// FILE: CodexLiveVoiceCoordinatorTests.swift
// Purpose: Verifies the contained live-voice media boundary without opening a
// real microphone, speaker, relay, or OpenAI connection.
// Layer: Unit Test
// Exports: CodexLiveVoiceCoordinatorTests

import XCTest
import AVFAudio
@testable import CodexMobile

@MainActor
final class CodexLiveVoiceCoordinatorTests: XCTestCase {
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

    func testCaptureChunkIsEncodedAndSentThroughBridgeConnection() async throws {
        var sentMethods: [String] = []
        var sentParams: [JSONValue?] = []
        let audioSentExpectation = expectation(description: "audio chunk reaches bridge sender")
        audioSentExpectation.assertForOverFulfill = true
        let connection = CodexRealtimeVoiceConnection(
            session: CodexRealtimeVoiceSession(
                sessionID: "live-session-test",
                expiresAt: Date().addingTimeInterval(60),
                model: "gpt-live-1"
            )
        ) { method, params in
            sentMethods.append(method)
            sentParams.append(params)
            if method == "voice/realtime/audio" {
                audioSentExpectation.fulfill()
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }
        let capture = FakeLiveVoiceCapture()
        let playback = FakeLiveVoicePlayback()
        let coordinator = CodexLiveVoiceCoordinator(
            connection: connection,
            capture: capture,
            playback: playback
        )

        try await connection.connect()
        try coordinator.start()
        capture.emit(Data([0x01, 0x02, 0x03, 0x04]))
        await fulfillment(of: [audioSentExpectation], timeout: 1)

        XCTAssertEqual(sentMethods, ["voice/realtime/audio"])
        let sentParameters = try XCTUnwrap(sentParams.first ?? nil)
        XCTAssertEqual(
            sentParameters.objectValue?["sessionId"]?.stringValue,
            "live-session-test"
        )
        XCTAssertEqual(
            sentParameters.objectValue?["audio"]?.stringValue,
            Data([0x01, 0x02, 0x03, 0x04]).base64EncodedString()
        )

        coordinator.stop()
    }

    func testDelayedBridgeSenderKeepsCaptureQueueBounded() async throws {
        var sendCount = 0
        var releaseFirstSend: CheckedContinuation<RPCMessage, Never>?
        let firstAudioSendEntered = expectation(description: "first audio send is held by the bridge")
        firstAudioSendEntered.assertForOverFulfill = true
        let connection = CodexRealtimeVoiceConnection(
            session: CodexRealtimeVoiceSession(
                sessionID: "live-session-test",
                expiresAt: Date().addingTimeInterval(60),
                model: "gpt-live-1"
            )
        ) { method, _ in
            sendCount += 1
            if method == "voice/realtime/audio", sendCount == 1 {
                return await withCheckedContinuation { continuation in
                    releaseFirstSend = continuation
                    firstAudioSendEntered.fulfill()
                }
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }
        let capture = FakeLiveVoiceCapture()
        let playback = FakeLiveVoicePlayback()
        let coordinator = CodexLiveVoiceCoordinator(
            connection: connection,
            capture: capture,
            playback: playback
        )

        try await connection.connect()
        try coordinator.start()
        for index in 0..<64 {
            capture.emit(Data([UInt8(index & 0xff), 0x00]))
        }
        await fulfillment(of: [firstAudioSendEntered], timeout: 1)

        XCTAssertEqual(sendCount, 1)
        XCTAssertLessThanOrEqual(coordinator.pendingAudioChunkCount, 8)
        let firstSendContinuation = try XCTUnwrap(releaseFirstSend)
        releaseFirstSend = nil
        firstSendContinuation.resume(returning: RPCMessage(
            id: .string("released"),
            result: .object([:]),
            includeJSONRPC: false
        ))
        coordinator.stop()
    }

    func testProviderOutputAudioDeltaIsRoutedToPlayback() async throws {
        let connection = CodexRealtimeVoiceConnection(
            session: CodexRealtimeVoiceSession(
                sessionID: "live-session-test",
                expiresAt: Date().addingTimeInterval(60),
                model: "gpt-live-1"
            )
        ) { _, _ in
            RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }
        let capture = FakeLiveVoiceCapture()
        let playback = FakeLiveVoicePlayback()
        let coordinator = CodexLiveVoiceCoordinator(
            connection: connection,
            capture: capture,
            playback: playback
        )

        try await connection.connect()
        try coordinator.start()
        let pcm = Data([0x10, 0x11, 0x12, 0x13])
        let playbackExpectation = expectation(description: "decoded provider audio reaches playback")
        playback.onEnqueue = { playbackExpectation.fulfill() }
        coordinator.handleProviderEvent(.object([
            "type": .string("session.output_audio.delta"),
            "delta": .string(pcm.base64EncodedString()),
        ]))

        await fulfillment(of: [playbackExpectation], timeout: 1)
        XCTAssertEqual(playback.chunks, [pcm])
        coordinator.stop()
    }
}

@MainActor
private final class FakeLiveVoiceCapture: CodexLiveVoiceCapture {
    var onPCM16Chunk: (@MainActor (Data) -> Void)?

    func start() throws {}
    func stop() {}

    func emit(_ data: Data) {
        onPCM16Chunk?(data)
    }
}

@MainActor
private final class FakeLiveVoicePlayback: CodexLiveVoicePlayback {
    var chunks: [Data] = []
    var onEnqueue: (@MainActor () -> Void)?

    func enqueuePCM16(_ data: Data) {
        chunks.append(data)
        onEnqueue?()
    }

    func stop() {}
}
