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

enum CodexNativePinAuthorityProbe: Equatable {
    case complete([String])
    case missingSection
    case unsupported
    case malformed
    case incomplete
}

enum CodexHostPinAuthorityProbe: Equatable {
    case valid([String])
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
        if case .valid(let hostIDs) = host {
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
        try await withSerializedNativePinOperation {
            try await self.synchronizeNativePinsWithoutSerialization()
        }
    }

    func setThreadPinned(_ threadID: String, pinned: Bool) async throws {
        try await withSerializedNativePinOperation {
            try await self.setThreadPinnedWithoutSerialization(threadID, pinned: pinned)
        }
    }

    func refreshNativePinsForThreadHydration() async -> [CodexThread] {
        do {
            try await withSerializedNativePinOperation {
                do {
                    try await self.synchronizeNativePinsWithoutSerialization()
                } catch {
                    self.lastErrorMessage = self.nativePinBackgroundErrorMessage(for: error)
                }
                if self.pinnedStateAuthority == .hostCompatibility {
                    await self.hydrateConfirmedHostPinnedThreads()
                }
            }
        } catch {
            lastErrorMessage = nativePinBackgroundErrorMessage(for: error)
        }
        return confirmedNativePinnedThreadsForHydration()
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

    private func hydrateConfirmedHostPinnedThreads() async {
        var didChangeSnapshots = false
        for threadID in confirmedHostPinnedThreadIDs {
            if let liveThread = thread(for: threadID) {
                guard !liveThread.isSubagent else { continue }
                if let snapshot = snapshotThreadsForPinnedRoot(threadID), !snapshot.isEmpty {
                    if confirmedHostPinnedThreadSnapshotsByRootID[threadID] != snapshot {
                        confirmedHostPinnedThreadSnapshotsByRootID[threadID] = snapshot
                        didChangeSnapshots = true
                    }
                }
            }

            // Refresh authoritative metadata on every sync; the live row or cached snapshot remains the fallback on failure.
            do {
                guard let hydratedThread = try await readHostPinnedThread(threadID: threadID),
                      !hydratedThread.isSubagent else {
                    continue
                }
                upsertThread(hydratedThread, treatAsServerState: true)
                confirmedHostPinnedThreadSnapshotsByRootID[threadID] =
                    snapshotThreadsForPinnedRoot(threadID) ?? [hydratedThread]
                didChangeSnapshots = true
            } catch {
                // Keep the confirmed host ID and any prior snapshot. The next
                // serialized refresh retries only the row that is still absent.
                continue
            }
        }

        if didChangeSnapshots {
            persistConfirmedHostPinnedThreadState()
            rebuildEffectivePinnedThreadState()
        }
    }

    private func readHostPinnedThread(threadID: String) async throws -> CodexThread? {
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
            return try decodeHostPinnedThread(response, requestedThreadID: threadID)
        } catch {
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
            return try decodeHostPinnedThread(response, requestedThreadID: threadID)
        }
    }

    private func decodeHostPinnedThread(
        _ response: RPCMessage,
        requestedThreadID: String
    ) throws -> CodexThread? {
        if let error = response.error {
            throw CodexServiceError.rpcError(error)
        }
        guard let threadValue = response.result?.objectValue?["thread"],
              let decodedThread = decodeModel(CodexThread.self, from: threadValue) else {
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

    private func synchronizeNativePinsWithoutSerialization() async throws {
        var nativeProbe: CodexNativePinAuthorityProbe = .incomplete
        var nativeThreads: [CodexThread] = []
        var nativeError: Error?

        do {
            let section = try await resolveNativePinnedSection()
            guard let section else {
                nativePinnedSectionID = nil
                nativePinCapability = .available
                nativeProbe = .missingSection
                nativeThreads = []
                return try await finishNativePinSynchronization(
                    nativeProbe: nativeProbe,
                    nativeThreads: nativeThreads,
                    nativeError: nil
                )
            }

            nativePinnedSectionID = section.id
            nativePinCapability = .available
            let threads = try await fetchNativePinnedThreads(sectionID: section.id)
            nativeThreads = threads
            nativeProbe = .complete(orderedUniqueThreadIDs(threads.map(\.id)))
        } catch {
            if isUnsupportedNativePinError(error) {
                nativePinCapability = .unsupported
            }
            nativeError = error
            nativeThreads = []
            nativeProbe = nativePinAuthorityProbe(for: error)
        }

        try await finishNativePinSynchronization(
            nativeProbe: nativeProbe,
            nativeThreads: nativeThreads,
            nativeError: nativeError
        )
    }

    private func finishNativePinSynchronization(
        nativeProbe: CodexNativePinAuthorityProbe,
        nativeThreads: [CodexThread],
        nativeError: Error?
    ) async throws {
        let shouldReadHost = pinnedStateAuthority != .native
            && !isCompleteNonEmptyNativeProbe(nativeProbe)

        let hostProbe: CodexHostPinAuthorityProbe
        if shouldReadHost {
            hostProbe = await readHostPinAuthorityProbe()
        } else {
            hostProbe = .unavailable
        }

        let nextAuthority = codexPinnedStateAuthorityDecision(
            native: nativeProbe,
            host: hostProbe,
            current: pinnedStateAuthority
        )

        switch nextAuthority {
        case .native:
            if case .complete = nativeProbe {
                commitConfirmedNativePins(nativeThreads)
            }
        case .hostCompatibility:
            if case .valid(let hostIDs) = hostProbe {
                commitConfirmedHostPins(hostIDs)
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

    private func readHostPinAuthorityProbe() async -> CodexHostPinAuthorityProbe {
        do {
            let response = try await sendRequest(
                method: "bridge/hostPins/read",
                params: .object([:]),
                timeoutNanoseconds: ThreadListHydrationPolicy.requestTimeoutNanoseconds,
                timeoutMessage: "bridge/hostPins/read timed out while synchronizing pins."
            )
            if let error = response.error {
                return hostPinAuthorityProbe(for: error)
            }

            guard let result = response.result?.objectValue,
                  result["schemaVersion"]?.intValue == 1,
                  result["source"]?.stringValue == "codex-host",
                  let rawIDs = result["pinnedThreadIds"]?.arrayValue,
                  rawIDs.count <= 512 else {
                return .malformed
            }

            var seen: Set<String> = []
            let ids = rawIDs.compactMap { value -> String? in
                guard let id = value.stringValue,
                      !id.isEmpty,
                      id.count <= 256,
                      seen.insert(id).inserted else {
                    return nil
                }
                return id
            }
            guard ids.count == rawIDs.count else {
                return .malformed
            }
            return .valid(ids)
        } catch {
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

    private func commitConfirmedNativePins(_ threads: [CodexThread]) {
        replaceConfirmedNativePinsCache(with: threads)
        pinnedStateAuthority = .native
        persistPinnedStateAuthority()
        confirmedHostPinnedThreadIDs.removeAll()
        confirmedHostPinnedThreadSnapshotsByRootID.removeAll()
        defaults.removeObject(forKey: macScopedDefaultsKey(Self.hostPinnedThreadIDsDefaultsKey))
        defaults.removeObject(forKey: macScopedDefaultsKey(Self.hostPinnedThreadSnapshotsDefaultsKey))
        rebuildEffectivePinnedThreadState()
    }

    private func commitConfirmedHostPins(_ ids: [String]) {
        confirmedHostPinnedThreadIDs = orderedUniqueThreadIDs(ids)
        confirmedHostPinnedThreadSnapshotsByRootID = confirmedHostPinnedThreadSnapshotsByRootID.filter {
            confirmedHostPinnedThreadIDs.contains($0.key)
        }
        persistConfirmedHostPinnedThreadState()
        pinnedStateAuthority = .hostCompatibility
        persistPinnedStateAuthority()
        rebuildEffectivePinnedThreadState()
    }

    private func setThreadPinnedWithoutSerialization(_ threadID: String, pinned: Bool) async throws {
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
            try await synchronizeNativePinsWithoutSerialization()
        } catch {
            throw userFacingNativePinMutationError(error)
        }

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
                section = try await createNativePinnedSection()
            } catch {
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
        } catch {
            if isUnsupportedNativePinError(error) {
                nativePinCapability = .unsupported
            }
            throw userFacingNativePinMutationError(error)
        }

        applyConfirmedNativePinMutation(rootThreadID: rootThreadID, pinned: pinned)

        do {
            try await synchronizeNativePinsWithoutSerialization()
        } catch {
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

    private func resolveNativePinnedSection() async throws -> NativeThreadSection? {
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

    private func createNativePinnedSection() async throws -> NativeThreadSection {
        let response = try await sendRequest(
            method: "threadSection/create",
            params: .object(["name": .string("Pinned")]),
            timeoutNanoseconds: ThreadListHydrationPolicy.requestTimeoutNanoseconds,
            timeoutMessage: "threadSection/create timed out while synchronizing pins."
        )
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

    private func fetchNativePinnedThreads(sectionID: String) async throws -> [CodexThread] {
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
                    sourceKinds: sourceKinds
                )
            } catch {
                guard sourceKinds == threadListSourceKinds,
                      shouldRetryThreadListWithLegacySourceKinds(error) else {
                    throw error
                }
                sourceKinds = legacyThreadListSourceKinds
                page = try await fetchNativePinnedThreadsPage(
                    sectionID: sectionID,
                    cursor: cursor,
                    sourceKinds: sourceKinds
                )
            }
            threads.append(contentsOf: page.threads)
            cursor = page.nextCursor
        } while hasNativePinCursor(cursor)

        return threads
    }

    private func fetchNativePinnedThreadsPage(
        sectionID: String,
        cursor: JSONValue,
        sourceKinds: [String]
    ) async throws -> (threads: [CodexThread], nextCursor: JSONValue) {
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
        let decodedThreads = await CodexThreadPageDecoder.decode(rawThreads)
        guard decodedThreads.count == rawThreads.count else {
            throw CodexServiceError.invalidResponse("Pinned thread/list response contained malformed data")
        }
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
