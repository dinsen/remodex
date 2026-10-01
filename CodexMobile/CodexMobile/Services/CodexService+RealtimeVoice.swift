// FILE: CodexService+RealtimeVoice.swift
// Purpose: Connects iOS directly to GPT-Live and delegates Codex work through
// the paired bridge using transcript and response events.
// Layer: Service
// Exports: CodexRealtimeVoiceSession, CodexRealtimeVoiceConnection, CodexService realtime voice helpers
// Depends on: Foundation, CryptoKit, CodexService, JSONValue

import Foundation
import AVFAudio
import CoreAudio
import CryptoKit

struct CodexRealtimeVoiceSession: Equatable, Sendable {
    static let liveModel = "gpt-live-1"

    let sessionID: String
    let expiresAt: Date
    let model: String

    var isValid: Bool {
        expiresAt > Date()
    }
}

@MainActor
protocol CodexLiveVoiceWebSocket: AnyObject {
    func resume()
    func send(text: String) async throws
    func receiveText() async throws -> String
    func close()
}

enum CodexRealtimeVoiceStartupError: Error, Equatable {
    case missingAPIKey
    case bridgeUpdateRequired

    var userMessage: String {
        switch self {
        case .missingAPIKey:
            "Add an OpenAI API key in Settings to use Live Voice."
        case .bridgeUpdateRequired:
            "Update the Remodex bridge on your Mac to use direct GPT-Live Voice."
        }
    }
}

private func isLegacyRealtimeVoiceBridgeMethodError(_ error: RPCError) -> Bool {
    error.code == -32601
        || error.message.localizedCaseInsensitiveContains("unknown method")
        || error.message.localizedCaseInsensitiveContains("method not found")
}

enum CodexLiveVoiceRedirectPolicy {
    static func permits(_ url: URL?) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "wss",
              components.host?.lowercased() == "api.openai.com",
              components.port == nil || components.port == 443,
              components.path == "/v1/live/sessions",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return true
    }
}

private final class CodexLiveVoiceRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(CodexLiveVoiceRedirectPolicy.permits(request.url) ? request : nil)
    }
}

@MainActor
final class URLSessionLiveVoiceWebSocket: CodexLiveVoiceWebSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration,
            delegate: CodexLiveVoiceRedirectDelegate(),
            delegateQueue: nil
        )
        self.session = session
        task = session.webSocketTask(with: request)
    }

    func resume() {
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw CodexServiceError.invalidResponse("Live Voice returned an unreadable event.")
            }
            return text
        @unknown default:
            throw CodexServiceError.invalidResponse("Live Voice returned an unsupported event.")
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Owns the phone-to-provider WebSocket and keeps Codex delegation on the
/// encrypted bridge. Provider audio never enters a bridge RPC.
@MainActor
final class CodexRealtimeVoiceConnection {
    typealias EventSender = @MainActor (_ method: String, _ params: JSONValue?) async throws -> RPCMessage
    typealias WebSocketFactory = @MainActor (URLRequest) -> CodexLiveVoiceWebSocket

    private static let providerURL = URL(string: "wss://api.openai.com/v1/live/sessions")!
    private static let providerStartTimeoutNanoseconds: UInt64 = 15_000_000_000
    private static let maxProviderEventBytes = 1_048_576
    private static let maxPendingProviderSends = 8

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case closing
        case failed
        case closed
    }

    let session: CodexRealtimeVoiceSession

    private let safetyIdentifier: String
    private let apiKeyProvider: @MainActor () -> String?
    private let webSocketFactory: WebSocketFactory
    private let sendEvent: EventSender
    private let providerCloseTimeoutNanoseconds: UInt64
    private var liveVoiceCoordinator: CodexLiveVoiceCoordinator?
    private var providerEventHandler: ((JSONValue) -> Void)?
    private var terminalHandlers: [() -> Void] = []
    private var providerSocket: CodexLiveVoiceWebSocket?
    private var providerReceiveTask: Task<Void, Never>?
    private var providerStartTimeoutTask: Task<Void, Never>?
    private var providerExpiryTask: Task<Void, Never>?
    private var providerCloseTimeoutTask: Task<Void, Never>?
    private var providerStartContinuation: CheckedContinuation<Void, Error>?
    private var providerStartResult: Result<Void, Error>?
    private var providerCloseContinuation: CheckedContinuation<Void, Never>?
    private var providerSendTail: Task<Void, Error>?
    private var bridgeCloseTask: Task<Void, Never>?
    private var queuedProviderSendCount = 0
    private var didReceiveProviderStart = false
    private var didReceiveProviderClose = false
    private var didSendBridgeClose = false
    private(set) var state: State = .idle
    private(set) var providerCloseFinalizationConfirmed: Bool?

    init(
        session: CodexRealtimeVoiceSession,
        safetyIdentifier: String? = nil,
        apiKeyProvider: @escaping @MainActor () -> String? = {
            SecureStore.readString(for: CodexSecureKeys.liveVoiceAPIKey)
        },
        webSocketFactory: @escaping WebSocketFactory = { URLSessionLiveVoiceWebSocket(request: $0) },
        providerCloseTimeoutNanoseconds: UInt64 = 3_000_000_000,
        sendEvent: @escaping EventSender
    ) {
        self.session = session
        self.safetyIdentifier = safetyIdentifier ?? Self.safetyIdentifier(for: session.sessionID)
        self.apiKeyProvider = apiKeyProvider
        self.webSocketFactory = webSocketFactory
        self.providerCloseTimeoutNanoseconds = providerCloseTimeoutNanoseconds
        self.sendEvent = sendEvent
    }

    // A default keeps previews/older call sites safe: the bridge-backed starter
    // in CodexService.openRealtimeVoiceConnection supplies the real sender.
    convenience init(session: CodexRealtimeVoiceSession) {
        self.init(session: session) { _, _ in
            throw CodexServiceError.invalidInput("Live Voice is unavailable.")
        }
    }

    /// Opens the provider WebSocket directly from the device and waits for the
    /// server's session.started event before capture begins.
    func connect() async throws {
        guard state == .idle else {
            throw CodexServiceError.invalidInput("Voice connection has already been started.")
        }
        guard session.isValid else {
            throw CodexServiceError.invalidInput("The live Voice session has expired. Try again.")
        }

        guard session.model == CodexRealtimeVoiceSession.liveModel else {
            state = .failed
            throw CodexServiceError.invalidInput("Live Voice is unavailable.")
        }

        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            state = .failed
            throw CodexRealtimeVoiceStartupError.missingAPIKey
        }

        var request = URLRequest(
            url: Self.providerURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: TimeInterval(Self.providerStartTimeoutNanoseconds) / 1_000_000_000
        )
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(safetyIdentifier, forHTTPHeaderField: "OpenAI-Safety-Identifier")

        let socket = webSocketFactory(request)
        providerSocket = socket
        state = .connecting
        scheduleProviderExpiry()
        socket.resume()
        providerStartTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.providerStartTimeoutNanoseconds)
            guard !Task.isCancelled, let self, self.state == .connecting else { return }
            self.completeProviderStart(
                .failure(CodexServiceError.invalidInput("Live Voice took too long to start. Check the API key and try again."))
            )
            self.finishProviderSession(
                error: CodexServiceError.invalidInput("Live Voice took too long to start. Check the API key and try again.")
            )
        }
        providerReceiveTask = Task { @MainActor [weak self] in
            await self?.receiveProviderEvents(from: socket)
        }

        do {
            try await sendProviderEvent(Self.sessionStartEvent())
            try await waitForProviderStart()
        } catch {
            if state != .closing {
                finishProviderSession(error: error)
            }
            throw error
        }
    }

    func setProviderEventHandler(_ handler: @escaping (JSONValue) -> Void) {
        providerEventHandler = handler
    }

    func setTerminalHandler(_ handler: @escaping () -> Void) {
        terminalHandlers = [handler]
    }

    func addTerminalHandler(_ handler: @escaping () -> Void) {
        terminalHandlers.append(handler)
    }

    func attachLiveVoiceCoordinator(_ coordinator: CodexLiveVoiceCoordinator) {
        liveVoiceCoordinator = coordinator
    }

    /// The bridge sends only completed Codex commentary back for the local
    /// provider socket to speak.
    func handleBridgeEvent(_ event: JSONValue) {
        guard let object = event.objectValue,
              let type = object["type"]?.stringValue else {
            return
        }
        if type == "session.closed",
           ["idle", "expired"].contains(object["reason"]?.stringValue),
           object["event_id"]?.stringValue != nil {
            beginProviderClose(notifyBridgeClose: false)
            return
        }
        guard state == .connected,
              type == "session.commentary.append",
              object["event_id"]?.stringValue != nil,
              object["delegation_id"]?.stringValue != nil,
              let content = object["content"]?.stringValue,
              content.utf8.count <= 1_024 else {
            return
        }
        Task { @MainActor [weak self] in
            do {
                try await self?.sendProviderEvent(event)
            } catch {
                guard let self, self.state != .closing else { return }
                self.finishProviderSession(error: error)
            }
        }
    }

    /// Sends one base64-encoded PCM16 chunk directly to GPT-Live.
    func sendAudio(base64PCM: String) async throws {
        guard state == .connected else {
            throw CodexServiceError.invalidInput("Voice connection is not active.")
        }
        let normalized = try await CodexTransferWork.trimWhitespace(base64PCM)
        guard !normalized.isEmpty else {
            throw CodexServiceError.invalidInput("Live Voice audio was empty.")
        }
        try await sendProviderEvent(.object([
            "type": .string("session.input_audio.append"),
            "audio": .string(normalized),
        ]))
    }

    func close() {
        beginProviderClose(notifyBridgeClose: true)
    }

    private func receiveProviderEvents(from socket: CodexLiveVoiceWebSocket) async {
        while !Task.isCancelled,
              providerSocket === socket,
              state == .connecting || state == .connected || state == .closing {
            do {
                let payload = try await socket.receiveText()
                guard payload.utf8.count <= Self.maxProviderEventBytes,
                      let event = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)),
                      let type = event.objectValue?["type"]?.stringValue else {
                    finishProviderSession(
                        error: CodexServiceError.invalidResponse("Live Voice returned an invalid event.")
                    )
                    return
                }

                if type == "session.started" {
                    didReceiveProviderStart = true
                    if state == .connecting {
                        state = .connected
                    }
                    providerStartTimeoutTask?.cancel()
                    providerStartTimeoutTask = nil
                    completeProviderStart(.success(()))
                } else if state != .closing,
                          type == "session.input_transcript.delta" || type == "session.delegation.created" {
                    try await forwardDelegationMetadata(event)
                }

                if state != .closing || type == "session.closed" {
                    providerEventHandler?(event)
                }
                if type == "session.closed" {
                    didReceiveProviderClose = true
                    if state == .closing {
                        completeProviderCloseWait()
                        return
                    }
                    finishProviderSession()
                    return
                }
                if type == "error" {
                    finishProviderSession(
                        error: CodexServiceError.invalidInput("GPT-Live returned an error. Check the API key and network connection.")
                    )
                    return
                }
            } catch {
                guard state == .connecting || state == .connected || state == .closing else { return }
                finishProviderSession(error: error)
                return
            }
        }
    }

    private func forwardDelegationMetadata(_ event: JSONValue) async throws {
        guard let bridgeEvent = Self.deviceBridgeMetadata(from: event) else { return }
        let response = try await sendEvent(
            "voice/realtime/device/event",
            .object([
                "sessionId": .string(session.sessionID),
                "event": bridgeEvent,
            ])
        )
        if let error = response.error {
            throw CodexServiceError.rpcError(error)
        }
    }

    private func waitForProviderStart() async throws {
        if let providerStartResult {
            try providerStartResult.get()
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            if let providerStartResult {
                continuation.resume(with: providerStartResult)
            } else {
                providerStartContinuation = continuation
            }
        }
    }

    private func completeProviderStart(_ result: Result<Void, Error>) {
        guard providerStartResult == nil else { return }
        providerStartResult = result
        guard let continuation = providerStartContinuation else { return }
        providerStartContinuation = nil
        continuation.resume(with: result)
    }

    private func scheduleProviderExpiry() {
        let remaining = max(0, session.expiresAt.timeIntervalSinceNow)
        let delayNanoseconds = UInt64(remaining * 1_000_000_000)
        providerExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.state == .connecting || self.state == .connected else {
                return
            }
            self.beginProviderClose(notifyBridgeClose: true)
        }
    }

    private func beginProviderClose(notifyBridgeClose: Bool) {
        guard state != .closed, state != .failed, state != .closing else { return }
        let bridgeCloseBarrier = notifyBridgeClose ? sendBridgeClose() : nil
        let shouldSendProviderClose = providerSocket != nil && (state == .connecting || state == .connected)

        liveVoiceCoordinator?.stopMedia()
        liveVoiceCoordinator = nil
        providerEventHandler = nil
        providerStartTimeoutTask?.cancel()
        providerStartTimeoutTask = nil
        providerExpiryTask?.cancel()
        providerExpiryTask = nil
        completeProviderStart(.failure(CodexServiceError.disconnected))

        guard shouldSendProviderClose else {
            state = .closed
            providerCloseFinalizationConfirmed = nil
            stopProviderResources()
            notifyTerminalHandlers()
            return
        }

        state = .closing
        didReceiveProviderClose = false
        providerCloseFinalizationConfirmed = nil
        providerCloseTimeoutTask = Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: self.providerCloseTimeoutNanoseconds)
            guard !Task.isCancelled, self.state == .closing else { return }
            self.finalizeProviderClose(confirmed: false)
        }
        Task { @MainActor [self] in
            if let bridgeCloseBarrier {
                await bridgeCloseBarrier.value
            }
            guard self.state == .closing else { return }
            if self.didReceiveProviderClose {
                self.finalizeProviderClose(confirmed: true)
                return
            }
            do {
                try await self.sendProviderEvent(Self.sessionCloseEvent(), allowDuringClose: true)
                guard self.state == .closing else { return }
                if !self.didReceiveProviderClose {
                    await self.waitForProviderClose()
                }
            } catch {
                guard self.state == .closing else { return }
            }
            guard self.state == .closing else { return }
            self.finalizeProviderClose(confirmed: self.didReceiveProviderClose)
        }
        notifyTerminalHandlers()
    }

    private func waitForProviderClose() async {
        guard state == .closing, !didReceiveProviderClose else { return }
        await withCheckedContinuation { continuation in
            if state != .closing || didReceiveProviderClose {
                continuation.resume()
            } else {
                providerCloseContinuation = continuation
            }
        }
    }

    private func completeProviderCloseWait() {
        guard let continuation = providerCloseContinuation else { return }
        providerCloseContinuation = nil
        continuation.resume()
    }

    private func finalizeProviderClose(confirmed: Bool) {
        guard state == .closing else { return }
        providerCloseFinalizationConfirmed = confirmed
        state = .closed
        completeProviderCloseWait()
        completeProviderStart(.failure(CodexServiceError.disconnected))
        liveVoiceCoordinator?.stopMedia()
        if !confirmed {
            bridgeCloseTask?.cancel()
        }
        stopProviderResources()
        notifyTerminalHandlers()
    }

    private func sendProviderEvent(_ event: JSONValue, allowDuringClose: Bool = false) async throws {
        let isActive = state == .connecting || state == .connected
        guard isActive || (allowDuringClose && state == .closing),
              let socket = providerSocket else {
            throw CodexServiceError.invalidInput("Voice connection is not active.")
        }
        guard allowDuringClose || queuedProviderSendCount < Self.maxPendingProviderSends else {
            throw CodexServiceError.invalidInput("Live Voice is temporarily overloaded. Try again.")
        }
        let data = try JSONEncoder().encode(event)
        guard data.count <= Self.maxProviderEventBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw CodexServiceError.invalidInput("Live Voice event was too large.")
        }

        let previousSend = providerSendTail
        queuedProviderSendCount += 1
        let sendTask = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.queuedProviderSendCount = max(0, self.queuedProviderSendCount - 1)
                    if self.queuedProviderSendCount == 0 {
                        self.providerSendTail = nil
                    }
                }
            }
            if let previousSend {
                if allowDuringClose {
                    try? await previousSend.value
                } else {
                    try await previousSend.value
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.providerSocket === socket,
                  self.state == .connecting
                    || self.state == .connected
                    || (allowDuringClose && self.state == .closing) else {
                throw CodexServiceError.disconnected
            }
            try await socket.send(text: text)
        }
        providerSendTail = sendTask
        try await sendTask.value
    }

    private func finishProviderSession(error: Error? = nil) {
        if state == .closing {
            finalizeProviderClose(confirmed: didReceiveProviderClose)
            return
        }
        guard state != .closed && state != .failed else { return }
        state = error == nil ? .closed : .failed
        providerCloseFinalizationConfirmed = nil
        _ = sendBridgeClose()
        completeProviderStart(.failure(error ?? CodexServiceError.disconnected))
        providerStartTimeoutTask?.cancel()
        providerStartTimeoutTask = nil
        liveVoiceCoordinator?.stopMedia()
        stopProviderResources()
        notifyTerminalHandlers()
    }

    private func stopProviderResources() {
        providerReceiveTask?.cancel()
        providerReceiveTask = nil
        providerStartTimeoutTask?.cancel()
        providerStartTimeoutTask = nil
        providerExpiryTask?.cancel()
        providerExpiryTask = nil
        providerCloseTimeoutTask?.cancel()
        providerCloseTimeoutTask = nil
        providerSendTail?.cancel()
        providerSendTail = nil
        queuedProviderSendCount = 0
        providerSocket?.close()
        providerSocket = nil
    }

    @discardableResult
    private func sendBridgeClose() -> Task<Void, Never>? {
        guard !didSendBridgeClose else { return bridgeCloseTask }
        didSendBridgeClose = true
        let sessionID = session.sessionID
        let sendEvent = self.sendEvent
        let task = Task { @MainActor in
            _ = try? await sendEvent(
                "voice/realtime/device/close",
                .object(["sessionId": .string(sessionID)])
            )
        }
        bridgeCloseTask = task
        return task
    }

    private static func sessionStartEvent() -> JSONValue {
        .object([
            "type": .string("session.start"),
            "event_id": .string(UUID().uuidString),
            "session": .object([
                "model": .string(CodexRealtimeVoiceSession.liveModel),
                "instructions": .string("You are the live voice interface for the user's local Codex task. Keep spoken replies concise and delegate task execution to the paired Mac bridge."),
                "audio": .object([
                    "format": .object([
                        "type": .string("audio/pcm"),
                        "rate": .integer(24_000),
                    ]),
                    "output": .object(["voice": .string("marin")]),
                ]),
                "delegation": .object(["type": .string("client")]),
            ]),
        ])
    }

    private static func sessionCloseEvent() -> JSONValue {
        .object([
            "type": .string("session.close"),
            "event_id": .string(UUID().uuidString),
        ])
    }

    private static func deviceBridgeMetadata(from event: JSONValue) -> JSONValue? {
        guard let object = event.objectValue,
              let type = object["type"]?.stringValue else {
            return nil
        }
        switch type {
        case "session.input_transcript.delta":
            guard let start = object["start_ms"],
                  let end = object["end_ms"],
                  let delta = object["delta"]?.stringValue,
                  !delta.isEmpty else {
                return nil
            }
            var metadata: [String: JSONValue] = [
                "type": .string(type),
                "start_ms": start,
                "end_ms": end,
                "delta": .string(delta),
            ]
            if let eventID = object["event_id"] {
                metadata["event_id"] = eventID
            }
            return .object(metadata)
        case "session.delegation.created":
            guard let offset = object["offset_ms"],
                  let delegation = object["delegation"]?.objectValue,
                  let id = delegation["id"]?.stringValue,
                  let target = delegation["target"]?.stringValue else {
                return nil
            }
            var metadata: [String: JSONValue] = [
                "type": .string(type),
                "offset_ms": offset,
                "delegation": .object([
                    "id": .string(id),
                    "target": .string(target),
                ]),
            ]
            if let eventID = object["event_id"] {
                metadata["event_id"] = eventID
            }
            if let delegationType = delegation["type"] {
                var normalizedDelegation = metadata["delegation"]?.objectValue ?? [:]
                normalizedDelegation["type"] = delegationType
                metadata["delegation"] = .object(normalizedDelegation)
            }
            return .object(metadata)
        default:
            return nil
        }
    }

    static func safetyIdentifier(for threadID: String) -> String {
        let digest = SHA256.hash(data: Data(threadID.utf8))
        return "remodex-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func notifyTerminalHandlers() {
        let handlers = terminalHandlers
        terminalHandlers.removeAll()
        handlers.forEach { $0() }
    }
}

@MainActor
protocol CodexLiveVoiceCapture: AnyObject {
    var onPCM16Chunk: (@MainActor (Data) -> Void)? { get set }
    func start() throws
    func stop()
}

@MainActor
protocol CodexLiveVoicePlayback: AnyObject {
    func enqueuePCM16(_ data: Data)
    func stop()
}

/// Captures mono PCM16 at the GPT-Live 24 kHz input rate. AVAudioConverter
/// handles hardware routes that expose a different sample rate or sample type.
nonisolated struct AVAudioLiveVoiceBufferSnapshot: Sendable {
    let sourceFormat: AVAudioFormat
    let frameLength: AVAudioFrameCount
    let buffers: [Data]
}

nonisolated final class AVAudioLiveVoiceConversionInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var didSupplyInput = false

    func claimInput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didSupplyInput else { return false }
        didSupplyInput = true
        return true
    }
}

@MainActor
final class AVAudioLiveVoiceCapture: CodexLiveVoiceCapture {
    var onPCM16Chunk: (@MainActor (Data) -> Void)?

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private let conversionQueue = DispatchQueue(label: "com.remodex.live-voice-audio-conversion")
    private var isRunning = false

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
    }

    nonisolated static func canUsePCM16FastPath(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatInt16
            && format.sampleRate == 24_000
            && format.channelCount == 1
            && format.isInterleaved
    }

    func start() throws {
        guard !isRunning else { return }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try audioSession.setActive(true)

        let inputNode = engine.inputNode
        let sourceFormat = inputNode.inputFormat(forBus: 0)
        guard sourceFormat.channelCount > 0, sourceFormat.sampleRate > 0 else {
            throw CodexServiceError.invalidInput("The microphone route is unavailable.")
        }

        let targetFormat = self.targetFormat
        let conversionQueue = self.conversionQueue
        inputNode.installTap(onBus: 0, bufferSize: 480, format: sourceFormat) { [weak self] buffer, _ in
            guard let snapshot = Self.snapshotAudioBuffer(buffer, sourceFormat: sourceFormat) else {
                return
            }

            conversionQueue.async {
                guard let data = Self.convertToPCM16(snapshot, targetFormat: targetFormat), !data.isEmpty else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.onPCM16Chunk?(data)
                }
            }
        }
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop() {
        guard isRunning || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private nonisolated static func snapshotAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat
    ) -> AVAudioLiveVoiceBufferSnapshot? {
        let bytesPerFrame = Int(sourceFormat.streamDescription.pointee.mBytesPerFrame)
        guard buffer.frameLength > 0, bytesPerFrame > 0 else {
            return nil
        }
        let byteCount = Int(buffer.frameLength) * bytesPerFrame
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard !sourceBuffers.isEmpty else {
            return nil
        }

        var copiedBuffers: [Data] = []
        copiedBuffers.reserveCapacity(sourceBuffers.count)
        for sourceBuffer in sourceBuffers {
            guard let sourceBytes = sourceBuffer.mData,
                  Int(sourceBuffer.mDataByteSize) >= byteCount else {
                return nil
            }
            copiedBuffers.append(Data(bytes: sourceBytes, count: byteCount))
        }

        return AVAudioLiveVoiceBufferSnapshot(
            sourceFormat: sourceFormat,
            frameLength: buffer.frameLength,
            buffers: copiedBuffers
        )
    }

    private nonisolated static func convertToPCM16(
        _ snapshot: AVAudioLiveVoiceBufferSnapshot,
        targetFormat: AVAudioFormat
    ) -> Data? {
        if canUsePCM16FastPath(snapshot.sourceFormat),
           let data = snapshot.buffers.first {
            return data
        }

        guard let converter = AVAudioConverter(from: snapshot.sourceFormat, to: targetFormat) else {
            return nil
        }
        let ratio = targetFormat.sampleRate / snapshot.sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(snapshot.frameLength) * ratio)) + 1))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var conversionError: NSError?
        let inputState = AVAudioLiveVoiceConversionInputState()
        converter.convert(to: output, error: &conversionError) { _, status in
            guard inputState.claimInput() else {
                status.pointee = .noDataNow
                return nil
            }
            guard let input = Self.makePCMBuffer(from: snapshot) else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil,
              output.frameLength > 0,
              let channelData = output.int16ChannelData else {
            return nil
        }
        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channelData.pointee, count: byteCount)
    }

    private nonisolated static func makePCMBuffer(from snapshot: AVAudioLiveVoiceBufferSnapshot) -> AVAudioPCMBuffer? {
        guard let input = AVAudioPCMBuffer(
            pcmFormat: snapshot.sourceFormat,
            frameCapacity: snapshot.frameLength
        ) else {
            return nil
        }
        input.frameLength = snapshot.frameLength
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        guard destinationBuffers.count == snapshot.buffers.count else {
            return nil
        }
        for (destination, source) in zip(destinationBuffers, snapshot.buffers) {
            guard let destinationBytes = destination.mData,
                  source.count <= Int(destination.mDataByteSize) else {
                return nil
            }
            source.copyBytes(to: destinationBytes.assumingMemoryBound(to: UInt8.self), count: source.count)
        }
        return input
    }
}

@MainActor
final class AVAudioLiveVoicePlayback: CodexLiveVoicePlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init() {
        format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func enqueuePCM16(_ data: Data) {
        guard !data.isEmpty, data.count % MemoryLayout<Int16>.size == 0 else { return }
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let destination = buffer.int16ChannelData?.pointee else {
            return
        }
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else { return }
            memcpy(destination, source, data.count)
        }
        buffer.frameLength = frameCount

        if !engine.isRunning {
            engine.prepare()
            guard (try? engine.start()) != nil else { return }
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying {
            player.play()
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.reset()
    }
}

/// Owns the iOS media lifecycle around a direct provider connection. Capture
/// and playback dependencies are injectable so tests never touch hardware.
@MainActor
final class CodexLiveVoiceCoordinator {
    private static let maxPendingAudioChunks = 8
    private static let maxPendingAudioBytes = 64 * 1_024
    private static let maxPendingOutputAudioChunks = 64
    private static let maxPendingOutputAudioBytes = 512 * 1_024

    private weak var connection: CodexRealtimeVoiceConnection?

    private let capture: CodexLiveVoiceCapture
    private let playback: CodexLiveVoicePlayback
    private var interruptionObserver: NSObjectProtocol?
    private var pendingSendTask: Task<Void, Never>?
    private var pendingAudioChunks: [Data] = []
    private var pendingAudioBytes = 0
    private var pendingOutputAudio: [Data] = []
    private var pendingOutputAudioBytes = 0
    private var outputAudioDrainTask: Task<Void, Never>?
    private var outputAudioDrainID: UUID?
    private(set) var pendingAudioChunkCount = 0
    private(set) var isRunning = false

    init(
        connection: CodexRealtimeVoiceConnection,
        capture: CodexLiveVoiceCapture,
        playback: CodexLiveVoicePlayback
    ) {
        self.connection = connection
        self.capture = capture
        self.playback = playback
    }

    convenience init(connection: CodexRealtimeVoiceConnection) {
        self.init(
            connection: connection,
            capture: AVAudioLiveVoiceCapture(),
            playback: AVAudioLiveVoicePlayback()
        )
    }

    func start() throws {
        guard !isRunning else { return }
        isRunning = true
        capture.onPCM16Chunk = { [weak self] data in
            self?.enqueueCapture(data)
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopForInterruption()
            }
        }
        do {
            try capture.start()
        } catch {
            stop(closeConnection: true)
            throw error
        }
    }

    func stop() {
        stop(closeConnection: true)
    }

    /// Called by the connection when its public close API is used. This keeps
    /// media teardown one-way and avoids recursively calling connection.close().
    func stopMedia() {
        stop(closeConnection: false)
    }

    func handleProviderEvent(_ event: JSONValue) {
        guard case .object(let object) = event else { return }
        let type = object["type"]?.stringValue ?? ""
        if type == "session.output_audio.delta",
           let encodedAudio = object["delta"]?.stringValue {
            if let data = Data(base64Encoded: encodedAudio),
               !data.isEmpty,
               data.count % MemoryLayout<Int16>.size == 0 {
                enqueueOutputAudio(data)
            }
        }
        if type == "session.closed" || type == "error" {
            stop(closeConnection: false)
        }
    }

    private func enqueueCapture(_ data: Data) {
        guard isRunning, !data.isEmpty, data.count % MemoryLayout<Int16>.size == 0 else { return }
        guard connection != nil else { return }
        guard data.count <= Self.maxPendingAudioBytes else { return }

        // Keep a small newest-audio window when the bridge is slower than the
        // microphone. Dropping the oldest frame bounds both count and memory,
        // and avoids retaining an unbounded chain of Tasks during backpressure.
        while pendingAudioChunks.count >= Self.maxPendingAudioChunks
            || pendingAudioBytes + data.count > Self.maxPendingAudioBytes {
            guard let dropped = pendingAudioChunks.first else { return }
            pendingAudioChunks.removeFirst()
            pendingAudioBytes -= dropped.count
        }
        pendingAudioChunks.append(data)
        pendingAudioBytes += data.count
        pendingAudioChunkCount = pendingAudioChunks.count
        startAudioDrainIfNeeded()
    }

    private func startAudioDrainIfNeeded() {
        guard pendingSendTask == nil else { return }
        pendingSendTask = Task { @MainActor [weak self] in
            await self?.drainAudioQueue()
        }
    }

    private func drainAudioQueue() async {
        defer {
            pendingSendTask = nil
            pendingAudioChunkCount = pendingAudioChunks.count
            if isRunning, !pendingAudioChunks.isEmpty {
                startAudioDrainIfNeeded()
            }
        }

        while isRunning, !Task.isCancelled, let connection, !pendingAudioChunks.isEmpty {
            let data = pendingAudioChunks.removeFirst()
            pendingAudioBytes -= data.count
            pendingAudioChunkCount = pendingAudioChunks.count
            do {
                let base64PCM = try await CodexTransferWork.encodeBase64(data)
                try await connection.sendAudio(base64PCM: base64PCM)
            } catch {
                stop(closeConnection: true)
                return
            }
        }
    }

    private func startOutputAudioDrainIfNeeded() {
        guard outputAudioDrainTask == nil else { return }
        let drainID = UUID()
        outputAudioDrainID = drainID
        outputAudioDrainTask = Task { @MainActor [weak self] in
            await self?.drainOutputAudioQueue(drainID: drainID)
        }
    }

    private func drainOutputAudioQueue(drainID: UUID) async {
        defer {
            if outputAudioDrainID == drainID {
                outputAudioDrainTask = nil
                outputAudioDrainID = nil
                if !pendingOutputAudio.isEmpty {
                    startOutputAudioDrainIfNeeded()
                }
            }
        }

        while !Task.isCancelled, !pendingOutputAudio.isEmpty {
            let data = pendingOutputAudio.removeFirst()
            pendingOutputAudioBytes -= data.count
            playback.enqueuePCM16(data)
            await Task.yield()
        }
    }

    private func enqueueOutputAudio(_ data: Data) {
        guard data.count <= Self.maxPendingOutputAudioBytes else { return }
        while pendingOutputAudio.count >= Self.maxPendingOutputAudioChunks
            || pendingOutputAudioBytes + data.count > Self.maxPendingOutputAudioBytes {
            guard !pendingOutputAudio.isEmpty else { return }
            pendingOutputAudioBytes -= pendingOutputAudio.removeFirst().count
        }
        pendingOutputAudio.append(data)
        pendingOutputAudioBytes += data.count
        startOutputAudioDrainIfNeeded()
    }

    private func stopForInterruption() {
        stop(closeConnection: true)
    }

    private func stop(closeConnection: Bool) {
        guard isRunning || interruptionObserver != nil else {
            if closeConnection { connection?.close() }
            return
        }
        isRunning = false
        capture.onPCM16Chunk = nil
        capture.stop()
        playback.stop()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        pendingSendTask?.cancel()
        pendingSendTask = nil
        pendingAudioChunks.removeAll(keepingCapacity: false)
        pendingAudioBytes = 0
        pendingAudioChunkCount = 0
        outputAudioDrainID = nil
        outputAudioDrainTask?.cancel()
        outputAudioDrainTask = nil
        pendingOutputAudio.removeAll(keepingCapacity: false)
        pendingOutputAudioBytes = 0
        if closeConnection {
            connection?.close()
        }
    }
}

extension CodexService {
    private static let realtimeVoiceSessionTimeoutNanoseconds: UInt64 = 15_000_000_000
    private static let realtimeVoiceBridgeCloseTimeoutNanoseconds: UInt64 = 1_000_000_000

    func registerRealtimeVoiceEventHandler(
        sessionID: String,
        handler: @escaping (JSONValue) -> Void
    ) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }
        realtimeVoiceEventHandlersBySessionID[normalizedSessionID] = handler
    }

    func unregisterRealtimeVoiceEventHandler(sessionID: String) {
        realtimeVoiceEventHandlersBySessionID.removeValue(forKey: sessionID)
        realtimeVoiceConnectionsBySessionID.removeValue(forKey: sessionID)
    }

    func invalidateRealtimeVoiceSessionsForAccessModeChange() {
        realtimeVoiceAccessRevision &+= 1
        Array(realtimeVoiceConnectionsBySessionID.values).forEach { $0.close() }
    }

    func invalidateRealtimeVoiceSessionsForAPIKeyChange() {
        realtimeVoiceAccessRevision &+= 1
        Array(realtimeVoiceConnectionsBySessionID.values).forEach { $0.close() }
    }

    func invalidateRealtimeVoiceSessionsForTransportDisconnect() {
        realtimeVoiceAccessRevision &+= 1
        Array(realtimeVoiceConnectionsBySessionID.values).forEach { $0.close() }
    }

    func handleRealtimeVoiceEvent(_ paramsObject: IncomingParamsObject?) {
        guard let paramsObject,
              let sessionID = paramsObject["sessionId"]?.stringValue,
              let event = paramsObject["event"] else {
            return
        }
        realtimeVoiceEventHandlersBySessionID[sessionID]?(event)
        let type = event.objectValue?["type"]?.stringValue
        if type == "session.closed" || type == "error" {
            realtimeVoiceEventHandlersBySessionID.removeValue(forKey: sessionID)
        }
    }

    // Requests a device-scoped GPT-Live delegation handle through the paired
    // bridge. Provider authentication and media remain on the iPhone.
    func requestRealtimeVoiceSession(threadID: String) async throws -> CodexRealtimeVoiceSession {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else {
            throw CodexServiceError.invalidInput("Voice needs an active conversation before it can start.")
        }

        let accessRevision = realtimeVoiceAccessRevision
        // Capture the selected access mode for the lifetime of this live session.
        // The bridge applies these per-turn fields to each spoken Codex request;
        // they must never be inherited from stale thread-level Full Access state.
        let accessConfiguration = runtimeAccessConfiguration()
        let turnStartAccessConfiguration = JSONValue.object([
            "approvalPolicyCandidates": .array(accessConfiguration.approvalPolicyCandidates.map { .string($0) }),
            "approvalsReviewerCandidates": .array(accessConfiguration.approvalsReviewerCandidates.map { reviewer in
                reviewer.map(JSONValue.string) ?? .null
            }),
            "legacySandbox": .string(accessConfiguration.legacySandbox),
            "sandboxPolicy": accessConfiguration.sandboxPolicy,
        ])

        let response: RPCMessage
        do {
            response = try await sendRequest(
                method: "voice/realtime/device/session",
                params: .object([
                    "threadId": .string(normalizedThreadID),
                    "turnStartAccessConfiguration": turnStartAccessConfiguration,
                ]),
                timeoutNanoseconds: Self.realtimeVoiceSessionTimeoutNanoseconds,
                timeoutMessage: "Live Voice session setup timed out. Check the bridge connection and try again."
            )
        } catch let CodexServiceError.rpcError(error) {
            // Real RPC responses are converted to errors by the incoming transport
            // before sendRequest returns; preserve safe upgrade guidance there too.
            guard isLegacyRealtimeVoiceBridgeMethodError(error) else {
                throw CodexServiceError.rpcError(error)
            }
            throw CodexRealtimeVoiceStartupError.bridgeUpdateRequired
        }

        if let error = response.error {
            if isLegacyRealtimeVoiceBridgeMethodError(error) {
                throw CodexRealtimeVoiceStartupError.bridgeUpdateRequired
            }
            throw CodexServiceError.rpcError(error)
        }

        guard let result = response.result?.objectValue,
              let sessionID = result["sessionId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              let expiresAtSeconds = result["expiresAt"]?.doubleValue,
              expiresAtSeconds.isFinite else {
            throw CodexServiceError.invalidResponse("The bridge returned an invalid live Voice session.")
        }

        guard result["transport"]?.stringValue == "device" else {
            await closeRealtimeVoiceBridgeSession(sessionID: sessionID)
            throw CodexRealtimeVoiceStartupError.bridgeUpdateRequired
        }

        let model = result["model"]?.stringValue ?? CodexRealtimeVoiceSession.liveModel
        guard model == CodexRealtimeVoiceSession.liveModel else {
            throw CodexServiceError.invalidResponse("The bridge returned an unsupported live Voice model.")
        }

        let expiresAt = Date(timeIntervalSince1970: expiresAtSeconds)
        guard expiresAt > Date() else {
            throw CodexServiceError.invalidResponse("The bridge returned an expired live Voice session.")
        }

        guard accessRevision == realtimeVoiceAccessRevision else {
            await closeRealtimeVoiceBridgeSession(sessionID: sessionID)
            throw CodexServiceError.invalidInput("The access mode changed while Voice was starting. Try again.")
        }

        return CodexRealtimeVoiceSession(sessionID: sessionID, expiresAt: expiresAt, model: model)
    }

    private func closeRealtimeVoiceBridgeSession(sessionID: String) async {
        _ = try? await sendRequest(
            method: "voice/realtime/device/close",
            params: .object(["sessionId": .string(sessionID)]),
            timeoutNanoseconds: Self.realtimeVoiceSessionTimeoutNanoseconds,
            timeoutMessage: "Live Voice bridge request timed out. Try again."
        )
    }

    // The iPhone owns the provider WebSocket. This object sends only transcript,
    // delegation, and close RPCs through the paired bridge.
    func openRealtimeVoiceConnection(threadID: String) async throws -> CodexRealtimeVoiceConnection {
        guard let apiKey = SecureStore.readString(for: CodexSecureKeys.liveVoiceAPIKey),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexRealtimeVoiceStartupError.missingAPIKey
        }
        let accessRevision = realtimeVoiceAccessRevision
        let session = try await requestRealtimeVoiceSession(threadID: threadID)
        guard accessRevision == realtimeVoiceAccessRevision else {
            await closeRealtimeVoiceBridgeSession(sessionID: session.sessionID)
            throw CodexServiceError.invalidInput("The access mode changed while Voice was starting. Try again.")
        }
        let connection = CodexRealtimeVoiceConnection(
            session: session,
            safetyIdentifier: CodexRealtimeVoiceConnection.safetyIdentifier(for: threadID.trimmingCharacters(in: .whitespacesAndNewlines)),
            apiKeyProvider: { SecureStore.readString(for: CodexSecureKeys.liveVoiceAPIKey) }
        ) { [weak self] method, params in
            guard let self else {
                throw CodexServiceError.disconnected
            }
            let isDeviceClose = method == "voice/realtime/device/close"
            let response = try await self.sendRequest(
                method: method,
                params: params,
                timeoutNanoseconds: isDeviceClose
                    ? Self.realtimeVoiceBridgeCloseTimeoutNanoseconds
                    : Self.realtimeVoiceSessionTimeoutNanoseconds,
                timeoutMessage: isDeviceClose
                    ? "Live Voice close timed out."
                    : "Live Voice bridge request timed out. Try again."
            )
            if let error = response.error {
                throw CodexServiceError.rpcError(error)
            }
            return response
        }
        let coordinator = CodexLiveVoiceCoordinator(connection: connection)
        connection.attachLiveVoiceCoordinator(coordinator)
        connection.setProviderEventHandler { [weak coordinator] event in
            coordinator?.handleProviderEvent(event)
        }
        connection.setTerminalHandler { [weak self] in
            self?.unregisterRealtimeVoiceEventHandler(sessionID: session.sessionID)
        }
        registerRealtimeVoiceEventHandler(sessionID: session.sessionID) { [weak connection] event in
            connection?.handleBridgeEvent(event)
        }
        realtimeVoiceConnectionsBySessionID[session.sessionID] = connection

        do {
            try await connection.connect()
            guard accessRevision == realtimeVoiceAccessRevision, connection.state == .connected else {
                throw CodexServiceError.invalidInput("The access mode changed while Voice was starting. Try again.")
            }
            try coordinator.start()
            guard accessRevision == realtimeVoiceAccessRevision, connection.state == .connected else {
                throw CodexServiceError.invalidInput("The access mode changed while Voice was starting. Try again.")
            }
            return connection
        } catch {
            connection.close()
            unregisterRealtimeVoiceEventHandler(sessionID: session.sessionID)
            coordinator.stop()
            throw error
        }
    }
}
