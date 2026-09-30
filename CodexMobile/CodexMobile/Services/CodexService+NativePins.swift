// FILE: CodexService+NativePins.swift
// Purpose: Synchronizes Codex's native Pinned section and migrates legacy phone-only pins.
// Layer: Service
// Exports: Native pin refresh, cache, and legacy migration helpers
// Depends on: CodexService, CodexThread, RPCMessage

import Foundation

enum NativePinCapability: Equatable {
    case unknown
    case available
    case unsupported
}

actor NativePinOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private struct NativeThreadSection {
    let id: String
    let name: String
}

private struct NativePinOperationContext: Equatable {
    let transferSessionGeneration: UUID
    let historyDecodeContextGeneration: UInt64
    let macScopedContextOverrideDeviceId: String?
    let macScopedPersistenceDeviceId: String?
    let connectedServerIdentity: String?
}

enum CodexNativePinAuthorityProbe: Equatable {
    case complete([String])
    case missingSection
    case unsupported
    case malformed
    case incomplete
}

enum CodexHostPinAuthorityProbe: Equatable {
    case valid(ids: [String], appServerOrder: [String]?)
    case unavailable
    case malformed
    case racing
    case unsupported
}

func codexPinnedStateAuthorityDecision(
    native: CodexNativePinAuthorityProbe,
    host: CodexHostPinAuthorityProbe,
    current: CodexPinnedStateAuthority
) -> CodexPinnedStateAuthority {
    if current == .native {
        return .native
    }

    switch native {
    case .complete(let nativeIDs) where !nativeIDs.isEmpty:
        return .native
    case .complete(let nativeIDs):
        if case .valid(let hostIDs, _) = host {
            return hostIDs == nativeIDs ? .native : .hostCompatibility
        }
        return current
    case .missingSection, .unsupported, .malformed, .incomplete:
        if case .valid = host {
            return .hostCompatibility
        }
        return current
    }
}

extension CodexService {
    func synchronizeNativePins() async throws {
        let context = captureNativePinOperationContext()
        try await withSerializedNativePinOperation {
            try self.requireCurrentNativePinOperation(context)
            try await self.synchronizeNativePinsWithoutSerialization(context: context)
        }
    }

    func setThreadPinned(_ threadID: String, pinned: Bool) async throws {
        let context = captureNativePinOperationContext()
        try await withSerializedNativePinOperation {
            try self.requireCurrentNativePinOperation(context)
            try await self.setThreadPinnedWithoutSerialization(threadID, pinned: pinned, context: context)
        }
    }

    func refreshNativePinsForThreadHydration() async -> [CodexThread] {
        let context = captureNativePinOperationContext()
        do {
            try await withSerializedNativePinOperation {
                try self.requireCurrentNativePinOperation(context)
                do {
                    try await self.synchronizeNativePinsWithoutSerialization(context: context)
                } catch {
                    try self.requireCurrentNativePinOperation(context)
                    if error is CancellationError {
                        throw error
                    }
                    self.lastErrorMessage = self.nativePinBackgroundErrorMessage(for: error)
                }
                try self.requireCurrentNativePinOperation(context)
                if self.pinnedStateAuthority == .hostCompatibility {
                    try await self.hydrateConfirmedHostPinnedThreads(context: context)
                }
            }
        } catch {
            if isCurrentNativePinOperation(context), !(error is CancellationError) {
                lastErrorMessage = nativePinBackgroundErrorMessage(for: error)
            }
        }
        return confirmedNativePinnedThreadsForHydration()
    }

    private func captureNativePinOperationContext() -> NativePinOperationContext {
        NativePinOperationContext(
            transferSessionGeneration: transferSessionGeneration,
            historyDecodeContextGeneration: historyDecodeContextGeneration,
            macScopedContextOverrideDeviceId: macScopedContextOverrideDeviceId,
            macScopedPersistenceDeviceId: currentMacScopedPersistenceDeviceId,
            connectedServerIdentity: connectedServerIdentity
        )
    }

    private func isCurrentNativePinOperation(_ context: NativePinOperationContext) -> Bool {
        !Task.isCancelled
            && transferSessionGeneration == context.transferSessionGeneration
            && historyDecodeContextGeneration == context.historyDecodeContextGeneration
            && macScopedContextOverrideDeviceId == context.macScopedContextOverrideDeviceId
            && currentMacScopedPersistenceDeviceId == context.macScopedPersistenceDeviceId
            && connectedServerIdentity == context.connectedServerIdentity
    }

    private func requireCurrentNativePinOperation(_ context: NativePinOperationContext) throws {
        guard isCurrentNativePinOperation(context) else {
            throw CancellationError()
        }
    }

    func confirmedNativePinnedThreadsForHydration() -> [CodexThread] {
        var seen: Set<String> = []
        let snapshots: [String: [CodexThread]] = pinnedStateAuthority == .hostCompatibility
            ? confirmedHostPinnedThreadSnapshotsByRootID
            : confirmedNativePinnedThreadSnapshotsByRootID
        let ids = pinnedStateAuthority == .hostCompatibility
            ? confirmedHostPinnedThreadIDs
            : confirmedNativePinnedThreadIDs
        return ids.flatMap { snapshots[$0] ?? [] }
            .filter { seen.insert($0.id).inserted }
    }

    private func hydrateConfirmedHostPinnedThreads(context: NativePinOperationContext) async throws {
        var didChangeSnapshots = false
        for threadID in confirmedHostPinnedThreadIDs {
            try requireCurrentNativePinOperation(context)
            if let liveThread = thread(for: threadID),
               !restoredThreadSnapshotIDs.contains(threadID),
               !snapshotOnlyPinnedThreadIDs.contains(threadID) {
                guard !liveThread.isSubagent else { continue }
                if let snapshot = snapshotThreadsForPinnedRoot(threadID), !snapshot.isEmpty {
                    if confirmedHostPinnedThreadSnapshotsByRootID[threadID] != snapshot {
                        confirmedHostPinnedThreadSnapshotsByRootID[threadID] = snapshot
                        didChangeSnapshots = true
                    }
                }
                continue
            }

            // Snapshot-only rows retry authoritative metadata; the cached snapshot remains the fallback on failure.
            do {
                guard let hydratedThread = try await readHostPinnedThread(threadID: threadID, context: context),
                      !hydratedThread.isSubagent else {
                    continue
                }
                try requireCurrentNativePinOperation(context)
                upsertThread(hydratedThread, treatAsServerState: true)
                confirmedHostPinnedThreadSnapshotsByRootID[threadID] =
                    snapshotThreadsForPinnedRoot(threadID) ?? [hydratedThread]
                didChangeSnapshots = true
            } catch {
                try requireCurrentNativePinOperation(context)
                if error is CancellationError {
                    throw error
                }
                // Keep the confirmed host ID and any prior snapshot. The next
                // serialized refresh retries only the row that is still absent.
                continue
            }
        }

        if didChangeSnapshots {
            try requireCurrentNativePinOperation(context)
            persistConfirmedHostPinnedThreadState()
            rebuildEffectivePinnedThreadState()
        }
    }

    private func readHostPinnedThread(
        threadID: String,
        context: NativePinOperationContext
    ) async throws -> CodexThread? {
        try requireCurrentNativePinOperation(context)
        let camelCaseParams: JSONValue = .object([
            "threadId": .string(threadID),
            "includeTurns": .bool(false),
        ])

        do {
            let response = try await sendRequest(
                method: "thread/read",
                params: camelCaseParams,
                timeoutNanoseconds: ThreadListHydrationPolicy.requestTimeoutNanoseconds,
                timeoutMessage: "thread/read timed out while hydrating a Codex host pin."
            )
            try requireCurrentNativePinOperation(context)
            return try await decodeHostPinnedThread(
                response,
                requestedThreadID: threadID,
                context: context
            )
        } catch {
            try requireCurrentNativePinOperation(context)
            if error is CancellationError {
                throw error
            }
            guard shouldRetryHostThreadReadWithSnakeCase(error) else {
                throw error
            }

            let response = try await sendRequest(
                method: "thread/read",
                params: .object([
                    "thread_id": .string(threadID),
                    "includeTurns": .bool(false),
                ]),
                timeoutNanoseconds: ThreadListHydrationPolicy.requestTimeoutNanoseconds,
                timeoutMessage: "thread/read timed out while hydrating a Codex host pin."
            )
            try requireCurrentNativePinOperation(context)
            return try await decodeHostPinnedThread(
                response,
                requestedThreadID: threadID,
                context: context
            )
        }
    }

    private func decodeHostPinnedThread(
        _ response: RPCMessage,
        requestedThreadID: String,
        context: NativePinOperationContext
    ) async throws -> CodexThread? {
        if let error = response.error {
            throw CodexServiceError.rpcError(error)
        }
        guard let threadValue = response.result?.objectValue?["thread"] else {
            throw CodexServiceError.invalidResponse("thread/read response missing thread")
        }
        let decodedThread = await decodeModelOffMain(
            CodexThread.self,
            from: threadValue,
            omittingTopLevelKeys: ["turns"]
        )
        try requireCurrentNativePinOperation(context)
        guard let decodedThread else {
            throw CodexServiceError.invalidResponse("thread/read response missing thread")
        }
        guard decodedThread.id == requestedThreadID else {
            throw CodexServiceError.invalidResponse("thread/read returned the wrong thread")
        }
        return decodedThread
    }

    private func shouldRetryHostThreadReadWithSnakeCase(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError,
              rpcError.code == -32602 else {
            return false
        }
        let message = rpcError.message.lowercased()
        return message.contains("threadid")
            || message.contains("thread_id")
            || (message.contains("unknown") && message.contains("field"))
    }

    private func synchronizeNativePinsWithoutSerialization(context: NativePinOperationContext) async throws {
        try requireCurrentNativePinOperation(context)
        var nativeProbe: CodexNativePinAuthorityProbe = .incomplete
        var nativeThreads: [CodexThread] = []
        var nativeError: Error?

        do {
            let section = try await resolveNativePinnedSection(context: context)
            try requireCurrentNativePinOperation(context)
            guard let section else {
                nativePinnedSectionID = nil
                nativePinCapability = .available
                nativeProbe = .missingSection
                nativeThreads = []
                return try await finishNativePinSynchronization(
                    context: context,
                    nativeProbe: nativeProbe,
                    nativeThreads: nativeThreads,
                    nativeError: nil
                )
            }

            nativePinnedSectionID = section.id
            nativePinCapability = .available
            let threads = try await fetchNativePinnedThreads(sectionID: section.id, context: context)
            try requireCurrentNativePinOperation(context)
            nativeThreads = threads
            nativeProbe = .complete(orderedUniqueThreadIDs(threads.map(\.id)))
        } catch {
            try requireCurrentNativePinOperation(context)
            if error is CancellationError {
                throw error
            }
            if isUnsupportedNativePinError(error) {
                nativePinCapability = .unsupported
            }
            nativeError = error
            nativeThreads = []
            nativeProbe = nativePinAuthorityProbe(for: error)
        }

        try await finishNativePinSynchronization(
            context: context,
            nativeProbe: nativeProbe,
            nativeThreads: nativeThreads,
            nativeError: nativeError
        )
    }

    private func finishNativePinSynchronization(
        context: NativePinOperationContext,
        nativeProbe: CodexNativePinAuthorityProbe,
        nativeThreads: [CodexThread],
        nativeError: Error?
    ) async throws {
        try requireCurrentNativePinOperation(context)
        let hasCompleteNativePins = isCompleteNonEmptyNativeProbe(nativeProbe)
        let shouldReadHost = (pinnedStateAuthority != .native && !hasCompleteNativePins)
            || (hasCompleteNativePins && isConnected && isInitialized)

        let hostProbe: CodexHostPinAuthorityProbe
        if shouldReadHost {
            hostProbe = try await readHostPinAuthorityProbe(context: context)
        } else {
            hostProbe = .unavailable
        }
        try requireCurrentNativePinOperation(context)

        let nextAuthority = codexPinnedStateAuthorityDecision(
            native: nativeProbe,
            host: hostProbe,
            current: pinnedStateAuthority
        )

        switch nextAuthority {
        case .native:
            if case .complete = nativeProbe {
                let appServerOrder: [String]?
                if case .valid(_, let order) = hostProbe {
                    appServerOrder = order
                } else {
                    appServerOrder = nil
                }
                commitConfirmedNativePins(nativeThreads, appServerOrder: appServerOrder)
            }
        case .hostCompatibility:
            if case .valid(let hostIDs, let appServerOrder) = hostProbe {
                commitConfirmedHostPins(hostIDs, appServerOrder: appServerOrder)
            }
        case .undecided:
            rebuildEffectivePinnedThreadState()
        }

        if nativeError != nil,
           !isCompleteNonEmptyNativeProbe(nativeProbe),
           case .valid = hostProbe {
            return
        }
        if let nativeError {
            throw nativeError
        }
    }

    private func isCompleteNonEmptyNativeProbe(_ probe: CodexNativePinAuthorityProbe) -> Bool {
        guard case .complete(let ids) = probe else {
            return false
        }
        return !ids.isEmpty
    }

    private func nativePinAuthorityProbe(for error: Error) -> CodexNativePinAuthorityProbe {
        if isUnsupportedNativePinError(error) {
            return .unsupported
        }

        guard let serviceError = error as? CodexServiceError,
              case .invalidResponse(let message) = serviceError else {
            return .incomplete
        }
        return message.localizedCaseInsensitiveContains("pagination") ? .incomplete : .malformed
    }

    private func readHostPinAuthorityProbe(
        context: NativePinOperationContext
    ) async throws -> CodexHostPinAuthorityProbe {
        try requireCurrentNativePinOperation(context)
        do {
            let response = try await sendRequest(
                method: "bridge/hostPins/read",
                params: .object([:]),
                timeoutNanoseconds: ThreadListHydrationPolicy.requestTimeoutNanoseconds,
                timeoutMessage: "bridge/hostPins/read timed out while synchronizing pins."
            )
            try requireCurrentNativePinOperation(context)
            if let error = response.error {
                return hostPinAuthorityProbe(for: error)
            }

            guard let result = response.result?.objectValue,
                  result["schemaVersion"]?.intValue == 1,
                  result["source"]?.stringValue == "codex-host",
                  let rawIDs = result["pinnedThreadIds"]?.arrayValue,
                  let ids = validatedHostPinIDs(rawIDs) else {
                return .malformed
            }

            let appServerOrder: [String]?
            if let rawOrder = result["appServerPinnedThreadOrder"] {
                guard let values = rawOrder.arrayValue,
                      let validatedOrder = validatedHostPinIDs(values) else {
                    return .malformed
                }
                appServerOrder = validatedOrder
            } else {
                appServerOrder = nil
            }
            return .valid(ids: ids, appServerOrder: appServerOrder)
        } catch {
            try requireCurrentNativePinOperation(context)
            if error is CancellationError {
                throw error
            }
            return hostPinAuthorityProbe(for: error)
        }
    }

    private func hostPinAuthorityProbe(for error: Error) -> CodexHostPinAuthorityProbe {
        if let serviceError = error as? CodexServiceError,
           case .rpcError(let rpcError) = serviceError {
            let errorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue
            switch errorCode {
            case "host_pins_malformed":
                return .malformed
            case "host_pins_racing":
                return .racing
            case "host_pins_unavailable":
                return .unavailable
            default:
                if rpcError.code == -32601 {
                    return .unsupported
                }
            }
        }
        return .unavailable
    }

    private func validatedHostPinIDs(_ rawIDs: [JSONValue]) -> [String]? {
        guard rawIDs.count <= 512 else {
            return nil
        }

        var seen: Set<String> = []
        var ids: [String] = []
        for value in rawIDs {
            guard let id = value.stringValue,
                  !id.isEmpty,
                  id.count <= 256,
                  seen.insert(id).inserted else {
                return nil
            }
            ids.append(id)
        }
        return ids
    }

    private func commitConfirmedNativePins(_ threads: [CodexThread], appServerOrder: [String]?) {
        replaceConfirmedNativePinsCache(with: orderedPinnedThreads(threads, appServerOrder: appServerOrder))
        pinnedStateAuthority = .native
        persistPinnedStateAuthority()
        confirmedHostPinnedThreadIDs.removeAll()
        confirmedHostPinnedThreadSnapshotsByRootID.removeAll()
        defaults.removeObject(forKey: macScopedDefaultsKey(Self.hostPinnedThreadIDsDefaultsKey))
        defaults.removeObject(forKey: macScopedDefaultsKey(Self.hostPinnedThreadSnapshotsDefaultsKey))
        rebuildEffectivePinnedThreadState()
    }

    private func commitConfirmedHostPins(_ ids: [String], appServerOrder: [String]?) {
        confirmedHostPinnedThreadIDs = orderedPinnedThreadIDs(ids, appServerOrder: appServerOrder)
        confirmedHostPinnedThreadSnapshotsByRootID = confirmedHostPinnedThreadSnapshotsByRootID.filter {
            confirmedHostPinnedThreadIDs.contains($0.key)
        }
        persistConfirmedHostPinnedThreadState()
        pinnedStateAuthority = .hostCompatibility
        persistPinnedStateAuthority()
        rebuildEffectivePinnedThreadState()
    }

    private func setThreadPinnedWithoutSerialization(
        _ threadID: String,
        pinned: Bool,
        context: NativePinOperationContext
    ) async throws {
        try requireCurrentNativePinOperation(context)
        guard let requestedThread = thread(for: threadID) else {
            throw CodexServiceError.invalidInput("This chat is not available to pin.")
        }
        guard requestedThread.syncState != .archivedLocal else {
            throw CodexServiceError.invalidInput("Archived chats cannot be pinned.")
        }
        guard !requestedThread.isSubagent else {
            throw CodexServiceError.invalidInput("Subagent chats cannot be pinned directly.")
        }

        do {
            try await synchronizeNativePinsWithoutSerialization(context: context)
        } catch {
            try requireCurrentNativePinOperation(context)
            throw userFacingNativePinMutationError(error)
        }
        try requireCurrentNativePinOperation(context)

        guard pinnedStateAuthority == .native,
              nativePinCapability == .available else {
            throw CodexServiceError.invalidInput("Update Codex to synchronize pins.")
        }

        let rootThreadID = pinnedRootThreadID(for: threadID) ?? threadID
        if pinned == confirmedNativePinnedThreadIDs.contains(rootThreadID) {
            return
        }

        let section: NativeThreadSection
        if let nativePinnedSectionID {
            section = NativeThreadSection(id: nativePinnedSectionID, name: "Pinned")
        } else if pinned {
            do {
                section = try await createNativePinnedSection(context: context)
            } catch {
                try requireCurrentNativePinOperation(context)
                throw userFacingNativePinMutationError(error)
            }
        } else {
            return
        }

        var params: RPCObject = ["threadId": .string(rootThreadID)]
        if pinned {
            params["sectionId"] = .string(section.id)
            if let firstPinnedThreadID = confirmedNativePinnedThreadIDs.first {
                params["beforeThreadId"] = .string(firstPinnedThreadID)
            }
        } else {
            params["sectionId"] = .null
        }

        do {
            _ = try await sendRequest(
                method: "thread/section/move",
                params: .object(params),
                timeoutNanoseconds: ThreadListHydrationPolicy.requestTimeoutNanoseconds,
                timeoutMessage: "thread/section/move timed out while synchronizing pins."
            )
            try requireCurrentNativePinOperation(context)
        } catch {
            try requireCurrentNativePinOperation(context)
            if error is CancellationError {
                throw error
            }
            if isUnsupportedNativePinError(error) {
                nativePinCapability = .unsupported
            }
            throw userFacingNativePinMutationError(error)
        }

        applyConfirmedNativePinMutation(rootThreadID: rootThreadID, pinned: pinned)

        do {
            try await synchronizeNativePinsWithoutSerialization(context: context)
        } catch {
            try requireCurrentNativePinOperation(context)
            if error is CancellationError {
                throw error
            }
            lastErrorMessage = nativePinBackgroundErrorMessage(for: error)
        }
    }

    private func applyConfirmedNativePinMutation(rootThreadID: String, pinned: Bool) {
        confirmedNativePinnedThreadIDs.removeAll { $0 == rootThreadID }
        if pinned {
            confirmedNativePinnedThreadIDs.insert(rootThreadID, at: 0)
            confirmedNativePinnedThreadSnapshotsByRootID[rootThreadID] =
                snapshotThreadsForPinnedRoot(rootThreadID) ?? [CodexThread(id: rootThreadID)]
        } else {
            confirmedNativePinnedThreadSnapshotsByRootID.removeValue(forKey: rootThreadID)
        }
        persistConfirmedNativePinnedThreadState()
        rebuildEffectivePinnedThreadState()
    }

    private func withSerializedNativePinOperation<T>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        await nativePinOperationGate.acquire()
        do {
            let value = try await operation()
            await nativePinOperationGate.release()
            return value
        } catch {
            await nativePinOperationGate.release()
            throw error
        }
    }

    private func userFacingNativePinMutationError(_ error: Error) -> Error {
        guard isUnsupportedNativePinError(error) else {
            return error
        }
        return CodexServiceError.invalidInput("Update Codex to synchronize pins.")
    }

    private func nativePinBackgroundErrorMessage(for error: Error) -> String {
        if isUnsupportedNativePinError(error) {
            return "Update Codex to synchronize pins."
        }
        return "Pins could not be refreshed. The last confirmed pin state is still shown."
    }

    func rebuildEffectivePinnedThreadState() {
        let effectiveIDs: [String]
        let effectiveSnapshots: [String: [CodexThread]]
        switch pinnedStateAuthority {
        case .native:
            effectiveIDs = orderedUniqueThreadIDs(confirmedNativePinnedThreadIDs)
            effectiveSnapshots = confirmedNativePinnedThreadSnapshotsByRootID
        case .hostCompatibility:
            effectiveIDs = orderedUniqueThreadIDs(confirmedHostPinnedThreadIDs)
            effectiveSnapshots = confirmedHostPinnedThreadSnapshotsByRootID
        case .undecided:
            if !confirmedNativePinnedThreadIDs.isEmpty || confirmedHostPinnedThreadIDs.isEmpty {
                effectiveIDs = orderedUniqueThreadIDs(confirmedNativePinnedThreadIDs)
                effectiveSnapshots = confirmedNativePinnedThreadSnapshotsByRootID
            } else {
                effectiveIDs = orderedUniqueThreadIDs(confirmedHostPinnedThreadIDs)
                effectiveSnapshots = confirmedHostPinnedThreadSnapshotsByRootID
            }
        }

        pinnedThreadIDs = effectiveIDs
        pinnedThreadSnapshotsByRootID = effectiveSnapshots.filter {
            pinnedThreadIDs.contains($0.key)
        }
    }

    func persistConfirmedNativePinnedThreadState() {
        let uniqueIDs = orderedUniqueThreadIDs(confirmedNativePinnedThreadIDs)
        confirmedNativePinnedThreadIDs = uniqueIDs
        confirmedNativePinnedThreadSnapshotsByRootID = confirmedNativePinnedThreadSnapshotsByRootID.filter {
            uniqueIDs.contains($0.key)
        }

        let idsKey = macScopedDefaultsKey(Self.nativePinnedThreadIDsDefaultsKey)
        let snapshotsKey = macScopedDefaultsKey(Self.nativePinnedThreadSnapshotsDefaultsKey)
        guard !uniqueIDs.isEmpty else {
            confirmedNativePinnedThreadSnapshotsByRootID.removeAll()
            defaults.removeObject(forKey: idsKey)
            defaults.removeObject(forKey: snapshotsKey)
            return
        }

        if let encodedIDs = try? encoder.encode(uniqueIDs) {
            defaults.set(encodedIDs, forKey: idsKey)
        }
        if let encodedSnapshots = try? encoder.encode(confirmedNativePinnedThreadSnapshotsByRootID) {
            defaults.set(encodedSnapshots, forKey: snapshotsKey)
        }
    }

    func persistConfirmedHostPinnedThreadState() {
        confirmedHostPinnedThreadIDs = orderedUniqueThreadIDs(confirmedHostPinnedThreadIDs)
        confirmedHostPinnedThreadSnapshotsByRootID = confirmedHostPinnedThreadSnapshotsByRootID.filter {
            confirmedHostPinnedThreadIDs.contains($0.key)
        }

        let idsKey = macScopedDefaultsKey(Self.hostPinnedThreadIDsDefaultsKey)
        let snapshotsKey = macScopedDefaultsKey(Self.hostPinnedThreadSnapshotsDefaultsKey)
        if let encodedIDs = try? encoder.encode(confirmedHostPinnedThreadIDs) {
            defaults.set(encodedIDs, forKey: idsKey)
        }
        if let encodedSnapshots = try? encoder.encode(confirmedHostPinnedThreadSnapshotsByRootID) {
            defaults.set(encodedSnapshots, forKey: snapshotsKey)
        }
    }

    func persistPinnedStateAuthority() {
        guard let encodedAuthority = try? encoder.encode(pinnedStateAuthority) else {
            return
        }
        defaults.set(
            encodedAuthority,
            forKey: macScopedDefaultsKey(Self.pinnedStateAuthorityDefaultsKey)
        )
    }

    private func resolveNativePinnedSection(context: NativePinOperationContext) async throws -> NativeThreadSection? {
        var cursor: JSONValue = .null
        var seenCursors: Set<String> = []
        repeat {
            if let cursorValue = cursor.stringValue,
               !seenCursors.insert(cursorValue).inserted {
                throw CodexServiceError.invalidResponse("threadSection/list pagination did not complete")
            }
            let response = try await sendRequest(
                method: "threadSection/list",
                params: .object(["cursor": cursor, "limit": .integer(100)]),
                timeoutNanoseconds: ThreadListHydrationPolicy.requestTimeoutNanoseconds,
                timeoutMessage: "threadSection/list timed out while synchronizing pins."
            )
            try requireCurrentNativePinOperation(context)
            guard let result = response.result?.objectValue else {
                throw CodexServiceError.invalidResponse("threadSection/list response missing payload")
            }
            let rawSections: [JSONValue]?
            if let data = result["data"]?.arrayValue {
                rawSections = data
            } else if let items = result["items"]?.arrayValue {
                rawSections = items
            } else {
                rawSections = result["sections"]?.arrayValue
            }
            guard let rawSections else {
                throw CodexServiceError.invalidResponse("threadSection/list response missing sections")
            }

            for rawSection in rawSections {
                if let section = nativeThreadSection(from: rawSection), section.name == "Pinned" {
                    return section
                }
            }
            cursor = nativePinNextCursor(from: result)
        } while hasNativePinCursor(cursor)

        return nil
    }

    private func createNativePinnedSection(context: NativePinOperationContext) async throws -> NativeThreadSection {
        let response = try await sendRequest(
            method: "threadSection/create",
            params: .object(["name": .string("Pinned")]),
            timeoutNanoseconds: ThreadListHydrationPolicy.requestTimeoutNanoseconds,
            timeoutMessage: "threadSection/create timed out while synchronizing pins."
        )
        try requireCurrentNativePinOperation(context)
        guard let result = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("threadSection/create response missing payload")
        }
        let rawSection: JSONValue
        if let section = result["section"] {
            rawSection = section
        } else {
            rawSection = .object(result)
        }
        guard let section = nativeThreadSection(from: rawSection), section.name == "Pinned" else {
            throw CodexServiceError.invalidResponse("threadSection/create response missing Pinned section")
        }
        nativePinnedSectionID = section.id
        nativePinCapability = .available
        return section
    }

    private func fetchNativePinnedThreads(
        sectionID: String,
        context: NativePinOperationContext
    ) async throws -> [CodexThread] {
        var threads: [CodexThread] = []
        var cursor: JSONValue = .null
        var sourceKinds = threadListSourceKinds
        var seenCursors: Set<String> = []

        repeat {
            if let cursorValue = cursor.stringValue,
               !seenCursors.insert(cursorValue).inserted {
                throw CodexServiceError.invalidResponse("Pinned thread/list pagination did not complete")
            }
            let page: (threads: [CodexThread], nextCursor: JSONValue)
            do {
                page = try await fetchNativePinnedThreadsPage(
                    sectionID: sectionID,
                    cursor: cursor,
                    sourceKinds: sourceKinds,
                    context: context
                )
            } catch {
                try requireCurrentNativePinOperation(context)
                if error is CancellationError {
                    throw error
                }
                guard sourceKinds == threadListSourceKinds,
                      shouldRetryThreadListWithLegacySourceKinds(error) else {
                    throw error
                }
                sourceKinds = legacyThreadListSourceKinds
                page = try await fetchNativePinnedThreadsPage(
                    sectionID: sectionID,
                    cursor: cursor,
                    sourceKinds: sourceKinds,
                    context: context
                )
            }
            try requireCurrentNativePinOperation(context)
            threads.append(contentsOf: page.threads)
            cursor = page.nextCursor
        } while hasNativePinCursor(cursor)

        return threads
    }

    private func fetchNativePinnedThreadsPage(
        sectionID: String,
        cursor: JSONValue,
        sourceKinds: [String],
        context: NativePinOperationContext
    ) async throws -> (threads: [CodexThread], nextCursor: JSONValue) {
        try requireCurrentNativePinOperation(context)
        let response = try await sendRequest(
            method: "thread/list",
            params: .object([
                "sectionId": .string(sectionID),
                "sortKey": .string("section_position"),
                "sortDirection": .string("asc"),
                "sourceKinds": .array(sourceKinds.map(JSONValue.string)),
                "cursor": cursor,
                "limit": .integer(100),
            ]),
            timeoutNanoseconds: ThreadListHydrationPolicy.requestTimeoutNanoseconds,
            timeoutMessage: "thread/list timed out while synchronizing pins."
        )
        try requireCurrentNativePinOperation(context)
        guard let result = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("Pinned thread/list response missing payload")
        }
        let rawThreads: [JSONValue]?
        if let data = result["data"]?.arrayValue {
            rawThreads = data
        } else if let items = result["items"]?.arrayValue {
            rawThreads = items
        } else {
            rawThreads = result["threads"]?.arrayValue
        }
        guard let rawThreads else {
            throw CodexServiceError.invalidResponse("Pinned thread/list response missing data array")
        }
        let decodedResults = await decodeModelsOffMain(
            CodexThread.self,
            from: rawThreads,
            omittingTopLevelKeys: ["turns"]
        )
        try requireCurrentNativePinOperation(context)
        guard decodedResults.count == rawThreads.count,
              decodedResults.allSatisfy({ $0 != nil }) else {
            throw CodexServiceError.invalidResponse("Pinned thread/list response contained malformed data")
        }
        let decodedThreads = decodedResults.compactMap { $0 }
        return (decodedThreads, nativePinNextCursor(from: result))
    }

    private func replaceConfirmedNativePinsCache(with threads: [CodexThread]) {
        confirmedNativePinnedThreadIDs = orderedUniqueThreadIDs(threads.map(\.id))
        var returnedThreadsByID: [String: [CodexThread]] = [:]
        for thread in threads where returnedThreadsByID[thread.id] == nil {
            let cachedSnapshot = confirmedNativePinnedThreadSnapshotsByRootID[thread.id]
                ?? []
            returnedThreadsByID[thread.id] = [thread] + cachedSnapshot.filter { $0.id != thread.id }
        }
        confirmedNativePinnedThreadSnapshotsByRootID = returnedThreadsByID
        persistConfirmedNativePinnedThreadState()
    }

    private func orderedPinnedThreads(_ threads: [CodexThread], appServerOrder: [String]?) -> [CodexThread] {
        var threadsByID: [String: CodexThread] = [:]
        for thread in threads {
            guard let threadID = normalizedNativePinIdentifier(thread.id),
                  threadsByID[threadID] == nil else {
                continue
            }
            threadsByID[threadID] = thread
        }

        let ids = orderedPinnedThreadIDs(threads.map(\.id), appServerOrder: appServerOrder)
        return ids.compactMap { threadsByID[$0] }
    }

    private func orderedPinnedThreadIDs(_ ids: [String], appServerOrder: [String]?) -> [String] {
        let uniqueIDs = orderedUniqueThreadIDs(ids)
        guard let appServerOrder else {
            return uniqueIDs
        }

        let availableIDs = Set(uniqueIDs)
        let desktopIDs = orderedUniqueThreadIDs(appServerOrder).filter(availableIDs.contains)
        let desktopIDSet = Set(desktopIDs)
        let desktopPositions = uniqueIDs.indices.filter { desktopIDSet.contains(uniqueIDs[$0]) }
        var mergedIDs = uniqueIDs
        for (position, id) in zip(desktopPositions, desktopIDs) {
            mergedIDs[position] = id
        }
        return mergedIDs
    }

    private func nativeThreadSection(from value: JSONValue) -> NativeThreadSection? {
        guard let object = value.objectValue,
              let id = normalizedNativePinIdentifier(object["id"]?.stringValue),
              let name = normalizedNativePinIdentifier(object["name"]?.stringValue) else {
            return nil
        }
        return NativeThreadSection(id: id, name: name)
    }

    private func nativePinNextCursor(from result: RPCObject) -> JSONValue {
        result["nextCursor"] ?? result["next_cursor"] ?? .null
    }

    private func hasNativePinCursor(_ cursor: JSONValue) -> Bool {
        normalizedNativePinIdentifier(cursor.stringValue) != nil
    }

    private func normalizedNativePinIdentifier(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private func orderedUniqueThreadIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { normalizedNativePinIdentifier($0) }.filter {
            seen.insert($0).inserted
        }
    }

    private func isUnsupportedNativePinError(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }
        if rpcError.code == -32601 {
            return true
        }
        guard rpcError.code == -32600 || rpcError.code == -32602 || rpcError.code == -32000 else {
            return false
        }
        let message = rpcError.message.lowercased()
        return message.contains("threadsection")
            || message.contains("thread/section")
            || message.contains("sectionid")
            || message.contains("section id")
            || message.contains("section_position")
    }
}
