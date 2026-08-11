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
            try await synchronizeNativePins()
        } catch {
            lastErrorMessage = nativePinBackgroundErrorMessage(for: error)
        }
        return confirmedNativePinnedThreadsForHydration()
    }

    func confirmedNativePinnedThreadsForHydration() -> [CodexThread] {
        var seen: Set<String> = []
        return confirmedNativePinnedThreadIDs.flatMap { confirmedNativePinnedThreadSnapshotsByRootID[$0] ?? [] }
            .filter { seen.insert($0.id).inserted }
    }

    private func synchronizeNativePinsWithoutSerialization() async throws {
        do {
            let section = try await resolveNativePinnedSection()
            guard let section else {
                nativePinnedSectionID = nil
                nativePinCapability = .available
                replaceConfirmedNativePins(with: [])
                return
            }

            nativePinnedSectionID = section.id
            nativePinCapability = .available
            try await refreshConfirmedNativePins(sectionID: section.id)
        } catch {
            if isUnsupportedNativePinError(error) {
                nativePinCapability = .unsupported
            }
            throw error
        }
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
        pinnedThreadIDs = orderedUniqueThreadIDs(confirmedNativePinnedThreadIDs)
        pinnedThreadSnapshotsByRootID = confirmedNativePinnedThreadSnapshotsByRootID.filter {
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

    private func resolveNativePinnedSection() async throws -> NativeThreadSection? {
        var cursor: JSONValue = .null
        repeat {
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

    private func refreshConfirmedNativePins(sectionID: String) async throws {
        let threads = try await fetchNativePinnedThreads(sectionID: sectionID)
        replaceConfirmedNativePins(with: threads)
    }

    private func fetchNativePinnedThreads(sectionID: String) async throws -> [CodexThread] {
        var threads: [CodexThread] = []
        var cursor: JSONValue = .null
        var sourceKinds = threadListSourceKinds

        repeat {
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
        return (await CodexThreadPageDecoder.decode(rawThreads), nativePinNextCursor(from: result))
    }

    private func replaceConfirmedNativePins(with threads: [CodexThread]) {
        confirmedNativePinnedThreadIDs = orderedUniqueThreadIDs(threads.map(\.id))
        var returnedThreadsByID: [String: [CodexThread]] = [:]
        for thread in threads where returnedThreadsByID[thread.id] == nil {
            let cachedSnapshot = confirmedNativePinnedThreadSnapshotsByRootID[thread.id]
                ?? []
            returnedThreadsByID[thread.id] = [thread] + cachedSnapshot.filter { $0.id != thread.id }
        }
        confirmedNativePinnedThreadSnapshotsByRootID = returnedThreadsByID
        persistConfirmedNativePinnedThreadState()
        rebuildEffectivePinnedThreadState()
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
