// FILE: CodexThreadRenamePersistenceTests.swift
// Purpose: Verifies custom sidebar thread names survive app relaunches and are cleaned up on deletion.
// Layer: Unit Test
// Exports: CodexThreadRenamePersistenceTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadRenamePersistenceTests: XCTestCase {
    func testRenamePersistsAcrossServiceReload() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Renamed Thread")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Renamed Thread")
        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.name, "Renamed Thread")
    }

    func testDeletingThreadClearsPersistedRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Renamed Thread")
        service.deleteThread("thread-1")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "New Thread")
    }

    func testExplicitServerRenameClearsPersistedLocalRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Mac Rename",
                name: "Mac Rename",
                cwd: "/tmp/remodex"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Mac Rename")

        let secondReloadedService = CodexService(defaults: defaults)
        secondReloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(secondReloadedService.thread(for: "thread-1")?.displayTitle, "New Thread")
    }

    func testServerTitleOnlyRenameClearsPersistedLocalRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Mac Title Rename",
                cwd: "/tmp/remodex"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Mac Title Rename")

        let secondReloadedService = CodexService(defaults: defaults)
        secondReloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(secondReloadedService.thread(for: "thread-1")?.displayTitle, "New Thread")
    }

    func testFallbackConversationTitleDoesNotOverridePersistedRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")
    }

    func testHostCompatibilityStateIsMacScopedAndReloadsInOrder() throws {
        let suiteName = "CodexThreadRenamePersistenceTests.host-scope.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        let firstMacID = "host-mac-one"
        let secondMacID = "host-mac-two"
        let firstIDs = ["host-one", "host-two"]
        let secondIDs = ["other-one"]
        let firstSnapshots = [firstIDs[0]: [CodexThread(id: firstIDs[0])]]
        let secondSnapshots = [secondIDs[0]: [CodexThread(id: secondIDs[0])]]

        try defaults.set(
            service.encoder.encode(firstIDs),
            forKey: service.macScopedDefaultsKey(CodexService.hostPinnedThreadIDsDefaultsKey, macDeviceId: firstMacID)
        )
        try defaults.set(
            service.encoder.encode(firstSnapshots),
            forKey: service.macScopedDefaultsKey(CodexService.hostPinnedThreadSnapshotsDefaultsKey, macDeviceId: firstMacID)
        )
        try defaults.set(
            service.encoder.encode(CodexPinnedStateAuthority.hostCompatibility),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedStateAuthorityDefaultsKey, macDeviceId: firstMacID)
        )
        try defaults.set(
            service.encoder.encode(secondIDs),
            forKey: service.macScopedDefaultsKey(CodexService.hostPinnedThreadIDsDefaultsKey, macDeviceId: secondMacID)
        )
        try defaults.set(
            service.encoder.encode(secondSnapshots),
            forKey: service.macScopedDefaultsKey(CodexService.hostPinnedThreadSnapshotsDefaultsKey, macDeviceId: secondMacID)
        )
        try defaults.set(
            service.encoder.encode(CodexPinnedStateAuthority.hostCompatibility),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedStateAuthorityDefaultsKey, macDeviceId: secondMacID)
        )

        service.loadMacScopedDefaultsState(for: firstMacID)
        XCTAssertEqual(service.confirmedHostPinnedThreadIDs, firstIDs)
        XCTAssertEqual(service.pinnedThreadIDs, firstIDs)
        XCTAssertEqual(service.pinnedStateAuthority, .hostCompatibility)
        XCTAssertEqual(service.pinnedThreadSnapshotsByRootID[firstIDs[0]]?.first?.id, firstIDs[0])

        service.loadMacScopedDefaultsState(for: secondMacID)
        XCTAssertEqual(service.confirmedHostPinnedThreadIDs, secondIDs)
        XCTAssertEqual(service.pinnedThreadIDs, secondIDs)
        XCTAssertEqual(service.pinnedStateAuthority, .hostCompatibility)
        XCTAssertEqual(service.pinnedThreadSnapshotsByRootID[secondIDs[0]]?.first?.id, secondIDs[0])
    }

    func testNativeAuthorityDropsHostCacheOnReload() throws {
        let suiteName = "CodexThreadRenamePersistenceTests.native-authority.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        let macDeviceID = "native-authority-mac"
        let nativeIDs = ["native-one"]
        let hostIDs = ["host-stale"]
        try defaults.set(
            service.encoder.encode(nativeIDs),
            forKey: service.macScopedDefaultsKey(CodexService.nativePinnedThreadIDsDefaultsKey, macDeviceId: macDeviceID)
        )
        try defaults.set(
            service.encoder.encode(hostIDs),
            forKey: service.macScopedDefaultsKey(CodexService.hostPinnedThreadIDsDefaultsKey, macDeviceId: macDeviceID)
        )
        try defaults.set(
            service.encoder.encode(CodexPinnedStateAuthority.native),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedStateAuthorityDefaultsKey, macDeviceId: macDeviceID)
        )

        service.loadMacScopedDefaultsState(for: macDeviceID)

        XCTAssertEqual(service.pinnedStateAuthority, .native)
        XCTAssertEqual(service.pinnedThreadIDs, nativeIDs)
        XCTAssertEqual(service.confirmedNativePinnedThreadIDs, nativeIDs)
        XCTAssertEqual(service.confirmedHostPinnedThreadIDs, [])
        XCTAssertNil(defaults.data(
            forKey: service.macScopedDefaultsKey(CodexService.hostPinnedThreadIDsDefaultsKey, macDeviceId: macDeviceID)
        ))
    }

    func testLegacyPinsAreDiscardedDuringCoalescedMacMigration() throws {
        let suiteName = "CodexThreadRenamePersistenceTests.legacy-coalescing.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        let staleMacID = "legacy-stale-mac"
        let freshMacID = "legacy-fresh-mac"
        try defaults.set(
            service.encoder.encode(["legacy-stale"]),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadIDsDefaultsKey, macDeviceId: staleMacID)
        )
        try defaults.set(
            service.encoder.encode(["legacy-fresh"]),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadIDsDefaultsKey, macDeviceId: freshMacID)
        )
        try defaults.set(
            service.encoder.encode(["native-kept"]),
            forKey: service.macScopedDefaultsKey(CodexService.nativePinnedThreadIDsDefaultsKey, macDeviceId: freshMacID)
        )
        try defaults.set(
            service.encoder.encode(["host-kept"]),
            forKey: service.macScopedDefaultsKey(CodexService.hostPinnedThreadIDsDefaultsKey, macDeviceId: freshMacID)
        )
        try defaults.set(
            service.encoder.encode(CodexPinnedStateAuthority.native),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedStateAuthorityDefaultsKey, macDeviceId: freshMacID)
        )

        _ = service.migrateMacScopedState(from: [staleMacID], to: freshMacID)
        service.loadMacScopedDefaultsState(for: freshMacID)

        XCTAssertNil(defaults.object(
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadIDsDefaultsKey, macDeviceId: staleMacID)
        ))
        XCTAssertNil(defaults.object(
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadIDsDefaultsKey, macDeviceId: freshMacID)
        ))
        XCTAssertEqual(service.confirmedNativePinnedThreadIDs, ["native-kept"])
        XCTAssertEqual(service.confirmedHostPinnedThreadIDs, [])
        XCTAssertEqual(service.pinnedThreadIDs, ["native-kept"])
        XCTAssertEqual(service.pinnedStateAuthority, .native)
    }

    func testMacScopedPinMigrationKeepsAuthoritativeTargetSnapshot() throws {
        let suiteName = "CodexThreadRenamePersistenceTests.authoritative-pin-coalescing.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        let staleMacID = "stale-pin-mac"
        let targetMacID = "target-pin-mac"
        let targetThread = CodexThread(id: "target-pin")
        let staleThread = CodexThread(id: "stale-pin")

        try defaults.set(
            service.encoder.encode([targetThread.id]),
            forKey: service.macScopedDefaultsKey(CodexService.nativePinnedThreadIDsDefaultsKey, macDeviceId: targetMacID)
        )
        try defaults.set(
            service.encoder.encode([targetThread.id: [targetThread]]),
            forKey: service.macScopedDefaultsKey(CodexService.nativePinnedThreadSnapshotsDefaultsKey, macDeviceId: targetMacID)
        )
        try defaults.set(
            service.encoder.encode(CodexPinnedStateAuthority.native),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedStateAuthorityDefaultsKey, macDeviceId: targetMacID)
        )
        try defaults.set(
            service.encoder.encode([staleThread.id]),
            forKey: service.macScopedDefaultsKey(CodexService.nativePinnedThreadIDsDefaultsKey, macDeviceId: staleMacID)
        )
        try defaults.set(
            service.encoder.encode([staleThread.id: [staleThread]]),
            forKey: service.macScopedDefaultsKey(CodexService.nativePinnedThreadSnapshotsDefaultsKey, macDeviceId: staleMacID)
        )
        try defaults.set(
            service.encoder.encode(CodexPinnedStateAuthority.native),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedStateAuthorityDefaultsKey, macDeviceId: staleMacID)
        )

        _ = service.migrateMacScopedState(from: [staleMacID], to: targetMacID)
        service.loadMacScopedDefaultsState(for: targetMacID)

        XCTAssertEqual(service.confirmedNativePinnedThreadIDs, [targetThread.id])
        XCTAssertEqual(service.pinnedThreadIDs, [targetThread.id])
        XCTAssertEqual(
            service.confirmedNativePinnedThreadSnapshotsByRootID[targetThread.id]?.first?.id,
            targetThread.id
        )
        XCTAssertNil(service.confirmedNativePinnedThreadSnapshotsByRootID[staleThread.id])
        XCTAssertEqual(service.pinnedStateAuthority, .native)
    }

    func testUndecidedStateUsesLastConfirmedNativeCacheUntilProbe() throws {
        let suiteName = "CodexThreadRenamePersistenceTests.undecided.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        let macDeviceID = "undecided-mac"
        try defaults.set(
            service.encoder.encode(["native-first-paint"]),
            forKey: service.macScopedDefaultsKey(CodexService.nativePinnedThreadIDsDefaultsKey, macDeviceId: macDeviceID)
        )
        try defaults.set(
            service.encoder.encode(["host-waiting"]),
            forKey: service.macScopedDefaultsKey(CodexService.hostPinnedThreadIDsDefaultsKey, macDeviceId: macDeviceID)
        )

        service.loadMacScopedDefaultsState(for: macDeviceID)

        XCTAssertEqual(service.pinnedStateAuthority, .undecided)
        XCTAssertEqual(service.pinnedThreadIDs, ["native-first-paint"])
    }

    func testLegacyPinsAreDiscardedOnLoad() throws {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        let macDeviceID = "legacy-pin-mac"
        defaults.set(
            try JSONEncoder().encode(["legacy-one", "shared"]),
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadIDsDefaultsKey, macDeviceId: macDeviceID)
        )
        defaults.set(
            try JSONEncoder().encode(["shared", "native-one"]),
            forKey: service.macScopedDefaultsKey(CodexService.nativePinnedThreadIDsDefaultsKey, macDeviceId: macDeviceID)
        )

        service.clearInMemoryMacScopedState()
        service.loadMacScopedDefaultsState(for: macDeviceID)

        XCTAssertEqual(service.confirmedNativePinnedThreadIDs, ["shared", "native-one"])
        XCTAssertEqual(service.pinnedThreadIDs, ["shared", "native-one"])
        XCTAssertNil(defaults.data(
            forKey: service.macScopedDefaultsKey(CodexService.pinnedThreadIDsDefaultsKey, macDeviceId: macDeviceID)
        ))
    }

    func testDeletingThreadPreservesConfirmedNativePin() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        seedConfirmedPin("thread-1", in: service)
        service.deleteThread("thread-1")

        let reloadedService = CodexService(defaults: defaults)

        XCTAssertEqual(reloadedService.pinnedThreadIDs, ["thread-1"])
        XCTAssertTrue(reloadedService.isThreadPinned("thread-1"))
    }

    func testPinnedSnapshotRehydratesThreadWhenFreshServiceHasNoServerThreadsYet() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Pinned Thread",
                preview: "Saved locally",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                cwd: "/tmp/remodex"
            ),
        ]
        seedConfirmedPin("thread-1", in: service)

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.reconcileLocalThreadsWithServer([])

        XCTAssertEqual(reloadedService.pinnedThreadIDs, ["thread-1"])
        XCTAssertEqual(reloadedService.threads.map(\.id), ["thread-1"])
        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Pinned Thread")
    }

    func testPinnedSnapshotRehydrateKeepsPersistedRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Original Pinned Thread",
                preview: "Saved locally",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                cwd: "/tmp/remodex"
            ),
        ]
        seedConfirmedPin("thread-1", in: service)
        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.reconcileLocalThreadsWithServer([])

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")
        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.name, "Phone Rename")
    }

    func testArchivingPinnedChildDoesNotClearPinnedRoot() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "root-thread",
                title: "Root Thread",
                cwd: "/tmp/remodex"
            ),
            CodexThread(
                id: "child-thread",
                title: "Child Thread",
                cwd: "/tmp/remodex",
                parentThreadId: "root-thread"
            ),
        ]
        seedConfirmedPin("root-thread", in: service)

        service.archiveThread("child-thread")

        XCTAssertEqual(service.pinnedThreadIDs, ["root-thread"])
        XCTAssertTrue(service.isThreadPinned("root-thread"))
        XCTAssertTrue(service.thread(for: "child-thread")?.syncState == .archivedLocal)
    }

    func testRemoteArchiveCascadesThroughChildThreads() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "root-thread",
                title: "Root Thread",
                cwd: "/tmp/remodex"
            ),
            CodexThread(
                id: "child-thread",
                title: "Child Thread",
                cwd: "/tmp/remodex",
                parentThreadId: "root-thread"
            ),
        ]

        service.applyRemoteThreadArchiveState(threadId: "root-thread", isArchived: true)

        XCTAssertTrue(service.thread(for: "root-thread")?.syncState == .archivedLocal)
        XCTAssertTrue(service.thread(for: "child-thread")?.syncState == .archivedLocal)

        service.applyRemoteThreadArchiveState(threadId: "root-thread", isArchived: false)

        XCTAssertTrue(service.thread(for: "root-thread")?.syncState == .live)
        XCTAssertTrue(service.thread(for: "child-thread")?.syncState == .live)
    }

    func testRemoteArchivePreservesActiveRuntimeState() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "running-thread",
                title: "Running Thread",
                cwd: "/tmp/remodex"
            ),
        ]
        service.runningThreadIDs.insert("running-thread")
        service.activeTurnIdByThread["running-thread"] = "turn-live"
        service.activeTurnId = "turn-live"
        service.threadIdByTurnID["turn-live"] = "running-thread"

        service.applyRemoteThreadArchiveState(threadId: "running-thread", isArchived: true)

        XCTAssertTrue(service.thread(for: "running-thread")?.syncState == .archivedLocal)
        XCTAssertTrue(service.runningThreadIDs.contains("running-thread"))
        XCTAssertEqual(service.activeTurnIdByThread["running-thread"], "turn-live")
        XCTAssertEqual(service.activeTurnId, "turn-live")
        XCTAssertEqual(service.threadIdByTurnID["turn-live"], "running-thread")
    }

    private func seedConfirmedPin(_ threadID: String, in service: CodexService) {
        service.confirmedNativePinnedThreadIDs = [threadID]
        if let snapshot = service.threads.first(where: { $0.id == threadID }) {
            service.confirmedNativePinnedThreadSnapshotsByRootID[threadID] = [snapshot]
        }
        service.persistConfirmedNativePinnedThreadState()
        service.rebuildEffectivePinnedThreadState()
    }
}
