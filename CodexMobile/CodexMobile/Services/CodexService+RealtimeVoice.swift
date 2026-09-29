// FILE: CodexService+RealtimeVoice.swift
// Purpose: Starts a bridge-owned GPT-Live session and exposes a small iOS RPC
// boundary for audio/control events. The provider socket and API key stay on
// the paired Mac bridge.
// Layer: Service
// Exports: CodexRealtimeVoiceSession, CodexRealtimeVoiceConnection, CodexService realtime voice helpers
// Depends on: Foundation, CodexService, JSONValue

import Foundation
import AVFAudio
import CoreAudio

struct CodexRealtimeVoiceSession: Equatable, Sendable {
    static let liveModel = "gpt-live-1"

    let sessionID: String
    let expiresAt: Date
    let model: String

    var isValid: Bool {
        expiresAt > Date()
    }
}

/// Main-actor connection boundary for the bridge-owned GPT-Live session.
///
/// This type intentionally does not contain a provider URL, bearer token, or
/// provider WebSocket. `CodexService.sendRequest` carries the encrypted RPC
/// over the already-paired transport; the bridge owns OpenAI authentication and
/// the live provider connection. Native microphone capture/playback can feed
/// `sendAudio` as a later contained capability without changing that boundary.
@MainActor
final class CodexRealtimeVoiceConnection {
    typealias EventSender = @MainActor (_ method: String, _ params: JSONValue?) async throws -> RPCMessage

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed
        case closed
    }

    let session: CodexRealtimeVoiceSession

    private let sendEvent: EventSender
    private var liveVoiceCoordinator: CodexLiveVoiceCoordinator?
    private var bridgeEventHandler: ((JSONValue) -> Void)?
    private var terminalHandlers: [() -> Void] = []
    private(set) var state: State = .idle

    init(
        session: CodexRealtimeVoiceSession,
        sendEvent: @escaping EventSender
    ) {
        self.session = session
        self.sendEvent = sendEvent
    }

    // A default keeps previews/older call sites safe: the bridge-backed starter
    // in CodexService.openRealtimeVoiceConnection supplies the real sender.
    convenience init(session: CodexRealtimeVoiceSession) {
        self.init(session: session) { _, _ in
            throw CodexServiceError.invalidInput("Live Voice is unavailable.")
        }
    }

    /// The provider session is opened by the bridge before this object is
    /// created, so connecting here only transitions the local lifecycle state.
    func connect() async throws {
        guard state == .idle else {
            throw CodexServiceError.invalidInput("Voice connection has already been started.")
        }
        guard session.isValid else {
            throw CodexServiceError.invalidInput("The live Voice session has expired. Try again.")
        }

        state = .connecting
        guard session.model == CodexRealtimeVoiceSession.liveModel else {
            state = .failed
            throw CodexServiceError.invalidInput("Live Voice is unavailable.")
        }
        state = .connected
    }

    func setBridgeEventHandler(_ handler: @escaping (JSONValue) -> Void) {
        bridgeEventHandler = handler
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

    /// Called by CodexService when the bridge forwards a provider event. The
    /// event remains on-device after decryption; no provider credential is
    /// exposed to the handler or UI.
    func handleBridgeEvent(_ event: JSONValue) {
        let type = event.objectValue?["type"]?.stringValue
        if type == "session.closed" || type == "error" {
            state = .closed
            notifyTerminalHandlers()
        }
        bridgeEventHandler?(event)
    }

    /// Sends one base64-encoded PCM16 chunk to the bridge. The bridge validates
    /// and forwards it as `session.input_audio.append` to GPT-Live.
    func sendAudio(base64PCM: String) async throws {
        guard state == .connected else {
            throw CodexServiceError.invalidInput("Voice connection is not active.")
        }
        let normalized = base64PCM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CodexServiceError.invalidInput("Live Voice audio was empty.")
        }
        _ = try await sendEvent(
            "voice/realtime/audio",
            .object([
                "sessionId": .string(session.sessionID),
                "audio": .string(normalized),
            ])
        )
    }

    func close() {
        guard state != .closed else { return }
        let wasActive = state == .connected || state == .connecting
        state = .closed
        // Stop capture/playback before sending the close RPC so no queued
        // microphone chunk can race a provider session that is shutting down.
        liveVoiceCoordinator?.stopMedia()
        guard wasActive else { return }

        let sessionID = session.sessionID
        let sendEvent = self.sendEvent
        notifyTerminalHandlers()
        Task { @MainActor in
            _ = try? await sendEvent(
                "voice/realtime/close",
                .object(["sessionId": .string(sessionID)])
            )
        }
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

/// Owns the iOS media lifecycle around a bridge-backed connection. Capture and
/// playback dependencies are injectable so tests never touch hardware.
@MainActor
final class CodexLiveVoiceCoordinator {
    private static let maxPendingAudioChunks = 8
    private static let maxPendingAudioBytes = 64 * 1_024

    private weak var connection: CodexRealtimeVoiceConnection?

    private let capture: CodexLiveVoiceCapture
    private let playback: CodexLiveVoicePlayback
    private var interruptionObserver: NSObjectProtocol?
    private var pendingSendTask: Task<Void, Never>?
    private var pendingAudioChunks: [Data] = []
    private var pendingAudioBytes = 0
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
           let encodedAudio = object["delta"]?.stringValue,
           let data = Data(base64Encoded: encodedAudio),
           !data.isEmpty,
           data.count % MemoryLayout<Int16>.size == 0 {
            playback.enqueuePCM16(data)
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
                try await connection.sendAudio(base64PCM: data.base64EncodedString())
            } catch {
                stop(closeConnection: true)
                return
            }
        }
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
        if closeConnection {
            connection?.close()
        }
    }
}

extension CodexService {
    private static let realtimeVoiceSessionTimeoutNanoseconds: UInt64 = 15_000_000_000

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

    // Requests a bridge-owned GPT-Live handle through the encrypted, paired
    // bridge. No provider credential is returned to the iOS process.
    func requestRealtimeVoiceSession(threadID: String) async throws -> CodexRealtimeVoiceSession {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else {
            throw CodexServiceError.invalidInput("Voice needs an active conversation before it can start.")
        }

        let response = try await sendRequest(
            method: "voice/realtime/session",
            params: .object(["threadId": .string(normalizedThreadID)]),
            timeoutNanoseconds: Self.realtimeVoiceSessionTimeoutNanoseconds,
            timeoutMessage: "Live Voice session setup timed out. Check the bridge connection and try again."
        )

        if let error = response.error {
            throw CodexServiceError.rpcError(error)
        }

        guard let result = response.result?.objectValue,
              let sessionID = result["sessionId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              let expiresAtSeconds = result["expiresAt"]?.doubleValue,
              expiresAtSeconds.isFinite else {
            throw CodexServiceError.invalidResponse("The bridge returned an invalid live Voice session.")
        }

        let model = result["model"]?.stringValue ?? CodexRealtimeVoiceSession.liveModel
        guard model == CodexRealtimeVoiceSession.liveModel else {
            throw CodexServiceError.invalidResponse("The bridge returned an unsupported live Voice model.")
        }

        let expiresAt = Date(timeIntervalSince1970: expiresAtSeconds)
        guard expiresAt > Date() else {
            throw CodexServiceError.invalidResponse("The bridge returned an expired live Voice session.")
        }

        return CodexRealtimeVoiceSession(sessionID: sessionID, expiresAt: expiresAt, model: model)
    }

    // The bridge opens and owns the provider WebSocket. This object only sends
    // encrypted media/control RPCs back through the same paired transport.
    func openRealtimeVoiceConnection(threadID: String) async throws -> CodexRealtimeVoiceConnection {
        let session = try await requestRealtimeVoiceSession(threadID: threadID)
        let connection = CodexRealtimeVoiceConnection(session: session) { [weak self] method, params in
            guard let self else {
                throw CodexServiceError.disconnected
            }
            let response = try await self.sendRequest(
                method: method,
                params: params,
                timeoutNanoseconds: Self.realtimeVoiceSessionTimeoutNanoseconds,
                timeoutMessage: "Live Voice bridge request timed out. Try again."
            )
            if let error = response.error {
                throw CodexServiceError.rpcError(error)
            }
            return response
        }
        let coordinator = CodexLiveVoiceCoordinator(connection: connection)
        connection.attachLiveVoiceCoordinator(coordinator)
        connection.setBridgeEventHandler { [weak coordinator] event in
            coordinator?.handleProviderEvent(event)
        }
        connection.setTerminalHandler { [weak self] in
            self?.unregisterRealtimeVoiceEventHandler(sessionID: session.sessionID)
        }
        registerRealtimeVoiceEventHandler(sessionID: session.sessionID) { [weak connection] event in
            connection?.handleBridgeEvent(event)
        }

        do {
            try await connection.connect()
            try coordinator.start()
            return connection
        } catch {
            unregisterRealtimeVoiceEventHandler(sessionID: session.sessionID)
            coordinator.stop()
            throw error
        }
    }
}
