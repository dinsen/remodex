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

private struct NativeThreadSection {
    let id: String
    let name: String
}

extension CodexService {
    func synchronizeNativePins() async throws {
        do {
            let section = try await resolveNativePinnedSection()
            guard let section else {
                nativePinnedSectionID = nil
                nativePinCapability = .available

                guard !legacyPinnedThreadIDs.isEmpty else {
                    replaceConfirmedNativePins(with: [])
                    return
                }

                let createdSection = try await createNativePinnedSection()
                try await migrateLegacyPins(into: createdSection)
                return
            }

            nativePinnedSectionID = section.id
            nativePinCapability = .available
            try await refreshConfirmedNativePins(sectionID: section.id)
            if !legacyPinnedThreadIDs.isEmpty {
                try await migrateLegacyPins(into: section)
            }
        } catch {
            if isUnsupportedNativePinError(error) {
                nativePinCapability = .unsupported
            }
            throw error
        }
    }

    func rebuildEffectivePinnedThreadState() {
        var seen: Set<String> = []
        pinnedThreadIDs = (legacyPinnedThreadIDs + confirmedNativePinnedThreadIDs).filter {
            seen.insert($0).inserted
        }

        var effectiveSnapshots: [String: [CodexThread]] = [:]
        for threadID in pinnedThreadIDs {
            if let legacySnapshot = legacyPinnedThreadSnapshotsByRootID[threadID] {
                effectiveSnapshots[threadID] = legacySnapshot
            } else if let nativeSnapshot = confirmedNativePinnedThreadSnapshotsByRootID[threadID] {
                effectiveSnapshots[threadID] = nativeSnapshot
            }
        }
        pinnedThreadSnapshotsByRootID = effectiveSnapshots
    }

    func clearCompletedLegacyPinMigration() {
        legacyPinnedThreadIDs.removeAll()
        legacyPinnedThreadSnapshotsByRootID.removeAll()
        defaults.removeObject(forKey: macScopedDefaultsKey(Self.pinnedThreadIDsDefaultsKey))
        defaults.removeObject(forKey: macScopedDefaultsKey(Self.pinnedThreadSnapshotsDefaultsKey))
        rebuildEffectivePinnedThreadState()
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

    private func migrateLegacyPins(into section: NativeThreadSection) async throws {
        try await refreshConfirmedNativePins(sectionID: section.id)

        let confirmedIDs = Set(confirmedNativePinnedThreadIDs)
        let missingLegacyIDs = orderedUniqueThreadIDs(legacyPinnedThreadIDs).filter {
            !confirmedIDs.contains($0)
        }
        var firstPinnedThreadID = confirmedNativePinnedThreadIDs.first

        for threadID in missingLegacyIDs.reversed() {
            var params: RPCObject = [
                "threadId": .string(threadID),
                "sectionId": .string(section.id),
            ]
            if let firstPinnedThreadID {
                params["beforeThreadId"] = .string(firstPinnedThreadID)
            }
            _ = try await sendRequest(
                method: "thread/section/move",
                params: .object(params),
                timeoutNanoseconds: ThreadListHydrationPolicy.requestTimeoutNanoseconds,
                timeoutMessage: "thread/section/move timed out while migrating pins."
            )
            firstPinnedThreadID = threadID
        }

        try await refreshConfirmedNativePins(sectionID: section.id)
        let refreshedIDs = Set(confirmedNativePinnedThreadIDs)
        guard legacyPinnedThreadIDs.allSatisfy(refreshedIDs.contains) else {
            throw CodexServiceError.invalidResponse("Codex did not confirm every migrated pin")
        }
        clearCompletedLegacyPinMigration()
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
            returnedThreadsByID[thread.id] = [thread]
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
