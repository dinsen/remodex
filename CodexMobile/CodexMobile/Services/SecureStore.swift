// FILE: SecureStore.swift
// Purpose: Small Keychain wrapper for sensitive app settings.
// Layer: Service
// Exports: SecureStore, CodexSecureKeys
// Depends on: Security

import Foundation
import Security

enum CodexSecureKeys {
    nonisolated static let relaySessionId = "codex.relay.sessionId"
    nonisolated static let relayUrl = "codex.relay.url"
    nonisolated static let relayMacDeviceId = "codex.relay.macDeviceId"
    nonisolated static let relayMacIdentityPublicKey = "codex.relay.macIdentityPublicKey"
    nonisolated static let relayProtocolVersion = "codex.relay.protocolVersion"
    nonisolated static let relayLastAppliedBridgeOutboundSeq = "codex.relay.lastAppliedBridgeOutboundSeq"
    nonisolated static let relayBridgeReplayEpoch = "codex.relay.bridgeReplayEpoch"
    nonisolated static let pushDeviceToken = "codex.push.deviceToken"
    nonisolated static let trustedMacRegistry = "codex.secure.trustedMacRegistry"
    nonisolated static let currentTrustedMacDeviceId = "codex.secure.currentTrustedMacDeviceId"
    nonisolated static let lastTrustedMacDeviceId = "codex.secure.lastTrustedMacDeviceId"
    nonisolated static let phoneIdentityState = "codex.secure.phoneIdentityState"
    nonisolated static let messageHistoryKey = "codex.local.messageHistoryKey"
    nonisolated static let liveVoiceAPIKey = "codex.liveVoice.openaiAPIKey"
    nonisolated static let terminalSSHProfile = "codex.terminal.sshProfile"
    nonisolated static let terminalSSHPrivateKey = "codex.terminal.sshPrivateKey"
    nonisolated static let terminalSSHPrivateKeyPassphrase = "codex.terminal.sshPrivateKeyPassphrase"
    nonisolated static let terminalSSHKnownHostPrefix = "codex.terminal.sshKnownHost"
}

enum SecureStoreCodableReadResult<Value> {
    case found(Value)
    case missing
    case unavailable
}

struct SecureStoreKeychainOperations: Sendable {
    let copyMatching: @Sendable ([String: Any]) -> (OSStatus, [String: Any]?)
    let update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    let add: @Sendable ([String: Any]) -> OSStatus
    let delete: @Sendable ([String: Any]) -> OSStatus

    nonisolated static let system = SecureStoreKeychainOperations(
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? [String: Any])
        },
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        add: { query in
            SecItemAdd(query as CFDictionary, nil)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    )
}

enum SecureStore {
    // Reads a UTF-8 string value from Keychain.
    nonisolated static func readString(for key: String) -> String? {
        guard let data = readData(for: key),
              let stringValue = String(data: data, encoding: .utf8) else {
            return nil
        }

        return stringValue
    }

    // Reads opaque key material or encrypted payload blobs from Keychain.
    nonisolated static func readData(for key: String) -> Data? {
        switch readDataResult(for: key) {
        case .found(let data, let service):
            migrateLegacyValueIfNeeded(data, for: key, service: service)
            return data
        case .missing, .unavailable:
            return nil
        }
    }

    // Writes a UTF-8 string to Keychain; empty values are treated as delete.
    nonisolated static func writeString(_ value: String, for key: String) {
        writeString(value, for: key, accessibility: nil)
    }

    // Writes sensitive strings with optional Keychain accessibility constraints.
    nonisolated static func writeString(_ value: String, for key: String, accessibility: CFString?) {
        if value.isEmpty {
            deleteValue(for: key)
            return
        }

        writeData(Data(value.utf8), for: key, accessibility: accessibility)
    }

    // Writes a sensitive UTF-8 string and reports whether Keychain accepted it.
    @discardableResult
    nonisolated static func writeStringChecked(
        _ value: String,
        for key: String,
        accessibility: CFString?
    ) -> Bool {
        if value.isEmpty {
            return deleteValueChecked(for: key)
        }
        return writeData(Data(value.utf8), for: key, accessibility: accessibility)
    }

    // Stores raw data in Keychain; used by local message-history encryption keys.
    nonisolated static func writeData(_ value: Data, for key: String) {
        writeData(value, for: key, accessibility: nil)
    }

    // Stores raw data in Keychain with optional accessibility constraints for key material.
    @discardableResult
    nonisolated static func writeData(_ value: Data, for key: String, accessibility: CFString?) -> Bool {
        if value.isEmpty {
            deleteValue(for: key)
            return true
        }

        return writeData(value, for: key, accessibility: accessibility, operations: .system)
    }

    @discardableResult
    nonisolated static func writeData(
        _ value: Data,
        for key: String,
        accessibility: CFString?,
        operations: SecureStoreKeychainOperations
    ) -> Bool {
        if value.isEmpty {
            deleteValue(for: key)
            return true
        }

        let stableQuery = baseQuery(for: key, service: stableServiceName)
        let requestedAccessibility = accessibility.map { $0 as String }
        if let currentItem = readStableItem(for: key, using: operations),
           currentItem.data == value,
           requestedAccessibility == nil || currentItem.accessibility == requestedAccessibility {
            return true
        }

        var updateAttributes: [String: Any] = [kSecValueData as String: value]
        if let accessibility {
            updateAttributes[kSecAttrAccessible as String] = accessibility
        }

        let updateStatus = operations.update(stableQuery, updateAttributes)
        if updateStatus == errSecSuccess {
            deleteLegacyValues(for: key, using: operations)
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = stableQuery
        addQuery[kSecValueData as String] = value
        if let accessibility {
            addQuery[kSecAttrAccessible as String] = accessibility
        }
        let addStatus = operations.add(addQuery)
        if addStatus == errSecSuccess {
            deleteLegacyValues(for: key, using: operations)
            return true
        }
        guard addStatus == errSecDuplicateItem else {
            return false
        }

        let retryStatus = operations.update(stableQuery, updateAttributes)
        guard retryStatus == errSecSuccess else {
            return false
        }
        deleteLegacyValues(for: key, using: operations)
        return true
    }

    // Convenience wrapper for small Codable payloads kept in Keychain.
    nonisolated static func readCodable<Value: Decodable>(_ type: Value.Type, for key: String) -> Value? {
        switch readCodableResult(type, for: key) {
        case .found(let value):
            return value
        case .missing, .unavailable:
            return nil
        }
    }

    nonisolated static func readCodableResult<Value: Decodable>(
        _ type: Value.Type,
        for key: String
    ) -> SecureStoreCodableReadResult<Value> {
        switch readDataResult(for: key) {
        case .found(let data, let service):
            migrateLegacyValueIfNeeded(data, for: key, service: service)
            guard let value = try? JSONDecoder().decode(type, from: data) else {
                return .missing
            }
            return .found(value)
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        }
    }

    // Convenience wrapper for small Codable payloads kept in Keychain.
    @discardableResult
    nonisolated static func writeCodable<Value: Encodable>(_ value: Value, for key: String) -> Bool {
        writeCodable(value, for: key, accessibility: nil)
    }

    @discardableResult
    nonisolated static func writeCodable<Value: Encodable>(
        _ value: Value,
        for key: String,
        accessibility: CFString?
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else {
            return false
        }
        return writeData(data, for: key, accessibility: accessibility)
    }

    nonisolated static func updateAccessibilityIfNeeded(for key: String, accessibility: CFString) -> Bool {
        updateAccessibilityIfNeeded(for: key, accessibility: accessibility, operations: .system)
    }

    nonisolated static func updateAccessibilityIfNeeded(
        for key: String,
        accessibility: CFString,
        operations: SecureStoreKeychainOperations
    ) -> Bool {
        guard let currentItem = readStableItem(for: key, using: operations) else {
            return false
        }
        guard currentItem.accessibility != (accessibility as String) else {
            return true
        }
        return operations.update(
            baseQuery(for: key, service: stableServiceName),
            [kSecAttrAccessible as String: accessibility]
        ) == errSecSuccess
    }

    nonisolated static func deleteValue(for key: String) {
        for service in storageServiceNames {
            let query = baseQuery(for: key, service: service)
            SecItemDelete(query as CFDictionary)
        }
    }

    @discardableResult
    nonisolated static func deleteValueChecked(for key: String) -> Bool {
        var succeeded = true
        for service in storageServiceNames {
            let status = SecureStoreKeychainOperations.system.delete(baseQuery(for: key, service: service))
            if status != errSecSuccess && status != errSecItemNotFound {
                succeeded = false
            }
        }
        return succeeded
    }

    private enum DataReadResult {
        case found(Data, service: String)
        case missing
        case unavailable
    }

    private struct StableItem {
        let data: Data
        let accessibility: String?
    }

    private nonisolated static func readStableItem(
        for key: String,
        using operations: SecureStoreKeychainOperations
    ) -> StableItem? {
        var query = baseQuery(for: key, service: stableServiceName)
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, attributes) = operations.copyMatching(query)
        guard status == errSecSuccess,
              let attributes,
              let data = attributes[kSecValueData as String] as? Data else {
            return nil
        }
        return StableItem(
            data: data,
            accessibility: attributes[kSecAttrAccessible as String] as? String
        )
    }

    private nonisolated static func deleteLegacyValues(
        for key: String,
        using operations: SecureStoreKeychainOperations
    ) {
        for service in storageServiceNames.dropFirst() {
            _ = operations.delete(baseQuery(for: key, service: service))
        }
    }

    private nonisolated static func readDataResult(for key: String) -> DataReadResult {
        var encounteredUnavailableStatus = false
        for service in storageServiceNames {
            var query = baseQuery(for: key, service: service)
            query[kSecReturnData as String] = kCFBooleanTrue
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data {
                return .found(data, service: service)
            }
            if status != errSecItemNotFound {
                encounteredUnavailableStatus = true
            }
        }

        return encounteredUnavailableStatus ? .unavailable : .missing
    }

    private nonisolated static func migrateLegacyValueIfNeeded(
        _ data: Data,
        for key: String,
        service: String
    ) {
        guard service != stableServiceName else {
            return
        }
        writeData(data, for: key)
    }

    private nonisolated static func baseQuery(for key: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private nonisolated static let stableServiceName = "com.remodex.secure-store"

    private nonisolated static var storageServiceNames: [String] {
        var names = [stableServiceName]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            names.append(bundleIdentifier)
        }
        names.append(contentsOf: [
            "com.dinsen.remodex",
            "com.emanueledipietro.Remodex",
            "com.codexmobile.app",
        ])

        var uniqueNames: [String] = []
        for name in names where !uniqueNames.contains(name) {
            uniqueNames.append(name)
        }
        return uniqueNames
    }
}

actor SecureStoreReplayCursorWriter {
    nonisolated static let shared = SecureStoreReplayCursorWriter()

    private struct PendingRelayReplayCursor {
        let sessionID: String
        let sequence: Int
    }

    private var currentRelaySessionID: String?
    private var pendingRelayReplayCursor: PendingRelayReplayCursor?
    private var relayReplayCursorFlushTask: Task<Void, Never>?

    nonisolated func scheduleRelayLastAppliedBridgeOutboundSeq(_ sequence: Int, sessionID: String) {
        Task.detached(priority: .utility) {
            await self.enqueueRelayLastAppliedBridgeOutboundSeq(sequence, sessionID: sessionID)
        }
    }

    nonisolated func persistRelayLastAppliedBridgeOutboundSeqImmediately(_ sequence: Int, sessionID: String) {
        Task.detached(priority: .utility) {
            await self.persistRelayLastAppliedBridgeOutboundSeq(sequence, sessionID: sessionID)
        }
    }

    nonisolated func deleteRelayLastAppliedBridgeOutboundSeq() {
        Task.detached(priority: .utility) {
            await self.deleteRelayLastAppliedBridgeOutboundSeqValue()
        }
    }

    private func enqueueRelayLastAppliedBridgeOutboundSeq(_ sequence: Int, sessionID: String) {
        if let currentRelaySessionID, currentRelaySessionID != sessionID {
            return
        }

        currentRelaySessionID = sessionID
        let pendingSequence: Int
        if let pendingRelayReplayCursor, pendingRelayReplayCursor.sessionID == sessionID {
            pendingSequence = max(pendingRelayReplayCursor.sequence, sequence)
        } else {
            pendingSequence = sequence
        }
        pendingRelayReplayCursor = PendingRelayReplayCursor(
            sessionID: sessionID,
            sequence: pendingSequence
        )

        relayReplayCursorFlushTask?.cancel()
        relayReplayCursorFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushRelayLastAppliedBridgeOutboundSeq()
        }
    }

    private func persistRelayLastAppliedBridgeOutboundSeq(_ sequence: Int, sessionID: String) {
        currentRelaySessionID = sessionID
        pendingRelayReplayCursor = nil
        relayReplayCursorFlushTask?.cancel()
        relayReplayCursorFlushTask = nil
        SecureStore.writeString(
            String(sequence),
            for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq
        )
    }

    private func deleteRelayLastAppliedBridgeOutboundSeqValue() {
        currentRelaySessionID = nil
        pendingRelayReplayCursor = nil
        relayReplayCursorFlushTask?.cancel()
        relayReplayCursorFlushTask = nil
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
    }

    private func flushRelayLastAppliedBridgeOutboundSeq() {
        relayReplayCursorFlushTask = nil
        guard let pendingRelayReplayCursor else { return }
        self.pendingRelayReplayCursor = nil
        guard pendingRelayReplayCursor.sessionID == currentRelaySessionID else {
            return
        }
        SecureStore.writeString(
            String(pendingRelayReplayCursor.sequence),
            for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq
        )
    }
}
