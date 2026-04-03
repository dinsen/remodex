// FILE: CodexTrustedMacSelectionTests.swift
// Purpose: Verifies the app uses an explicit current trusted Mac instead of implicit recency fallback.
// Layer: Unit Test
// Exports: CodexTrustedMacSelectionTests
// Depends on: XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class CodexTrustedMacSelectionTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    override func setUp() {
        super.setUp()
        clearStoredSecureRelayState()
    }

    override func tearDown() {
        clearStoredSecureRelayState()
        super.tearDown()
    }

    func testServiceMigratesCurrentTrustedMacFromLastTrustedMacWhenMissing() {
        let macDeviceID = "mac-\(UUID().uuidString)"
        let registry = CodexTrustedMacRegistry(
            records: [
                macDeviceID: CodexTrustedMacRecord(
                    macDeviceId: macDeviceID,
                    macIdentityPublicKey: Data(repeating: 3, count: 32).base64EncodedString(),
                    lastPairedAt: Date()
                )
            ]
        )
        SecureStore.writeCodable(registry, for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.writeString(macDeviceID, for: CodexSecureKeys.lastTrustedMacDeviceId)

        let service = makeService()

        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, macDeviceID)
        XCTAssertEqual(service.preferredTrustedMacDeviceId, macDeviceID)
        XCTAssertEqual(
            SecureStore.readString(for: CodexSecureKeys.currentTrustedMacDeviceId),
            macDeviceID
        )
    }

    func testPreferredTrustedMacUsesExplicitCurrentMacInsteadOfLastTrustedFallback() {
        let service = makeService()
        let currentMacID = "mac-current-\(UUID().uuidString)"
        let lastTrustedMacID = "mac-last-\(UUID().uuidString)"

        service.trustedMacRegistry.records[currentMacID] = CodexTrustedMacRecord(
            macDeviceId: currentMacID,
            macIdentityPublicKey: Data(repeating: 4, count: 32).base64EncodedString(),
            lastPairedAt: Date().addingTimeInterval(-5)
        )
        service.trustedMacRegistry.records[lastTrustedMacID] = CodexTrustedMacRecord(
            macDeviceId: lastTrustedMacID,
            macIdentityPublicKey: Data(repeating: 5, count: 32).base64EncodedString(),
            lastPairedAt: Date()
        )
        service.lastTrustedMacDeviceId = lastTrustedMacID
        service.setCurrentTrustedMacDeviceId(currentMacID)

        XCTAssertEqual(service.preferredTrustedMacDeviceId, currentMacID)
        XCTAssertEqual(service.currentTrustedMacRecord?.macDeviceId, currentMacID)
    }

    func testHasSavedRelaySessionRejectsSessionForDifferentCurrentMac() {
        let service = makeService()
        let currentMacID = "mac-current-\(UUID().uuidString)"
        let staleMacID = "mac-stale-\(UUID().uuidString)"

        service.setCurrentTrustedMacDeviceId(currentMacID)
        service.relaySessionId = "saved-session"
        service.relayUrl = "wss://relay.local/relay"
        service.relayMacDeviceId = staleMacID

        XCTAssertFalse(service.hasSavedRelaySession)
    }

    func testForgetTrustedMacClearsCurrentTrustedMacDeviceId() {
        let service = makeService()
        let currentMacID = "mac-current-\(UUID().uuidString)"

        service.trustedMacRegistry.records[currentMacID] = CodexTrustedMacRecord(
            macDeviceId: currentMacID,
            macIdentityPublicKey: Data(repeating: 6, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay"
        )
        service.setCurrentTrustedMacDeviceId(currentMacID)

        service.forgetTrustedMac(deviceId: currentMacID)

        XCTAssertNil(service.normalizedCurrentTrustedMacDeviceId)
        XCTAssertNil(SecureStore.readString(for: CodexSecureKeys.currentTrustedMacDeviceId))
    }

    private func clearStoredSecureRelayState() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        SecureStore.deleteValue(for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.deleteValue(for: CodexSecureKeys.currentTrustedMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }

    private func makeService() -> CodexService {
        let service = CodexService()
        Self.retainedServices.append(service)
        return service
    }
}
