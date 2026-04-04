// FILE: CodexService+MacContext.swift
// Purpose: Loads, saves, and clears Mac-scoped local app state between explicit Mac switches.
// Layer: Service extension
// Exports: CodexService Mac context helpers
// Depends on: Foundation

import Foundation

extension CodexService {
    var currentMacScopedPersistenceDeviceId: String? {
        resolvedMacScopedDeviceId()
    }

    func macScopedDefaultsKey(_ baseKey: String, macDeviceId: String? = nil) -> String {
        guard let normalizedMacDeviceId = resolvedMacScopedDeviceId(explicitMacDeviceId: macDeviceId) else {
            return baseKey
        }

        return "\(baseKey).\(normalizedMacDeviceId)"
    }

    func loadCurrentMacScopedLocalState() {
        loadLocalState(for: currentMacScopedPersistenceDeviceId)
    }

    // Persists the active Mac's message and change-set caches without changing the current selection.
    func persistCurrentMacMessages() {
        guard !suspendAutomaticMacScopedPersistence else {
            return
        }

        saveLocalState(for: currentMacScopedPersistenceDeviceId)
    }

    // Persists the currently loaded local state under the provided Mac namespace.
    func saveLocalState(for macDeviceId: String?) {
        let normalizedMacDeviceId = normalizedMacScopedDeviceId(macDeviceId)
        messagePersistence.save(messagesByThread, macDeviceId: normalizedMacDeviceId)
        aiChangeSetPersistence.save(Array(aiChangeSetsByID.values), macDeviceId: normalizedMacDeviceId)
    }

    // Loads messages and assistant change-set metadata for the provided Mac namespace.
    func loadLocalState(for macDeviceId: String?) {
        let normalizedMacDeviceId = normalizedMacScopedDeviceId(macDeviceId)
        withApplyingMacScopedState {
            let loadedMessages = messagePersistence.load(macDeviceId: normalizedMacDeviceId).mapValues { messages in
                messages.map { message in
                    var value = message
                    value.isStreaming = false
                    return value
                }
            }

            CodexMessageOrderCounter.seed(from: loadedMessages)
            messagesByThread = loadedMessages
            messageRevisionByThread = Dictionary(uniqueKeysWithValues: loadedMessages.keys.map { ($0, 0) })
            messageIndexCacheByThread.removeAll()
            latestAssistantOutputByThread.removeAll()
            latestRepoAffectingMessageSignalByThread.removeAll()
            assistantCompletionFingerprintByThread.removeAll()
            recentActivityLineByThread.removeAll()
            contextWindowUsageByThread.removeAll()
            removeAllThreadTimelineState()

            let loadedChangeSets = aiChangeSetPersistence.load(macDeviceId: normalizedMacDeviceId)
            aiChangeSetsByID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
                partialResult[changeSet.id] = changeSet
            }
            aiChangeSetIDByTurnID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
                partialResult[changeSet.turnId] = changeSet.id
            }
            aiChangeSetIDByAssistantMessageID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
                if let assistantMessageId = changeSet.assistantMessageId {
                    partialResult[assistantMessageId] = changeSet.id
                }
            }
        }
    }

    func loadCurrentMacScopedDefaultsState() {
        loadMacScopedDefaultsState(for: normalizedCurrentTrustedMacDeviceId)
    }

    func loadMacScopedDefaultsState(for macDeviceId: String?) {
        withApplyingMacScopedState {
            if let savedThreadRuntimeOverrides = defaults.data(forKey: macScopedDefaultsKey(Self.threadRuntimeOverridesDefaultsKey, macDeviceId: macDeviceId)),
               let decodedThreadRuntimeOverrides = try? decoder.decode(
                   [String: CodexThreadRuntimeOverride].self,
                   from: savedThreadRuntimeOverrides
               ) {
                threadRuntimeOverridesByThreadID = decodedThreadRuntimeOverrides
            } else {
                threadRuntimeOverridesByThreadID = [:]
            }

            if let savedPlanSessionSources = defaults.data(forKey: macScopedDefaultsKey(Self.planSessionSourcesDefaultsKey, macDeviceId: macDeviceId)),
               let decodedPlanSessionSources = try? decoder.decode(
                   [String: CodexPlanSessionSource].self,
                   from: savedPlanSessionSources
               ) {
                planSessionSourceByThread = decodedPlanSessionSources
            } else {
                planSessionSourceByThread = [:]
            }

            if let savedForkOrigins = defaults.data(forKey: macScopedDefaultsKey(Self.forkedThreadOriginsDefaultsKey, macDeviceId: macDeviceId)),
               let decodedForkOrigins = try? decoder.decode([String: String].self, from: savedForkOrigins) {
                forkedFromThreadIDByThreadID = decodedForkOrigins
            } else {
                forkedFromThreadIDByThreadID = [:]
            }

            if let savedRenamedThreadNames = defaults.data(forKey: macScopedDefaultsKey(Self.renamedThreadNamesDefaultsKey, macDeviceId: macDeviceId)),
               let decodedRenamedThreadNames = try? decoder.decode([String: String].self, from: savedRenamedThreadNames) {
                renamedThreadNameByThreadID = decodedRenamedThreadNames
            } else {
                renamedThreadNameByThreadID = [:]
            }

            if let savedAssociatedManagedWorktreePaths = defaults.data(
                forKey: macScopedDefaultsKey(Self.associatedManagedWorktreePathsDefaultsKey, macDeviceId: macDeviceId)
            ),
               let decodedAssociatedManagedWorktreePaths = try? decoder.decode(
                   [String: String].self,
                   from: savedAssociatedManagedWorktreePaths
               ) {
                associatedManagedWorktreePathByThreadID = decodedAssociatedManagedWorktreePaths
            } else {
                associatedManagedWorktreePathByThreadID = [:]
            }

            authoritativeProjectPathByThreadID = [:]

            if let persistedGPTAccountSnapshot = loadPersistedGPTAccountSnapshot(macDeviceId: macDeviceId) {
                gptAccountSnapshot = persistedGPTAccountSnapshot
            } else {
                gptAccountSnapshot = codexGPTAccountInitialSnapshot()
            }

            if let pendingLogin = gptPendingLoginState(macDeviceId: macDeviceId),
               !gptAccountSnapshot.isAuthenticated,
               gptAccountSnapshot.status != .loginPending {
                gptAccountSnapshot = CodexGPTAccountSnapshot(
                    status: .loginPending,
                    authMethod: .chatgpt,
                    email: nil,
                    displayName: nil,
                    planType: nil,
                    loginInFlight: true,
                    needsReauth: false,
                    expiresAt: pendingLogin.expiresAt,
                    tokenReady: false,
                    tokenUnavailableSince: nil,
                    updatedAt: .now
                )
            }
        }
    }

    // Clears in-memory state that is tied to the active Mac before another Mac is loaded.
    func clearInMemoryMacScopedState() {
        withApplyingMacScopedState {
            threads = []
            activeThreadId = nil
            activeTurnId = nil
            activeTurnIdByThread.removeAll()
            messagesByThread.removeAll()
            messageRevisionByThread.removeAll()
            threadIdByTurnID.removeAll()
            queuedTurnDraftsByThread.removeAll()
            queuePauseStateByThread.removeAll()
            assistantCompletionFingerprintByThread.removeAll()
            recentActivityLineByThread.removeAll()
            contextWindowUsageByThread.removeAll()
            aiChangeSetsByID.removeAll()
            aiChangeSetIDByTurnID.removeAll()
            aiChangeSetIDByAssistantMessageID.removeAll()
            clearAllRunningState()
            readyThreadIDs.removeAll()
            failedThreadIDs.removeAll()
            removeAllThreadTimelineState()
            assistantRevertStateCacheByThread.removeAll()
            assistantRevertStateRevision = 0
            messageIndexCacheByThread.removeAll()
            latestAssistantOutputByThread.removeAll()
            latestRepoAffectingMessageSignalByThread.removeAll()
            currentOutput = ""
            threadRuntimeOverridesByThreadID.removeAll()
            planSessionSourceByThread.removeAll()
            forkedFromThreadIDByThreadID.removeAll()
            renamedThreadNameByThreadID.removeAll()
            associatedManagedWorktreePathByThreadID.removeAll()
            authoritativeProjectPathByThreadID.removeAll()
            gptAccountSnapshot = codexGPTAccountInitialSnapshot()
            gptAccountErrorMessage = nil
        }
    }

    func migrateLegacyMacScopedDefaultsIfNeeded() {
        migrateLegacyMacScopedDefaultsValue(for: Self.planSessionSourcesDefaultsKey)
        migrateLegacyMacScopedDefaultsValue(for: Self.associatedManagedWorktreePathsDefaultsKey)
    }
}

private extension CodexService {
    func withApplyingMacScopedState(_ work: () -> Void) {
        let previous = isApplyingMacScopedState
        isApplyingMacScopedState = true
        defer { isApplyingMacScopedState = previous }
        work()
    }

    func resolvedMacScopedDeviceId(explicitMacDeviceId: String? = nil) -> String? {
        normalizedMacScopedDeviceId(
            explicitMacDeviceId
                ?? macScopedContextOverrideDeviceId
                ?? normalizedCurrentTrustedMacDeviceId
                ?? normalizedRelayMacDeviceId
        )
    }

    func migrateLegacyMacScopedDefaultsValue(for baseKey: String) {
        guard let normalizedCurrentTrustedMacDeviceId else {
            return
        }

        let scopedKey = macScopedDefaultsKey(baseKey, macDeviceId: normalizedCurrentTrustedMacDeviceId)
        guard scopedKey != baseKey else {
            return
        }

        if defaults.object(forKey: scopedKey) == nil,
           let legacyValue = defaults.object(forKey: baseKey) {
            defaults.set(legacyValue, forKey: scopedKey)
        }

        defaults.removeObject(forKey: baseKey)
    }

    func normalizedMacScopedDeviceId(_ macDeviceId: String?) -> String? {
        guard let trimmed = macDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
