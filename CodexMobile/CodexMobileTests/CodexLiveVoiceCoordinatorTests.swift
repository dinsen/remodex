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
        let connection = CodexRealtimeVoiceConnection(
            session: CodexRealtimeVoiceSession(
                sessionID: "live-session-test",
                expiresAt: Date().addingTimeInterval(60),
                model: "gpt-live-1"
            )
        ) { method, params in
            sentMethods.append(method)
            sentParams.append(params)
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
        await Task.yield()

        XCTAssertEqual(sentMethods, ["voice/realtime/audio"])
        XCTAssertEqual(
            sentParams.first?.objectValue?[
                "sessionId"
            ]?.stringValue,
            "live-session-test"
        )
        XCTAssertEqual(
            sentParams.first?.objectValue?["audio"]?.stringValue,
            Data([0x01, 0x02, 0x03, 0x04]).base64EncodedString()
        )

        coordinator.stop()
    }

    func testDelayedBridgeSenderKeepsCaptureQueueBounded() async throws {
        var sendCount = 0
        var releaseFirstSend: CheckedContinuation<RPCMessage, Never>?
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
        for _ in 0..<4 {
            await Task.yield()
        }

        XCTAssertLessThanOrEqual(coordinator.pendingAudioChunkCount, 8)
        releaseFirstSend?.resume(returning: RPCMessage(
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
        coordinator.handleProviderEvent(.object([
            "type": .string("session.output_audio.delta"),
            "delta": .string(pcm.base64EncodedString()),
        ]))

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

    func enqueuePCM16(_ data: Data) {
        chunks.append(data)
    }

    func stop() {}
}
