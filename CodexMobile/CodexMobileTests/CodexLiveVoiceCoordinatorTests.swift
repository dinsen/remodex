// FILE: CodexLiveVoiceCoordinatorTests.swift
// Purpose: Verifies the contained live-voice media boundary without opening a
// real microphone, speaker, relay, or OpenAI connection.
// Layer: Unit Test
// Exports: CodexLiveVoiceCoordinatorTests, FakeLiveVoiceWebSocket

import Foundation
import XCTest
import AVFAudio
@testable import CodexMobile

@MainActor
final class CodexLiveVoiceCoordinatorTests: XCTestCase {
    func testLiveVoiceRedirectPolicyAllowsOnlyTheFixedOpenAIWebSocketEndpoint() {
        XCTAssertTrue(CodexLiveVoiceRedirectPolicy.permits(URL(string: "wss://api.openai.com/v1/live/sessions")))
        XCTAssertTrue(CodexLiveVoiceRedirectPolicy.permits(URL(string: "wss://api.openai.com:443/v1/live/sessions")))
        XCTAssertFalse(CodexLiveVoiceRedirectPolicy.permits(URL(string: "wss://attacker.example/v1/live/sessions")))
        XCTAssertFalse(CodexLiveVoiceRedirectPolicy.permits(URL(string: "ws://api.openai.com/v1/live/sessions")))
        XCTAssertFalse(CodexLiveVoiceRedirectPolicy.permits(URL(string: "https://api.openai.com/v1/live/sessions")))
        XCTAssertFalse(CodexLiveVoiceRedirectPolicy.permits(URL(string: "wss://api.openai.com/v1/other")))
        XCTAssertFalse(CodexLiveVoiceRedirectPolicy.permits(URL(string: "wss://user@api.openai.com/v1/live/sessions")))
    }

    func testCaptureFastPathRequiresTheGPTLiveInputSampleRate() {
        let liveFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
        let hardwareFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        )!

        XCTAssertTrue(AVAudioLiveVoiceCapture.canUsePCM16FastPath(liveFormat))
        XCTAssertFalse(AVAudioLiveVoiceCapture.canUsePCM16FastPath(hardwareFormat))
    }

    func testCaptureChunkGoesDirectlyToProviderAndBridgeReceivesNoAudio() async throws {
        var bridgeMethods: [String] = []
        var bridgeParameters: [JSONValue?] = []
        var providerRequest: URLRequest?
        let providerSocket = FakeLiveVoiceWebSocket()
        let audioSentExpectation = expectation(description: "audio chunk reaches the provider socket")
        let transcriptForwardedExpectation = expectation(description: "transcript metadata reaches the bridge")
        let bridgeCloseExpectation = expectation(description: "bridge session is closed")
        providerSocket.onSend = { text in
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            if event.objectValue?["type"]?.stringValue == "session.input_audio.append" {
                audioSentExpectation.fulfill()
            }
        }

        let connection = CodexRealtimeVoiceConnection(
            session: makeSession(),
            apiKeyProvider: { "unit-test-key" },
            webSocketFactory: { request in
                providerRequest = request
                return providerSocket
            }
        ) { method, params in
            bridgeMethods.append(method)
            bridgeParameters.append(params)
            if method == "voice/realtime/device/event",
               params?.objectValue?["event"]?.objectValue?["type"]?.stringValue == "session.input_transcript.delta" {
                transcriptForwardedExpectation.fulfill()
            }
            if method == "voice/realtime/device/close" {
                bridgeCloseExpectation.fulfill()
            }
            return successResponse()
        }
        let capture = FakeLiveVoiceCapture()
        let coordinator = CodexLiveVoiceCoordinator(
            connection: connection,
            capture: capture,
            playback: FakeLiveVoicePlayback()
        )

        try await connection.connect()
        try coordinator.start()
        capture.emit(Data([0x01, 0x02, 0x03, 0x04]))
        await fulfillment(of: [audioSentExpectation], timeout: 1)

        let audioEvent = try XCTUnwrap(providerSocket.sentEvents.first {
            $0.objectValue?["type"]?.stringValue == "session.input_audio.append"
        })
        XCTAssertEqual(audioEvent.objectValue?["audio"]?.stringValue, Data([0x01, 0x02, 0x03, 0x04]).base64EncodedString())
        XCTAssertTrue(bridgeMethods.isEmpty)
        XCTAssertEqual(providerRequest?.url?.absoluteString, "wss://api.openai.com/v1/live/sessions")
        XCTAssertEqual(providerRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-key")
        XCTAssertTrue(providerRequest?.value(forHTTPHeaderField: "OpenAI-Safety-Identifier")?.hasPrefix("remodex-") == true)

        providerSocket.emit(.object([
            "type": .string("session.input_transcript.delta"),
            "event_id": .string("input-1"),
            "start_ms": .integer(10),
            "end_ms": .integer(100),
            "delta": .string("Check the branch."),
        ]))
        await fulfillment(of: [transcriptForwardedExpectation], timeout: 1)
        let transcriptParams = try XCTUnwrap(bridgeParameters.first ?? nil)
        XCTAssertEqual(transcriptParams.objectValue?["sessionId"]?.stringValue, "device-session-test")
        XCTAssertEqual(
            transcriptParams.objectValue?["event"]?.objectValue?["delta"]?.stringValue,
            "Check the branch."
        )
        XCTAssertEqual(bridgeMethods, ["voice/realtime/device/event"])

        coordinator.stop()
        await fulfillment(of: [bridgeCloseExpectation], timeout: 1)
        XCTAssertEqual(bridgeMethods, ["voice/realtime/device/event", "voice/realtime/device/close"])
        let bridgePayload = try JSONEncoder().encode(JSONValue.array(bridgeParameters.compactMap { $0 }))
        let bridgePayloadText = String(decoding: bridgePayload, as: UTF8.self)
        XCTAssertFalse(bridgePayloadText.contains("audio"))
        XCTAssertFalse(bridgePayloadText.contains("unit-test-key"))
        XCTAssertFalse(bridgePayloadText.contains(Data([0x01, 0x02, 0x03, 0x04]).base64EncodedString()))
    }

    func testStopClosesBridgeBeforeProviderDrainAndWaitsForCloseConfirmation() async throws {
        var bridgeMethods: [String] = []
        var pendingDelegationIDs = Set<String>()
        var pendingDelegationsAtProviderClose = Set<String>()
        var providerCloseWasSentAfterBridgeClose = false
        let providerSocket = FakeLiveVoiceWebSocket(autoCloseOnCloseEvent: false)
        let delegationForwarded = expectation(description: "pending delegation reaches the bridge")
        let closeSent = expectation(description: "provider session close is sent")
        let bridgeClose = expectation(description: "device bridge session is closed before provider drain")
        let providerSocketClosed = expectation(description: "provider socket closes after acknowledgement")
        providerSocket.onClose = { providerSocketClosed.fulfill() }
        providerSocket.onSend = { text in
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            if event.objectValue?["type"]?.stringValue == "session.close" {
                providerCloseWasSentAfterBridgeClose = bridgeMethods.contains("voice/realtime/device/close")
                pendingDelegationsAtProviderClose = pendingDelegationIDs
                closeSent.fulfill()
            }
        }
        let connection = CodexRealtimeVoiceConnection(
            session: makeSession(),
            apiKeyProvider: { "unit-test-key" },
            webSocketFactory: { _ in providerSocket }
        ) { method, _ in
            bridgeMethods.append(method)
            if method == "voice/realtime/device/event" {
                pendingDelegationIDs.insert("delegation-pending")
                delegationForwarded.fulfill()
            } else if method == "voice/realtime/device/close" {
                pendingDelegationIDs.removeAll()
                bridgeClose.fulfill()
            }
            return successResponse()
        }
        let capture = FakeLiveVoiceCapture()
        let playback = FakeLiveVoicePlayback()
        let coordinator = CodexLiveVoiceCoordinator(connection: connection, capture: capture, playback: playback)

        try await connection.connect()
        try coordinator.start()
        providerSocket.emit(.object([
            "type": .string("session.delegation.created"),
            "event_id": .string("delegation-event"),
            "offset_ms": .integer(500),
            "delegation": .object([
                "id": .string("delegation-pending"),
                "type": .string("delegation"),
                "target": .string("client"),
            ]),
        ]))
        await fulfillment(of: [delegationForwarded], timeout: 1)
        XCTAssertEqual(pendingDelegationIDs, ["delegation-pending"])

        coordinator.stop()

        XCTAssertFalse(capture.isRunning)
        XCTAssertTrue(playback.isStopped)
        XCTAssertEqual(connection.state, .closing)
        XCTAssertNil(connection.providerCloseFinalizationConfirmed)
        await fulfillment(of: [bridgeClose, closeSent], timeout: 1)
        XCTAssertEqual(providerSocket.sentEvents.last?.objectValue?["type"]?.stringValue, "session.close")
        XCTAssertEqual(providerSocket.closeCallCount, 0, "provider socket remains open for the close acknowledgement")
        XCTAssertTrue(providerCloseWasSentAfterBridgeClose)
        XCTAssertTrue(pendingDelegationsAtProviderClose.isEmpty, "bridge close discards pending work before provider drain")
        XCTAssertTrue(pendingDelegationIDs.isEmpty)
        XCTAssertEqual(
            bridgeMethods,
            ["voice/realtime/device/event", "voice/realtime/device/close"]
        )

        providerSocket.emit(.object(["type": .string("session.closed")]))
        await fulfillment(of: [providerSocketClosed], timeout: 1)
        XCTAssertEqual(connection.state, .closed)
        XCTAssertEqual(connection.providerCloseFinalizationConfirmed, true)
        XCTAssertEqual(providerSocket.closeCallCount, 1)
        XCTAssertEqual(bridgeMethods, ["voice/realtime/device/event", "voice/realtime/device/close"])
    }

    func testStopForcesSocketCloseAndMarksProviderFinalizationUnconfirmedAfterTimeout() async throws {
        let providerSocket = FakeLiveVoiceWebSocket(autoCloseOnCloseEvent: false)
        let closeSent = expectation(description: "provider session close is sent")
        let providerSocketClosed = expectation(description: "timeout finalizes and closes the provider socket")
        providerSocket.onClose = { providerSocketClosed.fulfill() }
        providerSocket.onSend = { text in
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            if event.objectValue?["type"]?.stringValue == "session.close" {
                closeSent.fulfill()
            }
        }
        let connection = CodexRealtimeVoiceConnection(
            session: makeSession(),
            apiKeyProvider: { "unit-test-key" },
            webSocketFactory: { _ in providerSocket },
            providerCloseTimeoutNanoseconds: 30_000_000
        ) { _, _ in successResponse() }
        let coordinator = CodexLiveVoiceCoordinator(
            connection: connection,
            capture: FakeLiveVoiceCapture(),
            playback: FakeLiveVoicePlayback()
        )

        try await connection.connect()
        try coordinator.start()
        coordinator.stop()
        await fulfillment(of: [closeSent, providerSocketClosed], timeout: 1)

        XCTAssertEqual(connection.state, .closed)
        XCTAssertEqual(connection.providerCloseFinalizationConfirmed, false)
        XCTAssertEqual(providerSocket.closeCallCount, 1, "timeout forces the provider socket closed")
    }

    func testLateProviderCloseSendAfterTimeoutDoesNotWaitOrRetainConnection() async throws {
        var releaseCloseSend: CheckedContinuation<Void, Never>?
        let closeSendEntered = expectation(description: "provider close send is held")
        let providerSocketClosed = expectation(description: "timeout closes the held provider socket")
        let providerSocket = FakeLiveVoiceWebSocket(autoCloseOnCloseEvent: false)
        providerSocket.onClose = { providerSocketClosed.fulfill() }
        providerSocket.onSend = { text in
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            guard event.objectValue?["type"]?.stringValue == "session.close" else { return }
            await withCheckedContinuation { continuation in
                releaseCloseSend = continuation
                closeSendEntered.fulfill()
            }
        }

        var connection: CodexRealtimeVoiceConnection? = CodexRealtimeVoiceConnection(
            session: makeSession(),
            apiKeyProvider: { "unit-test-key" },
            webSocketFactory: { _ in providerSocket },
            providerCloseTimeoutNanoseconds: 30_000_000
        ) { _, _ in successResponse() }
        weak var weakConnection = connection
        let coordinator = CodexLiveVoiceCoordinator(
            connection: try XCTUnwrap(connection),
            capture: FakeLiveVoiceCapture(),
            playback: FakeLiveVoicePlayback()
        )

        try await XCTUnwrap(connection).connect()
        try coordinator.start()
        connection?.close()
        await fulfillment(of: [closeSendEntered, providerSocketClosed], timeout: 1)

        XCTAssertEqual(try XCTUnwrap(connection).state, .closed)
        XCTAssertEqual(try XCTUnwrap(connection).providerCloseFinalizationConfirmed, false)
        XCTAssertEqual(providerSocket.closeCallCount, 1)

        connection = nil
        releaseCloseSend?.resume()
        releaseCloseSend = nil

        let releaseDeadline = ContinuousClock().now.advanced(by: .seconds(1))
        while weakConnection != nil && ContinuousClock().now < releaseDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(weakConnection, "a late successful send must not leave a close wait retaining the connection")
    }

    func testBridgeTerminalEventClosesPhoneProviderAndStopsMedia() async throws {
        let providerSocket = FakeLiveVoiceWebSocket()
        let terminal = expectation(description: "bridge expiry terminates the phone session")
        let capture = FakeLiveVoiceCapture()
        let playback = FakeLiveVoicePlayback()
        let connection = CodexRealtimeVoiceConnection(
            session: makeSession(),
            apiKeyProvider: { "unit-test-key" },
            webSocketFactory: { _ in providerSocket }
        ) { _, _ in successResponse() }
        let coordinator = CodexLiveVoiceCoordinator(connection: connection, capture: capture, playback: playback)
        connection.addTerminalHandler { terminal.fulfill() }

        try await connection.connect()
        try coordinator.start()
        connection.handleBridgeEvent(.object([
            "type": .string("session.closed"),
            "event_id": .string("bridge-expiry"),
            "reason": .string("expired"),
        ]))
        await fulfillment(of: [terminal], timeout: 1)

        XCTAssertFalse(capture.isRunning)
        XCTAssertTrue(playback.isStopped)
        XCTAssertEqual(providerSocket.sentEvents.last?.objectValue?["type"]?.stringValue, "session.close")
        XCTAssertEqual(connection.state, .closed)
    }

    func testPhoneSessionExpiryClosesProviderAndBridgeSession() async throws {
        let providerSocket = FakeLiveVoiceWebSocket()
        let bridgeClose = expectation(description: "expired phone session closes bridge state")
        let terminal = expectation(description: "phone expiry terminates the direct provider session")
        let capture = FakeLiveVoiceCapture()
        let playback = FakeLiveVoicePlayback()
        let connection = CodexRealtimeVoiceConnection(
            session: CodexRealtimeVoiceSession(
                sessionID: "device-session-expiry",
                expiresAt: Date().addingTimeInterval(0.2),
                model: "gpt-live-1"
            ),
            apiKeyProvider: { "unit-test-key" },
            webSocketFactory: { _ in providerSocket }
        ) { method, _ in
            if method == "voice/realtime/device/close" {
                bridgeClose.fulfill()
            }
            return successResponse()
        }
        let coordinator = CodexLiveVoiceCoordinator(connection: connection, capture: capture, playback: playback)
        connection.addTerminalHandler { terminal.fulfill() }

        try await connection.connect()
        try coordinator.start()
        await fulfillment(of: [terminal, bridgeClose], timeout: 1)

        XCTAssertFalse(capture.isRunning)
        XCTAssertTrue(playback.isStopped)
        XCTAssertTrue(providerSocket.sentEvents.contains {
            $0.objectValue?["type"]?.stringValue == "session.close"
        })
        XCTAssertEqual(connection.providerCloseFinalizationConfirmed, true)
    }

    func testDelayedProviderSendKeepsCaptureQueueBounded() async throws {
        var releaseFirstSend: CheckedContinuation<Void, Never>?
        var audioSendCount = 0
        let firstAudioSendEntered = expectation(description: "first provider audio send is held")
        let bridgeCloseExpectation = expectation(description: "bridge session is closed")
        let providerSocket = FakeLiveVoiceWebSocket()
        providerSocket.onSend = { text in
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            guard event.objectValue?["type"]?.stringValue == "session.input_audio.append" else { return }
            audioSendCount += 1
            if audioSendCount == 1 {
                await withCheckedContinuation { continuation in
                    releaseFirstSend = continuation
                    firstAudioSendEntered.fulfill()
                }
            }
        }
        let connection = CodexRealtimeVoiceConnection(
            session: makeSession(),
            apiKeyProvider: { "unit-test-key" },
            webSocketFactory: { _ in providerSocket }
        ) { method, _ in
            if method == "voice/realtime/device/close" {
                bridgeCloseExpectation.fulfill()
            }
            return successResponse()
        }
        let capture = FakeLiveVoiceCapture()
        let coordinator = CodexLiveVoiceCoordinator(
            connection: connection,
            capture: capture,
            playback: FakeLiveVoicePlayback()
        )

        try await connection.connect()
        try coordinator.start()
        for index in 0..<64 {
            capture.emit(Data([UInt8(index & 0xff), 0x00]))
        }
        await fulfillment(of: [firstAudioSendEntered], timeout: 1)

        XCTAssertEqual(audioSendCount, 1)
        XCTAssertLessThanOrEqual(coordinator.pendingAudioChunkCount, 8)
        let firstSendContinuation = try XCTUnwrap(releaseFirstSend)
        releaseFirstSend = nil
        firstSendContinuation.resume()
        coordinator.stop()
        await fulfillment(of: [bridgeCloseExpectation], timeout: 1)
    }

    func testProviderOutputAudioDeltaIsRoutedToPlayback() async throws {
        let providerSocket = FakeLiveVoiceWebSocket()
        let connection = CodexRealtimeVoiceConnection(
            session: makeSession(),
            apiKeyProvider: { "unit-test-key" },
            webSocketFactory: { _ in providerSocket }
        ) { _, _ in
            successResponse()
        }
        let capture = FakeLiveVoiceCapture()
        let playback = FakeLiveVoicePlayback()
        let coordinator = CodexLiveVoiceCoordinator(
            connection: connection,
            capture: capture,
            playback: playback
        )
        connection.attachLiveVoiceCoordinator(coordinator)
        connection.setProviderEventHandler { [weak coordinator] event in
            coordinator?.handleProviderEvent(event)
        }

        try await connection.connect()
        try coordinator.start()
        let pcm = Data([0x10, 0x11, 0x12, 0x13])
        let playbackExpectation = expectation(description: "provider audio reaches playback")
        playback.onEnqueue = { playbackExpectation.fulfill() }
        providerSocket.emit(.object([
            "type": .string("session.output_audio.delta"),
            "delta": .string(pcm.base64EncodedString()),
        ]))

        await fulfillment(of: [playbackExpectation], timeout: 1)
        XCTAssertEqual(playback.chunks, [pcm])

        coordinator.stop()
    }

    private func makeSession() -> CodexRealtimeVoiceSession {
        CodexRealtimeVoiceSession(
            sessionID: "device-session-test",
            expiresAt: Date().addingTimeInterval(60),
            model: "gpt-live-1"
        )
    }

    private func successResponse() -> RPCMessage {
        RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
    }
}

@MainActor
final class FakeLiveVoiceWebSocket: CodexLiveVoiceWebSocket {
    private var iterator: AsyncStream<String>.Iterator
    private let continuation: AsyncStream<String>.Continuation
    private var didResume = false
    private var didClose = false
    private let autoCloseOnCloseEvent: Bool
    private(set) var closeCallCount = 0
    var sentEvents: [JSONValue] = []
    var onClose: (@MainActor () -> Void)?
    var onSend: (@MainActor (String) async throws -> Void)?

    init(autoCloseOnCloseEvent: Bool = true) {
        self.autoCloseOnCloseEvent = autoCloseOnCloseEvent
        let streamPair = AsyncStream<String>.makeStream()
        iterator = streamPair.stream.makeAsyncIterator()
        continuation = streamPair.continuation
    }

    func resume() {
        guard !didResume else { return }
        didResume = true
        emit(.object(["type": .string("session.started")]))
    }

    func send(text: String) async throws {
        if let event = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
            sentEvents.append(event)
        }
        try await onSend?(text)
        if autoCloseOnCloseEvent,
           sentEvents.last?.objectValue?["type"]?.stringValue == "session.close" {
            emit(.object(["type": .string("session.closed")]))
        }
    }

    func receiveText() async throws -> String {
        guard let text = await iterator.next() else {
            throw CodexServiceError.disconnected
        }
        return text
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        closeCallCount += 1
        onClose?()
        continuation.finish()
    }

    func emit(_ event: JSONValue) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        continuation.yield(String(decoding: data, as: UTF8.self))
    }
}

@MainActor
private final class FakeLiveVoiceCapture: CodexLiveVoiceCapture {
    var onPCM16Chunk: (@MainActor (Data) -> Void)?
    private(set) var isRunning = false

    func start() throws { isRunning = true }
    func stop() { isRunning = false }

    func emit(_ data: Data) {
        onPCM16Chunk?(data)
    }
}

@MainActor
private final class FakeLiveVoicePlayback: CodexLiveVoicePlayback {
    var chunks: [Data] = []
    var onEnqueue: (@MainActor () -> Void)?
    private(set) var isStopped = false

    func enqueuePCM16(_ data: Data) {
        chunks.append(data)
        onEnqueue?()
    }

    func stop() { isStopped = true }
}
