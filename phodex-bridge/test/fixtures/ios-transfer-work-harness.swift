import Foundation
import CryptoKit

nonisolated struct HarnessTransferValue: Codable, Equatable, Sendable {
    let text: String
}

nonisolated struct HarnessThreadSummary: Codable, Equatable, Sendable {
    let id: String
    let title: String
}

@main
struct TransferWorkHarness {
    @MainActor
    static func main() async throws {
        let wasOffMain = try await CodexTransferWork.run {
            !Thread.isMainThread
        }
        precondition(wasOffMain, "transfer closure ran on the main thread")

        let encoded = try await CodexTransferWork.run {
            Data("transfer-payload".utf8).base64EncodedString()
        }
        precondition(encoded == "dHJhbnNmZXItcGF5bG9hZA==")

        let codec = CodexTransferJSONCodec(encoder: JSONEncoder(), decoder: JSONDecoder())
        let wireText = try await codec.encodeText(HarnessTransferValue(text: "history"))
        let decoded = try await codec.decodeText(HarnessTransferValue.self, from: wireText)
        precondition(decoded == HarnessTransferValue(text: "history"))
        let threadSummary = try await codec.decodeModel(
            HarnessThreadSummary.self,
            from: .object([
                "id": .string("thread-a"),
                "title": .string("History thread"),
                "turns": .array([.object(["items": .array([.string("large history payload")])])]),
            ]),
            omittingTopLevelKeys: ["turns"]
        )
        precondition(threadSummary == HarnessThreadSummary(id: "thread-a", title: "History thread"))

        let sectionValues = await codec.decodeModels(
            CodexThreadSection.self,
            from: [.object(["id": .string("section-a"), "name": .string("Inbox")])]
        )
        precondition(sectionValues.compactMap { $0 }.map(\.id) == ["section-a"])
        let threadValues = await codec.decodeModels(
            CodexThread.self,
            from: [.object([
                "id": .string("thread-a"),
                "name": .string("Off-main thread"),
                "turns": .array([.object(["items": .array([.string("large history")])])]),
            ])],
            omittingTopLevelKeys: ["turns"]
        )
        precondition(threadValues.compactMap { $0 }.map(\.id) == ["thread-a"])
        let fileValues = await codec.decodeModels(
            CodexFuzzyFileMatch.self,
            from: [.object([
                "root": .string("/project"),
                "path": .string("Sources/Hello.swift"),
                "score": .integer(7),
            ])]
        )
        precondition(fileValues.compactMap { $0 }.map(\.fileName) == ["Hello.swift"])
        let skillValues = await codec.decodeModels(
            CodexSkillMetadata.self,
            from: [.object(["name": .string("review"), "enabled": .bool(true)])]
        )
        precondition(skillValues.compactMap { $0 }.map(\.normalizedName) == ["review"])
        let pluginValues = await codec.decodeModels(
            CodexPluginListResponse.self,
            from: [.object(["marketplaces": .array([])])]
        )
        precondition(pluginValues.compactMap { $0 }.count == 1)

        let receiveSocketGeneration = UUID()
        let replacedSocketGeneration = UUID()
        let oldSecureGeneration = UUID()
        let installedSecureGeneration = UUID()
        for mode in CodexTransferReceiveMode.allCases {
            let token = CodexTransferReceiveToken(socketGeneration: receiveSocketGeneration, mode: mode)
            precondition(token.canContinue(currentSocketGeneration: receiveSocketGeneration))
            precondition(!token.canContinue(currentSocketGeneration: replacedSocketGeneration))
            precondition(token.canApply(
                currentSocketGeneration: receiveSocketGeneration,
                capturedSessionGeneration: oldSecureGeneration,
                currentSessionGeneration: installedSecureGeneration
            ) == false)
            precondition(token.canApply(
                currentSocketGeneration: receiveSocketGeneration,
                capturedSessionGeneration: installedSecureGeneration,
                currentSessionGeneration: installedSecureGeneration
            ))
        }

        let historyToken = CodexHistoryDecodeToken(
            threadId: "thread-a",
            threadGeneration: 4,
            contextGeneration: 12
        )
        var staleHistoryMutations = [Int](repeating: 0, count: 4)
        let delayedDecodedRows = try await CodexTransferWork.run { ["decoded-child"] }
        precondition(delayedDecodedRows == ["decoded-child"])
        let removedThreadToken = CodexHistoryDecodeToken(
            threadId: "thread-a",
            threadGeneration: 5,
            contextGeneration: 12
        )
        let removedThreadWasCommitted = CodexHistoryDecodeCommit.commitIfCurrent(
            captured: historyToken,
            current: removedThreadToken,
            taskIsCancelled: false
        ) {
            staleHistoryMutations = [1, 1, 1, 1]
        }
        precondition(!removedThreadWasCommitted && staleHistoryMutations == [0, 0, 0, 0])
        let resetContextToken = CodexHistoryDecodeToken(
            threadId: "thread-a",
            threadGeneration: 4,
            contextGeneration: 13
        )
        let resetContextWasCommitted = CodexHistoryDecodeCommit.commitIfCurrent(
            captured: historyToken,
            current: resetContextToken,
            taskIsCancelled: false
        ) {
            staleHistoryMutations = [1, 1, 1, 1]
        }
        precondition(!resetContextWasCommitted && staleHistoryMutations == [0, 0, 0, 0])
        let cancelledHistoryWasCommitted = CodexHistoryDecodeCommit.commitIfCurrent(
            captured: historyToken,
            current: historyToken,
            taskIsCancelled: true
        ) {
            staleHistoryMutations = [1, 1, 1, 1]
        }
        precondition(!cancelledHistoryWasCommitted && staleHistoryMutations == [0, 0, 0, 0])
        let currentHistoryWasCommitted = CodexHistoryDecodeCommit.commitIfCurrent(
            captured: historyToken,
            current: historyToken,
            taskIsCancelled: false
        ) {
            staleHistoryMutations = [1, 1, 1, 1]
        }
        precondition(currentHistoryWasCommitted && staleHistoryMutations == [1, 1, 1, 1])

        let key = SymmetricKey(data: Data(repeating: 0x27, count: 32))
        let outbound = CodexSecureOutboundSnapshot(
            sessionId: "session-a",
            keyEpoch: 9,
            counter: 4,
            key: key
        )
        let outboundOutcome = await codec.sealSecureText(
            "{\"jsonrpc\":\"2.0\",\"id\":\"probe\",\"method\":\"probe\"}",
            session: outbound
        )
        let outboundText: String
        switch outboundOutcome {
        case .sealed(let text, let counter):
            precondition(counter == 4)
            outboundText = text
        case .failedBeforeSeal(let error):
            throw error
        case .failedAfterSeal(_, let error):
            throw error
        }
        let outboundEnvelope = try JSONDecoder().decode(SecureEnvelope.self, from: Data(outboundText.utf8))
        precondition(outboundEnvelope.sessionId == "session-a")
        precondition(outboundEnvelope.keyEpoch == 9 && outboundEnvelope.counter == 4)
        precondition(outboundEnvelope.sender == "iphone")
        print("swift-outbound-envelope-base64=\(Data(outboundText.utf8).base64EncodedString())")

        let macCounter = 12
        // Independent fixed AES-GCM vector generated with the bridge's Node
        // createCipheriv("aes-256-gcm") path, key 0x27*32, sender mac, counter 12.
        let macText = #"{"kind":"encryptedEnvelope","v":2,"sessionId":"session-a","keyEpoch":9,"sender":"mac","counter":12,"ciphertext":"4a5E9DIokohFz5SBbmDObnpdl+GKMT4mlEGADQwORAIEnbXsh52Tn26qlWAOxuQ4xjsvvxpXEeadIP8stGpeMRvNi4XPnTnM8sZV6TQ/zf+S2sQCMYmm26M=","tag":"DdNADB2ETI5k1eoBW3m2rg=="}"#
        let macEnvelope = try JSONDecoder().decode(SecureEnvelope.self, from: Data(macText.utf8))
        let inbound = CodexSecureInboundSnapshot(
            sessionId: "session-a",
            keyEpoch: 9,
            lastCounter: -1,
            key: key
        )
        let opened = try await codec.openSecureText(macText, session: inbound)
        precondition(opened.counter == macCounter && opened.bridgeOutboundSeq == 33)
        precondition(opened.payloadText == "{\"id\":\"response-1\",\"result\":{\"ok\":true}}")
        if case .message(let rpcMessage) = opened.rpcResult {
            precondition(rpcMessage.id?.stringValue == "response-1")
        } else {
            fatalError("valid secure RPC did not decode")
        }

        var tamperedCiphertext = Data(base64Encoded: macEnvelope.ciphertext)!
        tamperedCiphertext[0] ^= 0x01
        let tamperedEnvelope = SecureEnvelope(
            kind: macEnvelope.kind,
            v: macEnvelope.v,
            sessionId: macEnvelope.sessionId,
            keyEpoch: macEnvelope.keyEpoch,
            sender: macEnvelope.sender,
            counter: macEnvelope.counter,
            ciphertext: tamperedCiphertext.base64EncodedString(),
            tag: macEnvelope.tag
        )
        let tamperedText = String(data: try JSONEncoder().encode(tamperedEnvelope), encoding: .utf8)!
        do {
            _ = try await codec.openSecureText(tamperedText, session: inbound)
            fatalError("tampered secure envelope was accepted")
        } catch CodexSecureTransferCodecError.decryptFailed {
            // AES-GCM authentication rejects modified ciphertext.
        }

        let malformedPayloadData = try JSONEncoder().encode(
            SecureApplicationPayload(bridgeOutboundSeq: 34, payloadText: "not-json")
        )
        let malformedCounter = 13
        let malformedNonce = try AES.GCM.Nonce(data: codexSecureNonce(sender: "mac", counter: malformedCounter))
        let malformedBox = try AES.GCM.seal(malformedPayloadData, using: key, nonce: malformedNonce)
        let malformedEnvelope = SecureEnvelope(
            kind: "encryptedEnvelope",
            v: 2,
            sessionId: "session-a",
            keyEpoch: 9,
            sender: "mac",
            counter: malformedCounter,
            ciphertext: malformedBox.ciphertext.base64EncodedString(),
            tag: malformedBox.tag.base64EncodedString()
        )
        let malformedText = String(data: try JSONEncoder().encode(malformedEnvelope), encoding: .utf8)!
        let malformedOpened = try await codec.openSecureText(malformedText, session: inbound)
        if case .decodeFailed = malformedOpened.rpcResult {
            // A valid envelope still consumes its counter when the inner RPC is malformed.
        } else {
            fatalError("malformed inner RPC was not reported separately")
        }

        do {
            let duplicateSnapshot = CodexSecureInboundSnapshot(
                sessionId: "session-a",
                keyEpoch: 9,
                lastCounter: macCounter,
                key: key
            )
            _ = try await codec.openSecureText(macText, session: duplicateSnapshot)
            fatalError("duplicate secure counter was accepted")
        } catch CodexSecureTransferCodecError.invalidEnvelope {
            // MainActor applies only strictly increasing inbound counters.
        }

        let newerText = try await CodexTransferWork.run {
            try bridgeCompatibleEnvelopeText(
                key: key,
                counter: 21,
                payloadText: "{\"id\":\"newer\",\"result\":{}}"
            )
        }
        _ = try await codec.openSecureText(newerText, session: inbound)
        let olderText = try await CodexTransferWork.run {
            try bridgeCompatibleEnvelopeText(
                key: key,
                counter: 20,
                payloadText: "{\"id\":\"older\",\"result\":{}}"
            )
        }
        do {
            let newerSnapshot = CodexSecureInboundSnapshot(
                sessionId: "session-a",
                keyEpoch: 9,
                lastCounter: 21,
                key: key
            )
            _ = try await codec.openSecureText(olderText, session: newerSnapshot)
            fatalError("out-of-order secure counter was accepted")
        } catch CodexSecureTransferCodecError.invalidEnvelope {
            // A valid but older counter is rejected before decryption/apply.
        }

        let sendLane = CodexTransferSendLane()
        var sendOrder: [Int] = []
        var firstSendStarted = false
        let firstSend = Task { @MainActor in
            try await sendLane.withPermit {
                firstSendStarted = true
                sendOrder.append(1)
                try await Task.sleep(nanoseconds: 20_000_000)
                sendOrder.append(2)
            }
        }
        while !firstSendStarted { await Task.yield() }
        let secondSend = Task { @MainActor in
            try await sendLane.withPermit {
                sendOrder.append(3)
                sendOrder.append(4)
            }
        }
        try await firstSend.value
        try await secondSend.value
        precondition(sendOrder == [1, 2, 3, 4], "send lane did not preserve FIFO order")

        let invalidatedLane = CodexTransferSendLane()
        var invalidationHolderStarted = false
        var invalidatedOperationCount = 0
        var invalidatedCompletionCount = 0
        let invalidationHolder = Task { @MainActor in
            try await invalidatedLane.withPermit {
                invalidationHolderStarted = true
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        while !invalidationHolderStarted { await Task.yield() }
        let invalidatedWaiter = Task { @MainActor in
            do {
                try await invalidatedLane.withPermit {
                    invalidatedOperationCount += 1
                }
                invalidatedCompletionCount += 1
                return false
            } catch CodexTransferSendLaneError.invalidated {
                invalidatedCompletionCount += 1
                return true
            } catch {
                invalidatedCompletionCount += 1
                return false
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        invalidatedLane.invalidate()
        let wasInvalidated = await invalidatedWaiter.value
        try await invalidationHolder.value
        precondition(wasInvalidated)
        precondition(invalidatedOperationCount == 0)
        precondition(invalidatedCompletionCount == 1, "invalidated waiter did not complete exactly once")

        let cancelledLane = CodexTransferSendLane()
        var cancellationHolderStarted = false
        var cancelledOperationCount = 0
        var cancelledCompletionCount = 0
        let cancellationHolder = Task { @MainActor in
            try await cancelledLane.withPermit {
                cancellationHolderStarted = true
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        while !cancellationHolderStarted { await Task.yield() }
        let cancelledWaiter = Task { @MainActor in
            do {
                try await cancelledLane.withPermit {
                    cancelledOperationCount += 1
                }
                cancelledCompletionCount += 1
                return false
            } catch is CancellationError {
                cancelledCompletionCount += 1
                return true
            } catch {
                cancelledCompletionCount += 1
                return false
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        cancelledWaiter.cancel()
        let wasCancelled = await cancelledWaiter.value
        try await cancellationHolder.value
        precondition(wasCancelled)
        precondition(cancelledOperationCount == 0)
        precondition(cancelledCompletionCount == 1, "cancelled waiter did not complete exactly once")

        let maskedPayload = Data("masked-frame-payload".utf8)
        let maskedFrame = try await CodexTransferWork.makeManualWebSocketFrame(opcode: 0x1, payload: maskedPayload)
        let splitIndex = maskedFrame.count / 2
        let firstHalf = try await CodexTransferWork.parseManualWebSocketFrames(
            from: Data(),
            appending: Data(maskedFrame.prefix(splitIndex))
        )
        precondition(firstHalf.frames.isEmpty)
        let secondHalf = try await CodexTransferWork.parseManualWebSocketFrames(
            from: firstHalf.remainingData,
            appending: Data(maskedFrame.suffix(from: splitIndex))
        )
        precondition(secondHalf.frames.count == 1)
        precondition(secondHalf.frames[0].opcode == 0x1)
        precondition(secondHalf.frames[0].payload == maskedPayload)
        precondition(secondHalf.remainingData.isEmpty)

        let largePayload = Data(repeating: 0x5A, count: 70_000)
        let largeFrame = try await CodexTransferWork.makeManualWebSocketFrame(opcode: 0x2, payload: largePayload)
        let parsedLargeFrame = try await CodexTransferWork.parseManualWebSocketFrames(from: largeFrame)
        precondition(parsedLargeFrame.frames.count == 1)
        precondition(parsedLargeFrame.frames[0].payload == largePayload)

        print("transfer work off-main checks passed")
    }
}

nonisolated private func bridgeCompatibleEnvelopeText(
    key: SymmetricKey,
    counter: Int,
    payloadText: String
) throws -> String {
    CodexTransferWork.assertOffMainThread()
    let payload = SecureApplicationPayload(bridgeOutboundSeq: 35, payloadText: payloadText)
    let payloadData = try JSONEncoder().encode(payload)
    let nonce = try AES.GCM.Nonce(data: codexSecureNonce(sender: "mac", counter: counter))
    let sealedBox = try AES.GCM.seal(payloadData, using: key, nonce: nonce)
    let envelope = SecureEnvelope(
        kind: "encryptedEnvelope",
        v: 2,
        sessionId: "session-a",
        keyEpoch: 9,
        sender: "mac",
        counter: counter,
        ciphertext: sealedBox.ciphertext.base64EncodedString(),
        tag: sealedBox.tag.base64EncodedString()
    )
    return String(data: try JSONEncoder().encode(envelope), encoding: .utf8)!
}
