// FILE: CodexTransferWork.swift
// Purpose: Provides an explicit serial off-main executor for CPU and file transfer preparation.
// Layer: Service support
// Depends on: Foundation, Dispatch

import Dispatch
import CryptoKit
import Foundation
import Security

nonisolated func codexSecureNonce(sender: String, counter: Int) -> Data {
    var nonce = Data(repeating: 0, count: 12)
    nonce[0] = sender == "mac" ? 1 : 2
    var remaining = UInt64(counter)
    for index in stride(from: 11, through: 1, by: -1) {
        nonce[index] = UInt8(remaining & 0xff)
        remaining >>= 8
    }
    return nonce
}

nonisolated final class CodexTransferSerialExecutor: SerialExecutor, Sendable {
    static let shared = CodexTransferSerialExecutor()

    let queue = DispatchQueue(
        label: "io.m10s.remodex.transfer-codec",
        qos: .userInitiated
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            #if DEBUG
            precondition(!Thread.isMainThread, "Codex transfer preparation must not run on the main thread")
            #endif
            unownedJob.runSynchronously(on: executor)
        }
    }
}

/// Runs immutable transfer preparation on a dedicated serial background queue.
///
/// Network APIs remain asynchronous and are not routed through this queue. Callers keep
/// actor-owned state on their actor, pass only Sendable snapshots into `run`, and apply the
/// resulting immutable value after the await. Serial execution also preserves codec order
/// for callers that enqueue work in wire order.
nonisolated enum CodexTransferWork {
    @MainActor
    static func makeEncoderCopy(from source: JSONEncoder) -> JSONEncoder {
        let copy = JSONEncoder()
        copy.dateEncodingStrategy = source.dateEncodingStrategy
        copy.dataEncodingStrategy = source.dataEncodingStrategy
        copy.nonConformingFloatEncodingStrategy = source.nonConformingFloatEncodingStrategy
        copy.keyEncodingStrategy = source.keyEncodingStrategy
        copy.outputFormatting = source.outputFormatting
        copy.userInfo = source.userInfo
        return copy
    }

    @MainActor
    static func makeDecoderCopy(from source: JSONDecoder) -> JSONDecoder {
        let copy = JSONDecoder()
        copy.dateDecodingStrategy = source.dateDecodingStrategy
        copy.dataDecodingStrategy = source.dataDecodingStrategy
        copy.nonConformingFloatDecodingStrategy = source.nonConformingFloatDecodingStrategy
        copy.keyDecodingStrategy = source.keyDecodingStrategy
        copy.userInfo = source.userInfo
        return copy
    }

    static func assertOffMainThread() {
        #if DEBUG
        precondition(!Thread.isMainThread, "Codex transfer preparation must not run on the main thread")
        #endif
    }

    static func run<Output: Sendable>(
        _ operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            CodexTransferSerialExecutor.shared.queue.async {
                assertOffMainThread()

                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs independent media work away from MainActor without serializing it behind ordered
    /// transport encoding, encryption, or receive decoding.
    static func runMedia<Output: Sendable>(
        _ operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                assertOffMainThread()

                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func prepareWebSocketText(
        _ text: String,
        manual: Bool,
        needsUTF8Data: Bool,
        maximumSize: Int
    ) async throws -> CodexPreparedWebSocketText {
        try await run {
            guard text.utf8.count <= maximumSize else {
                throw CodexTransferPreparationError.messageTooLarge
            }
            let data = (manual || needsUTF8Data) ? Data(text.utf8) : nil
            let frame = try manual ? maskedWebSocketFrame(opcode: 0x1, payload: data ?? Data()) : nil
            return CodexPreparedWebSocketText(utf8Data: data, manualFrame: frame)
        }
    }

    static func decodeUTF8(_ data: Data) async -> String? {
        try? await run {
            String(data: data, encoding: .utf8)
        }
    }

    static func encodeBase64(_ data: Data) async throws -> String {
        try await run {
            data.base64EncodedString()
        }
    }

    static func decodeBase64(_ value: String) async -> Data? {
        try? await run {
            Data(base64Encoded: value)
        }
    }

    static func trimWhitespace(_ value: String) async throws -> String {
        try await run {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func makeManualWebSocketFrame(opcode: UInt8, payload: Data) async throws -> Data {
        try await run {
            try maskedWebSocketFrame(opcode: opcode, payload: payload)
        }
    }

    static func parseManualWebSocketFrames(from data: Data) async throws -> CodexManualWebSocketFrameBatch {
        try await run {
            var remainingData = data
            var frames: [CodexManualWebSocketFrame] = []
            while let frame = parseManualWebSocketFrame(from: &remainingData) {
                frames.append(frame)
            }
            return CodexManualWebSocketFrameBatch(frames: frames, remainingData: remainingData)
        }
    }

    static func parseManualWebSocketFrames(
        from existingData: Data,
        appending newData: Data
    ) async throws -> CodexManualWebSocketFrameBatch {
        try await run {
            var remainingData = existingData
            remainingData.append(newData)
            var frames: [CodexManualWebSocketFrame] = []
            while let frame = parseManualWebSocketFrame(from: &remainingData) {
                frames.append(frame)
            }
            return CodexManualWebSocketFrameBatch(frames: frames, remainingData: remainingData)
        }
    }

    static func parseManualWebSocketFrames(from wireParts: [Data]) async throws -> CodexManualWebSocketFrameBatch {
        try await run {
            var wireData = Data()
            for part in wireParts {
                wireData.append(part)
            }

            var remainingData = wireData
            var frames: [CodexManualWebSocketFrame] = []
            while let frame = parseManualWebSocketFrame(from: &remainingData) {
                frames.append(frame)
            }
            return CodexManualWebSocketFrameBatch(frames: frames, remainingData: remainingData)
        }
    }

    private static func maskedWebSocketFrame(opcode: UInt8, payload: Data) throws -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)

        let maskBit: UInt8 = 0x80
        if payload.count < 126 {
            frame.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(maskBit | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(maskBit | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }

        var mask = [UInt8](repeating: 0, count: 4)
        guard SecRandomCopyBytes(kSecRandomDefault, mask.count, &mask) == errSecSuccess else {
            throw CodexTransferPreparationError.randomSourceFailed
        }
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }
        return frame
    }

    private static func parseManualWebSocketFrame(
        from buffer: inout Data
    ) -> CodexManualWebSocketFrame? {
        guard buffer.count >= 2 else { return nil }

        let firstByte = buffer[buffer.startIndex]
        let secondByte = buffer[buffer.startIndex + 1]
        let opcode = firstByte & 0x0F
        let masked = (secondByte & 0x80) != 0

        var index = 2
        var payloadLength = Int(secondByte & 0x7F)
        if payloadLength == 126 {
            guard buffer.count >= index + 2 else { return nil }
            payloadLength = Int(buffer[index]) << 8 | Int(buffer[index + 1])
            index += 2
        } else if payloadLength == 127 {
            guard buffer.count >= index + 8 else { return nil }
            var decodedLength: UInt64 = 0
            for offset in 0..<8 {
                decodedLength = (decodedLength << 8) | UInt64(buffer[index + offset])
            }
            guard decodedLength <= UInt64(Int.max) else { return nil }
            payloadLength = Int(decodedLength)
            index += 8
        }

        var maskKey = Data()
        if masked {
            guard buffer.count >= index + 4 else { return nil }
            maskKey = buffer.subdata(in: index..<(index + 4))
            index += 4
        }

        guard buffer.count >= index + payloadLength else { return nil }
        let wireData = buffer.subdata(in: 0..<(index + payloadLength))
        var payload = buffer.subdata(in: index..<(index + payloadLength))
        buffer.removeSubrange(0..<(index + payloadLength))

        if masked {
            let maskBytes = [UInt8](maskKey)
            var payloadBytes = [UInt8](payload)
            for offset in payloadBytes.indices {
                payloadBytes[offset] ^= maskBytes[offset % 4]
            }
            payload = Data(payloadBytes)
        }

        return CodexManualWebSocketFrame(opcode: opcode, payload: payload, wireData: wireData)
    }
}

/// Owns transport-only JSON coders on the transfer executor.
///
/// The service keeps its injected coders for MainActor persistence. A configuration copy is
/// created at initialization so transport encode/decode retains custom strategies and userInfo
/// without sharing the coder instances across executors. Objects stored in `userInfo` remain
/// shared references and therefore must be safe for transport-thread access.
actor CodexTransferJSONCodec {
    nonisolated let executor = CodexTransferSerialExecutor.shared

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(encoder: sending JSONEncoder, decoder: sending JSONDecoder) {
        self.encoder = encoder
        self.decoder = decoder
    }

    func encode<Value: Encodable & Sendable>(_ value: Value) throws -> Data {
        CodexTransferWork.assertOffMainThread()
        return try encoder.encode(value)
    }

    func decode<Value: Decodable & Sendable>(_ type: Value.Type, from data: Data) throws -> Value {
        CodexTransferWork.assertOffMainThread()
        return try decoder.decode(type, from: data)
    }

    func decodeModel<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from value: JSONValue,
        omittingTopLevelKeys keysToOmit: Set<String> = []
    ) throws -> Value {
        CodexTransferWork.assertOffMainThread()
        let boundedValue: JSONValue
        if !keysToOmit.isEmpty, var object = value.objectValue {
            for key in keysToOmit {
                object.removeValue(forKey: key)
            }
            boundedValue = .object(object)
        } else {
            boundedValue = value
        }
        return try decoder.decode(type, from: encoder.encode(boundedValue))
    }

    func decodeModels<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from values: [JSONValue],
        omittingTopLevelKeys keysToOmit: Set<String> = []
    ) -> [Value?] {
        CodexTransferWork.assertOffMainThread()
        return values.map { value in
            let boundedValue: JSONValue
            if !keysToOmit.isEmpty, var object = value.objectValue {
                for key in keysToOmit {
                    object.removeValue(forKey: key)
                }
                boundedValue = .object(object)
            } else {
                boundedValue = value
            }
            guard let data = try? encoder.encode(boundedValue) else { return nil }
            return try? decoder.decode(type, from: data)
        }
    }

    func encodeText<Value: Encodable & Sendable>(_ value: Value) throws -> String {
        CodexTransferWork.assertOffMainThread()
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw CodexTransferCodecError.invalidUTF8
        }
        return text
    }

    func decodeText<Value: Decodable & Sendable>(_ type: Value.Type, from text: String) throws -> Value {
        CodexTransferWork.assertOffMainThread()
        guard let data = text.data(using: .utf8) else {
            throw CodexTransferCodecError.invalidUTF8
        }
        return try decoder.decode(type, from: data)
    }

    func sealSecureText(
        _ plaintext: String,
        session: CodexSecureOutboundSnapshot
    ) -> CodexSecureSealOutcome {
        CodexTransferWork.assertOffMainThread()
        let applicationPayload = SecureApplicationPayload(
            bridgeOutboundSeq: nil,
            payloadText: plaintext
        )
        let payloadData: Data
        let sealedBox: AES.GCM.SealedBox
        do {
            payloadData = try encoder.encode(applicationPayload)
            let nonce = try AES.GCM.Nonce(data: codexSecureNonce(sender: "iphone", counter: session.counter))
            sealedBox = try AES.GCM.seal(payloadData, using: session.key, nonce: nonce)
        } catch {
            return .failedBeforeSeal(error)
        }
        let envelope = SecureEnvelope(
            kind: "encryptedEnvelope",
            v: 2,
            sessionId: session.sessionId,
            keyEpoch: session.keyEpoch,
            sender: "iphone",
            counter: session.counter,
            ciphertext: sealedBox.ciphertext.base64EncodedString(),
            tag: sealedBox.tag.base64EncodedString()
        )
        do {
            guard let text = String(data: try encoder.encode(envelope), encoding: .utf8) else {
                return .failedAfterSeal(counter: session.counter, error: CodexTransferCodecError.invalidUTF8)
            }
            return .sealed(text: text, counter: session.counter)
        } catch {
            return .failedAfterSeal(counter: session.counter, error: error)
        }
    }

    func openSecureText(
        _ text: String,
        session: CodexSecureInboundSnapshot
    ) throws -> CodexOpenedSecureEnvelope {
        CodexTransferWork.assertOffMainThread()
        guard let data = text.data(using: .utf8),
              let envelope = try? decoder.decode(SecureEnvelope.self, from: data),
              envelope.sessionId == session.sessionId,
              envelope.keyEpoch == session.keyEpoch,
              envelope.sender == "mac",
              envelope.counter > session.lastCounter else {
            throw CodexSecureTransferCodecError.invalidEnvelope
        }

        do {
            let nonce = try AES.GCM.Nonce(data: codexSecureNonce(sender: envelope.sender, counter: envelope.counter))
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: Data(base64Encoded: envelope.ciphertext) ?? Data(),
                tag: Data(base64Encoded: envelope.tag) ?? Data()
            )
            let plaintext = try AES.GCM.open(sealedBox, using: session.key)
            let applicationPayload = try decoder.decode(SecureApplicationPayload.self, from: plaintext)
            let rpcResult: CodexSecureRPCDecodeResult
            if let rpc = try? decoder.decode(RPCMessage.self, from: Data(applicationPayload.payloadText.utf8)) {
                rpcResult = .message(rpc)
            } else {
                rpcResult = .decodeFailed
            }
            return CodexOpenedSecureEnvelope(
                counter: envelope.counter,
                bridgeOutboundSeq: applicationPayload.bridgeOutboundSeq,
                payloadText: applicationPayload.payloadText,
                rpcResult: rpcResult
            )
        } catch {
            throw CodexSecureTransferCodecError.decryptFailed
        }
    }

}

nonisolated enum CodexTransferCodecError: Error {
    case invalidUTF8
}

nonisolated enum CodexTransferPreparationError: Error {
    case messageTooLarge
    case randomSourceFailed
}

nonisolated struct CodexPreparedWebSocketText: Sendable {
    let utf8Data: Data?
    let manualFrame: Data?
}

nonisolated enum CodexTransferReceiveMode: CaseIterable, Sendable {
    case networkMessage
    case urlSessionMessage
    case manualTCPChunk
}

nonisolated struct CodexTransferReceiveToken: Sendable {
    let socketGeneration: UUID
    let mode: CodexTransferReceiveMode

    func canContinue(currentSocketGeneration: UUID) -> Bool {
        socketGeneration == currentSocketGeneration
    }

    func canApply(
        currentSocketGeneration: UUID,
        capturedSessionGeneration: UUID,
        currentSessionGeneration: UUID
    ) -> Bool {
        canContinue(currentSocketGeneration: currentSocketGeneration)
            && capturedSessionGeneration == currentSessionGeneration
    }
}

nonisolated struct CodexHistoryDecodeToken: Equatable, Sendable {
    let threadId: String
    let threadGeneration: UInt64
    let contextGeneration: UInt64
}

nonisolated enum CodexHistoryDecodeCommit {
    @MainActor
    static func commitIfCurrent(
        captured: CodexHistoryDecodeToken,
        current: CodexHistoryDecodeToken,
        taskIsCancelled: Bool,
        apply: @MainActor () -> Void
    ) -> Bool {
        guard !taskIsCancelled, captured == current else { return false }
        apply()
        return true
    }
}

nonisolated struct CodexManualWebSocketFrame: Sendable {
    let opcode: UInt8
    let payload: Data
    let wireData: Data
}

nonisolated struct CodexManualWebSocketFrameBatch: Sendable {
    let frames: [CodexManualWebSocketFrame]
    let remainingData: Data
}

nonisolated struct SecureEnvelope: Codable, Sendable {
    let kind: String
    let v: Int
    let sessionId: String
    let keyEpoch: Int
    let sender: String
    let counter: Int
    let ciphertext: String
    let tag: String
}

nonisolated struct SecureApplicationPayload: Codable, Sendable {
    let bridgeOutboundSeq: Int?
    let payloadText: String
}

nonisolated struct CodexSecureOutboundSnapshot: Sendable {
    let sessionId: String
    let keyEpoch: Int
    let counter: Int
    let key: SymmetricKey
}

nonisolated struct CodexSecureInboundSnapshot: Sendable {
    let sessionId: String
    let keyEpoch: Int
    let lastCounter: Int
    let key: SymmetricKey
}

nonisolated enum CodexSecureTransferCodecError: Error {
    case invalidEnvelope
    case decryptFailed
}

nonisolated enum CodexSecureSealOutcome: Sendable {
    case failedBeforeSeal(any Error)
    case sealed(text: String, counter: Int)
    case failedAfterSeal(counter: Int, error: any Error)
}

nonisolated enum CodexTransferSendLaneError: Error {
    case invalidated
}

nonisolated enum CodexSecureRPCDecodeResult: Sendable {
    case message(RPCMessage)
    case decodeFailed
}

nonisolated struct CodexOpenedSecureEnvelope: Sendable {
    let counter: Int
    let bridgeOutboundSeq: Int?
    let payloadText: String
    let rpcResult: CodexSecureRPCDecodeResult
}

@MainActor
final class CodexTransferSendLane {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var activePermitID: UUID?
    private var waiters: [Waiter] = []
    private var isInvalidated = false

    func withPermit<Output: Sendable>(
        _ operation: @MainActor () async throws -> Output
    ) async throws -> Output {
        let permitID = try await acquire()
        defer { release(permitID) }
        try Task.checkCancellation()
        return try await operation()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        activePermitID = nil
        let queued = waiters
        waiters.removeAll()
        for waiter in queued {
            waiter.continuation.resume(throwing: CodexTransferSendLaneError.invalidated)
        }
    }

    private func acquire() async throws -> UUID {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !isInvalidated else {
                    continuation.resume(throwing: CodexTransferSendLaneError.invalidated)
                    return
                }
                if activePermitID == nil {
                    activePermitID = waiterID
                    continuation.resume(returning: waiterID)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelQueuedWaiter(waiterID)
            }
        }
    }

    private func cancelQueuedWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ permitID: UUID) {
        guard activePermitID == permitID else { return }
        guard !isInvalidated, !waiters.isEmpty else {
            activePermitID = nil
            return
        }
        let next = waiters.removeFirst()
        activePermitID = next.id
        next.continuation.resume(returning: next.id)
    }
}
