// FILE: CodexService+Transport.swift
// Purpose: Outbound JSON-RPC transport and pending-response coordination.
// Layer: Service
// Exports: CodexService transport internals
// Depends on: Network.NWConnection, URLSessionWebSocketTask, CryptoKit, Security, CodexURLSessionWebSocketDelegate

import CryptoKit
import Foundation
import Network
import Security

// Keeps encrypted relay envelopes under one explicit ceiling across all iPhone websocket APIs.
// Image-heavy thread history and secure-envelope overhead can legitimately exceed 4 MB while
// reopening a chat, so the limit needs enough headroom for background `thread/read` catches too.
let codexWebSocketMaximumMessageSizeBytes = 16 * 1024 * 1024

private enum CodexWebSocketKeepAlivePolicy {
    static let intervalNanoseconds: UInt64 = 25_000_000_000
    // The foreground probe waits for a served response, not just a queued ping, so it
    // needs room for a radio that is still waking up after a long suspend.
    static let foregroundProbeTimeoutNanoseconds: UInt64 = 4_000_000_000
    static let constrainedIntervalNanoseconds: UInt64 = 35_000_000_000
}

private final class CodexForegroundProbeWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<Result<Void, Error>, Never>
    private var didFinish = false
    private var tasks: [Task<Void, Never>] = []

    init(continuation: CheckedContinuation<Result<Void, Error>, Never>) {
        self.continuation = continuation
    }

    func addTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = didFinish
        if !didFinish {
            tasks.append(task)
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let tasksToCancel = tasks
        tasks.removeAll()
        lock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }
        continuation.resume(returning: result)
    }
}

private enum CodexRelayTransportPreference {
    case manualTCP
    case networkWebSocket

    var logLabel: String {
        switch self {
        case .manualTCP:
            return "manual TCP websocket"
        case .networkWebSocket:
            return "NWConnection websocket"
        }
    }
}

private struct CodexConnectionReadyWaitConfiguration: Sendable {
    let logLabel: String
    let timeoutNanoseconds: UInt64
    let timeoutMessage: String
}

private final class CodexConnectionReadyWaitState: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<Void, Error>
    private let connection: NWConnection
    private var didFinish = false
    private var timeoutTask: Task<Void, Never>?
    private var lastObservedStateDescription = "setup"
    private var lastWaitingErrorDescription: String?

    init(continuation: CheckedContinuation<Void, Error>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = didFinish
        if !didFinish {
            timeoutTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func recordObservedState(_ state: NWConnection.State) {
        lock.lock()
        lastObservedStateDescription = String(describing: state)
        lock.unlock()
    }

    func recordWaitingError(_ error: NWError) {
        lock.lock()
        lastWaitingErrorDescription = String(describing: error)
        lock.unlock()
    }

    func timeoutLogMessage(label: String) -> String {
        lock.lock()
        let stateDescription = lastObservedStateDescription
        let waitingErrorDescription = lastWaitingErrorDescription
        lock.unlock()

        var message = "\(label) timed out while state=\(stateDescription)"
        if let waitingErrorDescription {
            message += " waitingError=\(waitingErrorDescription)"
        }
        return message
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }

        didFinish = true
        let taskToCancel = timeoutTask
        timeoutTask = nil
        lock.unlock()

        taskToCancel?.cancel()
        continuation.resume(with: result)
        // Ignore future state transitions after first completion.
        connection.stateUpdateHandler = { _ in }
    }
}

private struct CodexManualWebSocketEndpoint {
    let host: String
    let port: NWEndpoint.Port
    let scheme: String
}

nonisolated private func codexLogPairingTransport(_ message: String, isFailure: Bool = false) {
    #if DEBUG
    guard isFailure || AppEnvironment.verboseDiagnosticsEnabled else { return }
    print("[PAIRING] \(message)")
    #endif
}

extension CodexService {
    func invalidateTransferSession() {
        transferSessionGeneration = UUID()
        openCodeModelsLoadID = nil
        isLoadingOpenCodeModels = false
        transferSendLane.invalidate()
        transferSendLane = CodexTransferSendLane()
    }

    func invalidateTransferSocket() {
        transferSocketGeneration = UUID()
        invalidateTransferSession()
    }

    func currentTransferSocket() throws -> (connection: NWConnection?, task: URLSessionWebSocketTask?, isManual: Bool) {
        if usesManualWebSocketTransport {
            guard let connection = webSocketConnection else {
                throw CodexServiceError.disconnected
            }
            return (connection, nil, true)
        }
        if let task = webSocketTask {
            return (nil, task, false)
        }
        if let connection = webSocketConnection {
            return (connection, nil, false)
        }
        throw CodexServiceError.disconnected
    }

    func isCurrentTransferSocket(
        generation: UUID,
        connection: NWConnection?,
        task: URLSessionWebSocketTask?
    ) -> Bool {
        guard transferSessionGeneration == generation else { return false }
        if let connection {
            return webSocketConnection === connection && webSocketTask == nil
        }
        if let task {
            return webSocketTask === task && webSocketConnection == nil
        }
        return false
    }

    func isCurrentTransferReceive(
        _ token: CodexTransferReceiveToken,
        connection: NWConnection?,
        task: URLSessionWebSocketTask?
    ) -> Bool {
        guard token.canContinue(currentSocketGeneration: transferSocketGeneration) else { return false }
        switch token.mode {
        case .networkMessage:
            guard let connection, task == nil, !usesManualWebSocketTransport else { return false }
            return webSocketConnection === connection && webSocketTask == nil
        case .urlSessionMessage:
            guard let task, connection == nil else { return false }
            return webSocketTask === task && webSocketConnection == nil
        case .manualTCPChunk:
            guard let connection, task == nil, usesManualWebSocketTransport else { return false }
            return webSocketConnection === connection && webSocketTask == nil
        }
    }

    func isCurrentTransferReceiveApply(
        _ token: CodexTransferReceiveToken,
        sessionGeneration: UUID,
        connection: NWConnection?,
        task: URLSessionWebSocketTask?
    ) -> Bool {
        token.canApply(
            currentSocketGeneration: transferSocketGeneration,
            capturedSessionGeneration: sessionGeneration,
            currentSessionGeneration: transferSessionGeneration
        ) && isCurrentTransferReceive(token, connection: connection, task: task)
    }

    // Rejects oversized relay frames before Network.framework turns them into a raw EMSGSIZE failure.
    func validateOutgoingWebSocketMessageSize(_ text: String) throws {
        let payloadSize = text.utf8.count
        guard payloadSize <= codexWebSocketMaximumMessageSizeBytes else {
            throw CodexServiceError.invalidInput(
                "This payload is too large for the relay connection. Try fewer or smaller images and retry."
            )
        }
    }

    // Sends an RPC request and waits for the matching response by request id.
    // Optional per-call timeout is reserved for non-critical reads that can fail open.
    func sendRequest(
        method: String,
        params: JSONValue?,
        timeoutNanoseconds: UInt64? = nil,
        timeoutMessage: String? = nil,
        onDispatch: (@MainActor () -> Void)? = nil
    ) async throws -> RPCMessage {
        if let requestTransportOverride {
            onDispatch?()
            return try await requestTransportOverride(method, params)
        }

        guard isConnected, webSocketConnection != nil || webSocketTask != nil else {
            throw CodexServiceError.disconnected
        }

        let requestID: JSONValue = .string(UUID().uuidString)
        let requestKey = idKey(from: requestID)

        let request = RPCMessage(
            id: requestID,
            method: method,
            params: params,
            includeJSONRPC: false
        )

        if method == "turn/start",
           let collaborationMode = params?.objectValue?["collaborationMode"]?.objectValue?["mode"]?.stringValue {
            debugRuntimeLog(
                "rpc send turn/start collaborationMode=\(collaborationMode) thread=\(params?.objectValue?["threadId"]?.stringValue ?? "")"
            )
        }

        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[requestKey] = continuation
                scheduleRequestTimeoutIfNeeded(
                    requestKey: requestKey,
                    method: method,
                    timeoutNanoseconds: timeoutNanoseconds,
                    timeoutMessage: timeoutMessage
                )

                Task {
                    do {
                        try await sendMessage(
                            request,
                            onSendAttempt: onDispatch,
                            shouldSend: { self.pendingRequests[requestKey] != nil }
                        )
                    } catch {
                        if shouldTreatSendFailureAsDisconnect(error) {
                            handleReceiveError(error)
                            return
                        }

                        // Avoid double-resume if the request was already completed
                        // (for example by a disconnect race that fails all pending requests).
                        if let pendingContinuation = pendingRequests.removeValue(forKey: requestKey) {
                            pendingContinuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      let continuation = self.pendingRequests.removeValue(forKey: requestKey) else {
                    return
                }
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    // Clears a still-pending request after the caller's timeout so late responses are ignored safely.
    func scheduleRequestTimeoutIfNeeded(
        requestKey: String,
        method: String,
        timeoutNanoseconds: UInt64?,
        timeoutMessage: String?
    ) {
        guard let timeoutNanoseconds, timeoutNanoseconds > 0 else {
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard let self,
                  let continuation = self.pendingRequests.removeValue(forKey: requestKey) else {
                return
            }
            let message = timeoutMessage ?? "\(method) timed out while loading this chat."
            continuation.resume(
                throwing: CodexServiceError.invalidInput(message)
            )
        }
    }

    // Sends a fire-and-forget RPC notification.
    func sendNotification(method: String, params: JSONValue?) async throws {
        let notification = RPCMessage(
            jsonrpc: nil,
            id: nil,
            method: method,
            params: params,
            result: nil,
            error: nil
        )

        try await sendMessage(notification)
    }

    // Sends an RPC response for a server-initiated request.
    func sendResponse(id: JSONValue, result: JSONValue) async throws {
        let response = RPCMessage(id: id, result: result, includeJSONRPC: false)
        try await sendMessage(response)
    }

    // Sends an RPC error response for unsupported or invalid server requests.
    func sendErrorResponse(id: JSONValue?, code: Int, message: String, data: JSONValue? = nil) async throws {
        let rpcError = RPCError(code: code, message: message, data: data)
        let response = RPCMessage(id: id, error: rpcError, includeJSONRPC: false)
        try await sendMessage(response)
    }

    func sendMessage(
        _ message: RPCMessage,
        onSendAttempt: (@MainActor () -> Void)? = nil,
        shouldSend: (@MainActor () -> Bool)? = nil
    ) async throws {
        let lane = transferSendLane
        try await lane.withPermit {
            let generation = self.transferSessionGeneration
            let socket = try self.currentTransferSocket()
            guard let secureSession = self.secureSession else {
                throw CodexSecureTransportError.invalidHandshake(
                    "The secure Remodex session is not ready yet. Try reconnecting."
                )
            }
            let outboundSnapshot = CodexSecureOutboundSnapshot(
                sessionId: secureSession.sessionId,
                keyEpoch: secureSession.keyEpoch,
                counter: secureSession.nextOutboundCounter,
                key: secureSession.phoneToMacKey
            )

            let plaintext = try await self.transferJSONCodec.encodeText(message)
            try Task.checkCancellation()
            guard self.isCurrentTransferSocket(
                generation: generation,
                connection: socket.connection,
                task: socket.task
            ), self.secureSession?.sessionId == outboundSnapshot.sessionId,
               self.secureSession?.keyEpoch == outboundSnapshot.keyEpoch else {
                throw CodexServiceError.disconnected
            }

            let sealOutcome = await self.transferJSONCodec.sealSecureText(plaintext, session: outboundSnapshot)
            let secureText: String
            switch sealOutcome {
            case .failedBeforeSeal(let error):
                throw error
            case .sealed(let text, let counter):
                try self.consumeOutboundSecureCounter(
                    sessionID: outboundSnapshot.sessionId,
                    keyEpoch: outboundSnapshot.keyEpoch,
                    counter: counter
                )
                secureText = text
            case .failedAfterSeal(let counter, let error):
                try self.consumeOutboundSecureCounter(
                    sessionID: outboundSnapshot.sessionId,
                    keyEpoch: outboundSnapshot.keyEpoch,
                    counter: counter
                )
                throw error
            }

            try Task.checkCancellation()
            try await self.sendRawTextAdmitted(
                secureText,
                socket: socket,
                generation: generation,
                onSendAttempt: onSendAttempt,
                shouldSend: shouldSend
            )
        }
    }

    // Sends raw secure control messages before the JSON-RPC channel is initialized.
    func sendRawText(
        _ text: String,
        onSendAttempt: (@MainActor () -> Void)? = nil,
        shouldSend: (@MainActor () -> Bool)? = nil
    ) async throws {
        let lane = transferSendLane
        try await lane.withPermit {
            let generation = self.transferSessionGeneration
            let socket = try self.currentTransferSocket()
            try await self.sendRawTextAdmitted(
                text,
                socket: socket,
                generation: generation,
                onSendAttempt: onSendAttempt,
                shouldSend: shouldSend
            )
        }
    }

    func sendRawTextAdmitted(
        _ text: String,
        socket: (connection: NWConnection?, task: URLSessionWebSocketTask?, isManual: Bool),
        generation: UUID,
        onSendAttempt: (@MainActor () -> Void)?,
        shouldSend: (@MainActor () -> Bool)?
    ) async throws {
        let prepared: CodexPreparedWebSocketText
        do {
            prepared = try await CodexTransferWork.prepareWebSocketText(
                text,
                manual: socket.isManual,
                needsUTF8Data: socket.connection != nil && !socket.isManual,
                maximumSize: codexWebSocketMaximumMessageSizeBytes
            )
        } catch CodexTransferPreparationError.messageTooLarge {
            throw CodexServiceError.invalidInput(
                "This payload is too large for the relay connection. Try fewer or smaller images and retry."
            )
        }

        try Task.checkCancellation()
        guard isCurrentTransferSocket(
            generation: generation,
            connection: socket.connection,
            task: socket.task
        ) else {
            throw CodexServiceError.disconnected
        }
        guard shouldSend?() != false else { throw CancellationError() }
        onSendAttempt?()

        if socket.isManual {
            guard let connection = socket.connection, let frame = prepared.manualFrame else {
                throw CodexServiceError.disconnected
            }
            try await sendRaw(frame, on: connection)
            return
        }

        if let task = socket.task {
            try await task.send(.string(text))
            return
        }

        guard let connection = socket.connection, let payload = prepared.utf8Data else {
            throw CodexServiceError.disconnected
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "codex-jsonrpc", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: payload,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    func consumeOutboundSecureCounter(sessionID: String, keyEpoch: Int, counter: Int) throws {
        guard var currentSession = secureSession,
              currentSession.sessionId == sessionID,
              currentSession.keyEpoch == keyEpoch,
              currentSession.nextOutboundCounter == counter else {
            throw CodexServiceError.disconnected
        }
        currentSession.nextOutboundCounter = counter + 1
        secureSession = currentSession
    }

    func startReceiveLoop(with connection: NWConnection) {
        receiveNextMessage(on: connection)
    }

    func startReceiveLoop(with task: URLSessionWebSocketTask) {
        receiveNextMessage(on: task)
    }

    func startWebSocketKeepAliveLoop() {
        guard isConnected, isInitialized, isAppInForeground else {
            stopWebSocketKeepAliveLoop()
            return
        }
        guard webSocketKeepAliveTask == nil else {
            return
        }
        guard webSocketKeepAlivePingOverride != nil || webSocketConnection != nil || webSocketTask != nil else {
            return
        }

        webSocketKeepAliveTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let defaultInterval = self.isConstrainedNetwork
                    ? CodexWebSocketKeepAlivePolicy.constrainedIntervalNanoseconds
                    : CodexWebSocketKeepAlivePolicy.intervalNanoseconds
                let interval = self.webSocketKeepAliveIntervalOverrideNanoseconds
                    ?? defaultInterval
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else {
                    return
                }
                guard self.isConnected, self.isInitialized, self.isAppInForeground else {
                    self.stopWebSocketKeepAliveLoop()
                    return
                }

                do {
                    try await self.sendWebSocketKeepAlivePing()
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }
                    self.handleReceiveError(error)
                    return
                }
            }
        }
    }

    // Probes a foregrounded socket immediately so overnight zombie connections do not wait for the next 25s keepalive.
    func probeForegroundConnectionIfNeeded() async {
        guard isConnected, isInitialized, isAppInForeground else {
            return
        }

        let result = await foregroundConnectionProbeResult(
            timeoutNanoseconds: webSocketForegroundProbeTimeoutOverrideNanoseconds
                ?? CodexWebSocketKeepAlivePolicy.foregroundProbeTimeoutNanoseconds
        )

        if case .failure(let error) = result,
           isAppInForeground,
           isConnected || isInitialized {
            handleReceiveError(error)
        }
    }

    private func foregroundConnectionProbeResult(timeoutNanoseconds: UInt64) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            let waiter = CodexForegroundProbeWaiter(continuation: continuation)

            let pingTask = Task { @MainActor [weak self] in
                guard let self else {
                    waiter.finish(.success(()))
                    return
                }

                do {
                    try await self.performForegroundConnectionProbe()
                    waiter.finish(.success(()))
                } catch {
                    waiter.finish(.failure(error))
                }
            }
            waiter.addTask(pingTask)

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else {
                    return
                }
                waiter.finish(.failure(NWError.posix(.ETIMEDOUT)))
            }
            waiter.addTask(timeoutTask)
        }
    }

    // Relay pings complete as soon as the local stack buffers the frame, so a socket that
    // died silently while the phone slept still passes a ping-only probe: the app then sits
    // "connected" against a dead peer and the sidebar never refreshes until a relaunch.
    // Only a served response proves the far side is alive, so the probe also asks for a
    // single thread row.
    private func performForegroundConnectionProbe() async throws {
        try await sendWebSocketKeepAlivePing()
        _ = try await fetchCoalescedServerThreads(limit: 1)
    }

    func stopWebSocketKeepAliveLoop() {
        webSocketKeepAliveTask?.cancel()
        webSocketKeepAliveTask = nil
    }

    func sendWebSocketKeepAlivePing() async throws {
        if let webSocketKeepAlivePingOverride {
            try await webSocketKeepAlivePingOverride()
            return
        }

        if usesManualWebSocketTransport {
            guard let connection = webSocketConnection else {
                throw CodexServiceError.disconnected
            }
            try await sendManualWebSocketFrame(opcode: 0x9, payload: Data(), on: connection)
            return
        }

        if let task = webSocketTask {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
            return
        }

        guard let connection = webSocketConnection else {
            throw CodexServiceError.disconnected
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        let context = NWConnection.ContentContext(identifier: "codex-keepalive-ping", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    // Reads raw TCP bytes and drains manual websocket frames for the relay LAN fallback.
    func startManualReceiveLoop(with connection: NWConnection) {
        receiveNextManualChunk(on: connection)
    }

    func receiveNextMessage(on connection: NWConnection) {
        let receiveToken = CodexTransferReceiveToken(
            socketGeneration: transferSocketGeneration,
            mode: .networkMessage
        )
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrentTransferReceive(
                    receiveToken,
                    connection: connection,
                    task: nil
                ) else { return }

                if let error {
                    self.handleReceiveError(error)
                    return
                }

                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   metadata.opcode == .close {
                    self.handleReceiveError(
                        CodexServiceError.disconnected,
                        relayCloseCode: metadata.closeCode
                    )
                    return
                }

                if let data, let text = await CodexTransferWork.decodeUTF8(data) {
                    let sessionGeneration = self.transferSessionGeneration
                    if self.isCurrentTransferReceiveApply(
                        receiveToken,
                        sessionGeneration: sessionGeneration,
                        connection: connection,
                        task: nil
                    ) {
                        await self.processIncomingWireText(text, expectedGeneration: sessionGeneration)
                    }
                }

                if self.isCurrentTransferReceive(receiveToken, connection: connection, task: nil) {
                    self.receiveNextMessage(on: connection)
                }
            }
        }
    }

    func receiveNextManualChunk(on connection: NWConnection) {
        let receiveToken = CodexTransferReceiveToken(
            socketGeneration: transferSocketGeneration,
            mode: .manualTCPChunk
        )
        let receiveSessionGeneration = transferSessionGeneration
        receiveRaw(on: connection) { [weak self] result in
            guard let self else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrentTransferReceive(
                    receiveToken,
                    connection: connection,
                    task: nil
                ) else { return }

                switch result {
                case .failure(let error):
                    self.handleReceiveError(error)
                case .success(nil):
                    self.handleReceiveError(CodexServiceError.disconnected)
                case .success(let data?):
                    if !data.isEmpty {
                        do {
                            let didHandleClose = try await self.drainManualWebSocketFrames(
                                on: connection,
                                appending: data
                            )
                            if didHandleClose {
                                return
                            }
                        } catch {
                            guard self.isCurrentTransferReceive(
                                receiveToken,
                                connection: connection,
                                task: nil
                            ) else { return }
                            if self.transferSessionGeneration == receiveSessionGeneration {
                                self.handleReceiveError(error)
                            } else {
                                self.receiveNextManualChunk(on: connection)
                            }
                            return
                        }
                    }
                    if self.isCurrentTransferReceive(receiveToken, connection: connection, task: nil) {
                        self.receiveNextManualChunk(on: connection)
                    }
                }
            }
        }
    }

    func receiveNextMessage(on task: URLSessionWebSocketTask) {
        let receiveToken = CodexTransferReceiveToken(
            socketGeneration: transferSocketGeneration,
            mode: .urlSessionMessage
        )
        task.receive { [weak self] result in
            guard let self else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrentTransferReceive(
                    receiveToken,
                    connection: nil,
                    task: task
                ) else { return }

                switch result {
                case .failure(let error):
                    self.handleReceiveError(
                        error,
                        relayCloseCode: self.relayCloseCode(for: task.closeCode)
                    )
                case .success(let message):
                    let text: String?
                    switch message {
                    case .string(let value):
                        text = value
                    case .data(let data):
                        text = await CodexTransferWork.decodeUTF8(data)
                    @unknown default:
                        text = nil
                    }
                    if let text {
                        let sessionGeneration = self.transferSessionGeneration
                        if self.isCurrentTransferReceiveApply(
                            receiveToken,
                            sessionGeneration: sessionGeneration,
                            connection: nil,
                            task: task
                        ) {
                            await self.processIncomingWireText(text, expectedGeneration: sessionGeneration)
                        }
                    }

                    if self.isCurrentTransferReceive(receiveToken, connection: nil, task: task) {
                        self.receiveNextMessage(on: task)
                    }
                }
            }
        }
    }

    func establishWebSocketConnection(url: URL, token: String, role: String? = nil) async throws -> CodexWebSocketTransport {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            throw CodexServiceError.invalidServerURL(url.absoluteString)
        }

        let preference = relayTransportPreference(for: url)
        codexLogPairingTransport("using \(preference.logLabel) for \(url.host ?? "unknown-host")")

        switch preference {
        case .manualTCP:
            return try await establishManualTCPWebSocketConnection(url: url, token: token, role: role)
        case .networkWebSocket:
            return try await establishNWWebSocketConnection(url: url, token: token, role: role)
        }
    }

    // Mirrors litter's raw TCP websocket client so LAN/private-overlay pairing can bypass iOS proxy/WebSocket API bugs.
    func establishManualTCPWebSocketConnection(
        url: URL,
        token: String,
        role: String? = nil
    ) async throws -> CodexWebSocketTransport {
        let endpoint = try manualWebSocketEndpoint(from: url)

        let parameters = NWParameters(
            tls: (endpoint.scheme == "wss") ? NWProtocolTLS.Options() : nil,
            tcp: NWProtocolTCP.Options()
        )
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: endpoint.port, using: parameters)
        let waitConfiguration = CodexConnectionReadyWaitConfiguration(
            logLabel: "manual TCP websocket",
            timeoutNanoseconds: 12_000_000_000,
            timeoutMessage: "Connection timed out after 12s while opening the direct relay socket."
        )

        codexLogPairingTransport("opening manual TCP websocket")
        try await waitUntilManualConnectionReady(connection, configuration: waitConfiguration)
        do {
            try await performManualWebSocketHandshake(on: connection, url: url, token: token, role: role)
            codexLogPairingTransport("manual TCP websocket connected")
        } catch {
            connection.cancel()
            throw error
        }

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.webSocketConnection === connection, self.usesManualWebSocketTransport else { return }

                switch state {
                case .failed(let error):
                    self.handleReceiveError(error)
                case .cancelled:
                    if self.isConnected {
                        self.handleReceiveError(CodexServiceError.disconnected)
                    }
                default:
                    break
                }
            }
        }

        return .manualTCP(connection)
    }

    // Uses Network.framework directly for remote relays and as a fallback when URLSession
    // misclassifies a reachable local relay as offline before sending any upgrade request.
    func establishNWWebSocketConnection(
        url: URL,
        token: String,
        role: String? = nil
    ) async throws -> CodexWebSocketTransport {
        let scheme = (url.scheme ?? "ws").lowercased()
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        // Network.framework defaults this low enough to reject larger encrypted envelopes.
        webSocketOptions.maximumMessageSize = codexWebSocketMaximumMessageSizeBytes

        var additionalHeaders: [(name: String, value: String)] = []
        if let role, !role.isEmpty {
            additionalHeaders.append((name: "x-role", value: role))
        } else if !token.isEmpty {
            additionalHeaders.append((name: "Authorization", value: "Bearer \(token)"))
        }
        if !additionalHeaders.isEmpty {
            webSocketOptions.setAdditionalHeaders(additionalHeaders)
        }

        let tlsOptions: NWProtocolTLS.Options? = (scheme == "wss") ? NWProtocolTLS.Options() : nil
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        codexLogPairingTransport("opening NWConnection websocket")
        let connection = NWConnection(to: .url(url), using: parameters)
        let waitConfiguration = CodexConnectionReadyWaitConfiguration(
            logLabel: "NWConnection websocket",
            timeoutNanoseconds: 12_000_000_000,
            timeoutMessage: "Connection timed out after 12s while opening the relay websocket."
        )

        try await waitUntilConnectionReady(connection, configuration: waitConfiguration)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.webSocketConnection === connection else { return }

                switch state {
                case .failed(let error):
                    self.handleReceiveError(error)
                case .cancelled:
                    if self.isConnected {
                        self.handleReceiveError(CodexServiceError.disconnected)
                    }
                default:
                    break
                }
            }
        }

        return .network(connection)
    }

    // Uses URLSession for LAN relay sockets because NWConnection has been unreliable
    // on some iOS builds for local ws:// endpoints even when the relay is reachable.
    func establishURLSessionWebSocketConnection(
        url: URL,
        token: String,
        role: String? = nil
    ) async throws -> CodexWebSocketTransport {
        var request = URLRequest(url: url)
        if let role, !role.isEmpty {
            request.setValue(role, forHTTPHeaderField: "x-role")
        } else if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let configuration = URLSessionConfiguration.default
        // Local relay sockets should fail fast if the LAN path is unusable instead of
        // waiting indefinitely for a "better" connectivity state that never starts the upgrade.
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        let delegate = CodexURLSessionWebSocketDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = codexWebSocketMaximumMessageSizeBytes
        let connectionTimeoutNanoseconds: UInt64 = 12_000_000_000

        codexLogPairingTransport("opening URLSessionWebSocketTask")
        task.resume()
        webSocketSessionDelegate = delegate

        let timeoutTask = Task { [weak task, weak delegate] in
            try? await Task.sleep(nanoseconds: connectionTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            task?.cancel(with: .goingAway, reason: nil)
            delegate?.resolveOpen(
                with: .failure(CodexServiceError.invalidInput("Connection timed out after 12s"))
            )
        }
        defer { timeoutTask.cancel() }

        do {
            try await delegate.waitForOpen()
            codexLogPairingTransport("URLSessionWebSocketTask connected")
        } catch {
            codexLogPairingTransport(
                "URLSessionWebSocketTask failed: \(urlSessionWebSocketDebugDescription(for: error))",
                isFailure: true
            )
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            webSocketSessionDelegate = nil
            throw error
        }

        return .urlSession(session, task)
    }

    func failAllPendingRequests(with error: Error) {
        let continuations = pendingRequests
        pendingRequests.removeAll()

        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    func idKey(from id: JSONValue) -> String {
        switch id {
        case .string(let value):
            return "s:\(value)"
        case .integer(let value):
            return "i:\(value)"
        case .double(let value):
            return "d:\(value)"
        case .bool(let value):
            return "b:\(value)"
        case .null:
            return "null"
        case .object, .array:
            return "complex:\(String(describing: id))"
        }
    }

    func relayCloseCode(for closeCode: URLSessionWebSocketTask.CloseCode) -> NWProtocolWebSocket.CloseCode? {
        guard closeCode != .invalid else {
            return nil
        }

        let rawValue = closeCode.rawValue
        if rawValue >= 4000 {
            return .privateCode(UInt16(rawValue))
        }
        if rawValue >= 3000 {
            return .applicationCode(UInt16(rawValue))
        }
        return nil
    }

    // Extracts CFNetwork/NWPath hints from websocket failures so local relay bugs are diagnosable on device.
    func urlSessionWebSocketDebugDescription(for error: Error) -> String {
        let nsError = error as NSError
        let pathDescription = nsError.userInfo["_NSURLErrorNWPathKey"] as? String
        let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError

        var parts = ["\(error)"]
        if let pathDescription, !pathDescription.isEmpty {
            parts.append("nwPath=\(pathDescription)")
        }
        if let underlyingError {
            parts.append("underlying=\(underlyingError.domain)(\(underlyingError.code)) \(underlyingError.localizedDescription)")
        }
        return parts.joined(separator: " | ")
    }

    // Waits for plain TCP readiness before sending the manual websocket upgrade request.
    private func waitUntilManualConnectionReady(
        _ connection: NWConnection,
        configuration: CodexConnectionReadyWaitConfiguration
    ) async throws {
        try await waitUntilConnectionReady(connection, configuration: configuration)
    }

    // Normalizes the one-shot NWConnection wait flow so timeout/cancel races surface a useful cause.
    private func waitUntilConnectionReady(
        _ connection: NWConnection,
        configuration: CodexConnectionReadyWaitConfiguration
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let waitState = CodexConnectionReadyWaitState(
                continuation: continuation,
                connection: connection
            )

            connection.stateUpdateHandler = { state in
                waitState.recordObservedState(state)
                codexLogPairingTransport("\(configuration.logLabel) state: \(state)")
                switch state {
                case .ready:
                    waitState.finish(.success(()))
                case .waiting(let error):
                    waitState.recordWaitingError(error)
                case .failed(let error):
                    codexLogPairingTransport(
                        "\(configuration.logLabel) failed: \(error)",
                        isFailure: true
                    )
                    waitState.finish(.failure(error))
                case .cancelled:
                    waitState.finish(.failure(CodexServiceError.disconnected))
                default:
                    break
                }
            }

            connection.start(queue: webSocketQueue)
            let timeoutTask = Task { [weak connection, waitState] in
                try? await Task.sleep(nanoseconds: configuration.timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                let timeoutError = CodexServiceError.invalidInput(configuration.timeoutMessage)
                codexLogPairingTransport(
                    waitState.timeoutLogMessage(label: configuration.logLabel),
                    isFailure: true
                )
                waitState.finish(.failure(timeoutError))
                connection?.cancel()
            }
            waitState.setTimeoutTask(timeoutTask)
        }
    }

    // Builds the HTTP upgrade request manually so LAN pairing avoids higher-level websocket APIs.
    func performManualWebSocketHandshake(
        on connection: NWConnection,
        url: URL,
        token: String,
        role: String?
    ) async throws {
        let key = randomManualWebSocketKey()
        let path = manualWebSocketPath(from: url)
        let hostHeader = url.port.map { "\(url.host ?? ""):\($0)" } ?? (url.host ?? "")
        var requestLines = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
        ]
        if let role, !role.isEmpty {
            requestLines.append("x-role: \(role)")
        } else if !token.isEmpty {
            requestLines.append("Authorization: Bearer \(token)")
        }
        requestLines.append(contentsOf: ["", ""])

        codexLogPairingTransport("sending manual TCP websocket upgrade request")
        try await sendRaw(Data(requestLines.joined(separator: "\r\n").utf8), on: connection)

        var headerBytes = Data()
        while true {
            if let range = headerBytes.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = Data(headerBytes[..<range.upperBound])
                manualWebSocketReadBuffer = Data(headerBytes[range.upperBound...])
                try validateManualWebSocketHandshakeResponse(headerData: headerData, key: key)
                codexLogPairingTransport("manual TCP websocket upgrade accepted")
                return
            }
            guard let chunk = try await receiveRaw(on: connection) else {
                throw CodexServiceError.disconnected
            }
            headerBytes.append(chunk)
            if headerBytes.count > 65_536 {
                throw CodexServiceError.invalidInput("Relay handshake response was too large")
            }
        }
    }

    private func relayTransportPreference(for url: URL) -> CodexRelayTransportPreference {
        prefersDirectRelayTransport(for: url) ? .manualTCP : .networkWebSocket
    }

    private func manualWebSocketEndpoint(from url: URL) throws -> CodexManualWebSocketEndpoint {
        guard let host = url.host else {
            throw CodexServiceError.invalidServerURL(url.absoluteString)
        }

        let scheme = (url.scheme ?? "ws").lowercased()
        let defaultPort: UInt16 = (scheme == "wss") ? 443 : 80
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? Int(defaultPort))) else {
            throw CodexServiceError.invalidServerURL(url.absoluteString)
        }

        return CodexManualWebSocketEndpoint(host: host, port: port, scheme: scheme)
    }

    func manualWebSocketPath(from url: URL) -> String {
        let base = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            return "\(base)?\(query)"
        }
        return base
    }

    func randomManualWebSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    func validateManualWebSocketHandshakeResponse(headerData: Data, key: String) throws {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw CodexServiceError.invalidInput("Relay handshake response could not be decoded")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let status = lines.first, status.contains(" 101 ") else {
            throw CodexServiceError.invalidInput("Relay rejected websocket upgrade")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let acceptSeed = "\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let expectedAccept = Data(Insecure.SHA1.hash(data: Data(acceptSeed.utf8))).base64EncodedString()
        guard headers["sec-websocket-accept"] == expectedAccept else {
            throw CodexServiceError.invalidInput("Relay returned an invalid websocket accept key")
        }
    }

    // Preserves relay close semantics on the raw TCP websocket path so `.local` reconnects
    // reuse the same retry / re-pair policy as the higher-level websocket transports.
    func drainManualWebSocketFrames(
        on connection: NWConnection,
        appending incomingData: Data = Data()
    ) async throws -> Bool {
        var wireParts = [manualWebSocketReadBuffer]
        if !incomingData.isEmpty {
            wireParts.append(incomingData)
        }

        while true {
            let parseGeneration = transferSessionGeneration
            let batch = try await CodexTransferWork.parseManualWebSocketFrames(from: wireParts)
            guard webSocketConnection === connection, usesManualWebSocketTransport else { return false }
            guard transferSessionGeneration == parseGeneration else { continue }

            manualWebSocketReadBuffer = batch.remainingData
            var unprocessedFrames = batch.frames
            var shouldReparseRemainder = false

            while !unprocessedFrames.isEmpty {
                let frame = unprocessedFrames.removeFirst()
                let frameGeneration = transferSessionGeneration
                guard webSocketConnection === connection, usesManualWebSocketTransport else { return false }
                var shouldRetryCurrentFrame = false

                switch frame.opcode {
                case 0x1:
                    if let text = await CodexTransferWork.decodeUTF8(frame.payload) {
                        guard transferSessionGeneration == frameGeneration else {
                            shouldRetryCurrentFrame = true
                            shouldReparseRemainder = true
                            break
                        }
                        let wasProcessed = await processIncomingWireText(text, expectedGeneration: frameGeneration)
                        if transferSessionGeneration != frameGeneration {
                            shouldRetryCurrentFrame = !wasProcessed
                            shouldReparseRemainder = true
                        }
                    }
                case 0x8:
                    handleReceiveError(
                        CodexServiceError.disconnected,
                        relayCloseCode: relayCloseCode(fromManualWebSocketClosePayload: frame.payload)
                    )
                    return true
                case 0x9:
                    try await sendManualWebSocketFrame(opcode: 0xA, payload: frame.payload, on: connection)
                case 0xA:
                    break
                default:
                    break
                }

                if shouldReparseRemainder {
                    wireParts.removeAll(keepingCapacity: false)
                    if shouldRetryCurrentFrame {
                        wireParts.append(frame.wireData)
                    }
                    wireParts.append(contentsOf: unprocessedFrames.map(\.wireData))
                    wireParts.append(batch.remainingData)
                    break
                }
            }

            if shouldReparseRemainder {
                manualWebSocketReadBuffer = Data()
                continue
            }
            return false
        }
    }

    // Pulls relay-owned custom close codes out of raw websocket close payloads on the direct transport.
    func relayCloseCode(fromManualWebSocketClosePayload payload: Data) -> NWProtocolWebSocket.CloseCode? {
        guard payload.count >= 2 else {
            return nil
        }

        let rawValue = (UInt16(payload[payload.startIndex]) << 8) | UInt16(payload[payload.startIndex + 1])
        if rawValue >= 4000 {
            return .privateCode(rawValue)
        }
        if rawValue >= 3000 {
            return .applicationCode(rawValue)
        }

        return nil
    }

    func sendManualWebSocketFrame(opcode: UInt8, payload: Data, on connection: NWConnection) async throws {
        let lane = transferSendLane
        try await lane.withPermit {
            let generation = self.transferSessionGeneration
            guard self.webSocketConnection === connection, self.usesManualWebSocketTransport else {
                throw CodexServiceError.disconnected
            }
            let frame = try await CodexTransferWork.makeManualWebSocketFrame(opcode: opcode, payload: payload)
            try Task.checkCancellation()
            guard self.isCurrentTransferSocket(generation: generation, connection: connection, task: nil),
                  self.usesManualWebSocketTransport else {
                throw CodexServiceError.disconnected
            }
            try await self.sendRaw(frame, on: connection)
        }
    }

    func sendRaw(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func receiveRaw(
        on connection: NWConnection,
        completion: @escaping (Result<Data?, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let error {
                completion(.failure(error))
                return
            }
            if isComplete && (data == nil || data?.isEmpty == true) {
                completion(.success(nil))
                return
            }
            completion(.success(data ?? Data()))
        }
    }

    func receiveRaw(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            receiveRaw(on: connection) { result in
                continuation.resume(with: result)
            }
        }
    }
}
