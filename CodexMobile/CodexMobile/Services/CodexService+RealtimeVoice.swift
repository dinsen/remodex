// FILE: CodexService+RealtimeVoice.swift
// Purpose: Requests an ephemeral Realtime session through the paired bridge and owns its socket lifecycle.
// Layer: Service
// Exports: CodexRealtimeVoiceSession, CodexRealtimeVoiceConnection, CodexService realtime voice helpers
// Depends on: Foundation, CodexService, CodexURLSessionWebSocketDelegate

import Foundation

struct CodexRealtimeVoiceSession: Equatable, Sendable {
    static let realtimeModel = "gpt-realtime-2.1"

    let clientSecret: String
    let expiresAt: Date

    var isValid: Bool {
        expiresAt > Date()
    }
}

@MainActor
protocol CodexRealtimeVoiceSocket: AnyObject {
    func connect() async throws
    func close()
}

@MainActor
private final class URLSessionRealtimeVoiceSocket: CodexRealtimeVoiceSocket {
    private static let connectionTimeoutNanoseconds: UInt64 = 15_000_000_000

    private let request: URLRequest
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var delegate: CodexURLSessionWebSocketDelegate?

    init(request: URLRequest) {
        self.request = request
    }

    func connect() async throws {
        guard task == nil else {
            return
        }

        let delegate = CodexURLSessionWebSocketDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = codexWebSocketMaximumMessageSizeBytes
        self.delegate = delegate
        self.session = session
        self.task = task
        task.resume()

        let timeoutTask = Task { [weak task, weak delegate] in
            try? await Task.sleep(nanoseconds: Self.connectionTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            task?.cancel(with: .goingAway, reason: nil)
            delegate?.resolveOpen(
                with: .failure(CodexServiceError.invalidInput("Live Voice connection timed out. Try again."))
            )
        }
        defer { timeoutTask.cancel() }

        do {
            try await delegate.waitForOpen()
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            self.task = nil
            self.session = nil
            self.delegate = nil
            throw error
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        delegate = nil
    }
}

@MainActor
final class CodexRealtimeVoiceConnection {
    typealias SocketFactory = @MainActor (URLRequest) -> CodexRealtimeVoiceSocket

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed
        case closed
    }

    let session: CodexRealtimeVoiceSession

    private let socketFactory: SocketFactory
    private var socket: CodexRealtimeVoiceSocket?
    private(set) var state: State = .idle

    init(
        session: CodexRealtimeVoiceSession,
        socketFactory: @escaping SocketFactory = {
            URLSessionRealtimeVoiceSocket(request: $0)
        }
    ) {
        self.session = session
        self.socketFactory = socketFactory
    }

    func connect() async throws {
        guard state == .idle else {
            throw CodexServiceError.invalidInput("Voice connection has already been started.")
        }
        guard session.isValid else {
            throw CodexServiceError.invalidInput("The live Voice session has expired. Try again.")
        }

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(CodexRealtimeVoiceSession.realtimeModel)") else {
            throw CodexServiceError.invalidInput("Live Voice is unavailable.")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.clientSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        state = .connecting
        let socket = socketFactory(request)
        self.socket = socket

        do {
            try await socket.connect()
            guard session.isValid else {
                socket.close()
                self.socket = nil
                state = .failed
                throw CodexServiceError.invalidInput("The live Voice session expired while connecting. Try again.")
            }
            state = .connected
        } catch {
            socket.close()
            self.socket = nil
            state = .failed
            throw error
        }
    }

    func close() {
        socket?.close()
        socket = nil
        state = .closed
    }
}

extension CodexService {
    private static let realtimeVoiceSessionTimeoutNanoseconds: UInt64 = 15_000_000_000

    // Requests a short-lived provider credential through the encrypted, paired bridge.
    // The credential is kept in memory only for the lifetime of the voice connection.
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
              let clientSecret = result["clientSecret"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientSecret.isEmpty,
              let expiresAtSeconds = result["expiresAt"]?.doubleValue,
              expiresAtSeconds.isFinite else {
            throw CodexServiceError.invalidResponse("The bridge returned an invalid live Voice session.")
        }

        let expiresAt = Date(timeIntervalSince1970: expiresAtSeconds)
        guard expiresAt > Date() else {
            throw CodexServiceError.invalidResponse("The bridge returned an expired live Voice session.")
        }

        return CodexRealtimeVoiceSession(clientSecret: clientSecret, expiresAt: expiresAt)
    }

    // Obtains a fresh bridge credential and opens the provider connection without
    // sending microphone data or transcript events yet.
    func openRealtimeVoiceConnection(threadID: String) async throws -> CodexRealtimeVoiceConnection {
        let session = try await requestRealtimeVoiceSession(threadID: threadID)
        let connection = CodexRealtimeVoiceConnection(session: session)
        try await connection.connect()
        return connection
    }
}
