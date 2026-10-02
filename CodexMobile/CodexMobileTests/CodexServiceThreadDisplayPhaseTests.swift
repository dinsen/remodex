// FILE: CodexServiceThreadDisplayPhaseTests.swift
// Purpose: Verifies thread display gates and pagination state do not regress loading UX.
// Layer: Unit Test
// Exports: CodexServiceThreadDisplayPhaseTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceThreadDisplayPhaseTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testThreadDisplayPhaseTreatsFreshPlaceholderThreadAsEmpty() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(
                id: threadID,
                title: CodexThread.defaultDisplayTitle,
                preview: nil,
                syncState: .live
            )
        ]

        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .empty)
    }

    func testThreadDisplayPhaseKeepsUnhydratedThreadWithPreviewLoading() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(
                id: threadID,
                title: CodexThread.defaultDisplayTitle,
                preview: "Existing message preview",
                syncState: .live
            )
        ]

        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .loading)
    }

    func testThreadDisplayPhaseKeepsBlankPlaceholderEmptyEvenIfLoadingStateAlreadyStarted() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(
                id: threadID,
                title: CodexThread.defaultDisplayTitle,
                preview: nil,
                syncState: .live
            )
        ]
        service.hydratedThreadIDs.insert(threadID)
        service.loadingThreadIDs.insert(threadID)

        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .empty)
    }

    func testFreshInitialPageDoesNotReviveOlderCursorAfterAuthoritativeStart() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.markThreadLocalHistoryStartAuthoritative(threadID, clearRemoteCursor: true)
        service.updateOlderThreadHistoryCursorFromInitialPage(
            threadId: threadID,
            cursor: .string("next-page"),
            isFreshInitialLoad: true
        )

        XCTAssertTrue(service.hasAuthoritativeLocalHistoryStart(threadId: threadID))
        XCTAssertFalse(service.hasRemoteOlderThreadHistoryCursor(threadId: threadID))
        XCTAssertFalse(service.canLoadOlderThreadHistory(threadId: threadID))
    }

    func testFreshInitialPageSeedsOlderCursorWhenStartIsUnknown() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.updateOlderThreadHistoryCursorFromInitialPage(
            threadId: threadID,
            cursor: .string("next-page"),
            isFreshInitialLoad: true
        )

        XCTAssertFalse(service.hasAuthoritativeLocalHistoryStart(threadId: threadID))
        XCTAssertTrue(service.hasRemoteOlderThreadHistoryCursor(threadId: threadID))
        XCTAssertTrue(service.canLoadOlderThreadHistory(threadId: threadID))
    }

    func testPrepareThreadForDisplayKeepsThreadLiveWhenResumeReportsMissing() async {
        let service = makeService()
        service.isConnected = true
        service.upsertThread(CodexThread(id: "thread-selected", title: "Selected"))

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            switch method {
            case "thread/resume":
                throw CodexServiceError.rpcError(
                    RPCError(code: -32000, message: "thread not found")
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        let didPrepare = await service.prepareThreadForDisplay(threadId: "thread-selected")

        XCTAssertFalse(didPrepare)
        XCTAssertEqual(recordedMethods, ["thread/resume"])
        XCTAssertEqual(service.activeThreadId, "thread-selected")
        XCTAssertEqual(service.thread(for: "thread-selected")?.syncState, .live)
    }

    func testIdleReleaseWaitsForResumeAndReopenResubscribesAfterCoalescedDisplay() async {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.threads = [
            CodexThread(
                id: threadID,
                title: "Existing chat",
                preview: "Existing history",
                syncState: .live
            )
        ]

        let firstResumeStarted = expectation(description: "first resume started")
        let secondResumeStarted = expectation(description: "reopened thread resumed")
        var resumeCount = 0
        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            if method == "thread/resume" {
                resumeCount += 1
                if resumeCount == 1 {
                    firstResumeStarted.fulfill()
                    try await Task.sleep(nanoseconds: 150_000_000)
                } else if resumeCount == 2 {
                    secondResumeStarted.fulfill()
                }
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        let initialDisplay = Task { await service.prepareThreadForDisplay(threadId: threadID) }
        await fulfillment(of: [firstResumeStarted], timeout: 1)
        let coalescedDisplay = Task { await service.prepareThreadForDisplay(threadId: threadID) }
        await Task.yield()

        XCTAssertFalse(service.scheduleThreadSubscriptionReleaseIfIdle(threadId: threadID))
        let reopenedDisplay = Task { await service.prepareThreadForDisplay(threadId: threadID) }

        await fulfillment(of: [secondResumeStarted], timeout: 3)
        let initialDisplaySucceeded = await initialDisplay.value
        let coalescedDisplaySucceeded = await coalescedDisplay.value
        let reopenedDisplaySucceeded = await reopenedDisplay.value
        XCTAssertTrue(initialDisplaySucceeded)
        XCTAssertFalse(coalescedDisplaySucceeded)
        XCTAssertTrue(reopenedDisplaySucceeded)
        XCTAssertTrue(service.resumedThreadIDs.contains(threadID))

        let unsubscribeIndex = try! XCTUnwrap(recordedMethods.firstIndex(of: "thread/unsubscribe"))
        let resumeIndices = recordedMethods.indices.filter { recordedMethods[$0] == "thread/resume" }
        XCTAssertGreaterThanOrEqual(resumeIndices.count, 2)
        XCTAssertLessThan(resumeIndices[0], unsubscribeIndex)
        XCTAssertLessThan(unsubscribeIndex, resumeIndices[1])
    }

    func testReleaseLeavesRunningThreadOwned() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        service.isConnected = true
        service.resumedThreadIDs.insert(threadID)
        service.runningThreadIDs.insert(threadID)
        service.requestTransportOverride = { method, _ in
            XCTFail("Running thread must not unsubscribe: \(method)")
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        XCTAssertFalse(service.scheduleThreadSubscriptionReleaseIfIdle(threadId: threadID))
        XCTAssertNil(service.threadUnsubscribeTaskByThreadID[threadID])
        XCTAssertTrue(service.resumedThreadIDs.contains(threadID))
        XCTAssertTrue(service.threadHasActiveOrRunningTurn(threadID))
    }

    func testUnsubscribeErrorDoesNotPreventDesktopHandoff() async throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        service.isConnected = true
        service.resumedThreadIDs.insert(threadID)
        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            if method == "thread/unsubscribe" {
                throw CodexServiceError.rpcError(RPCError(code: -32601, message: "Method not found"))
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["success": .bool(true)]),
                includeJSONRPC: false
            )
        }

        await service.releaseThreadSubscriptionIfIdle(threadId: threadID)
        try await DesktopHandoffService(codex: service).continueOnDesktopApp(threadId: threadID)

        XCTAssertEqual(recordedMethods, ["thread/unsubscribe", "desktop/continueOnDesktop"])
        XCTAssertFalse(service.resumedThreadIDs.contains(threadID))
    }

    func testTimedOutExistingThreadWithoutCacheRemainsLoading() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        service.activeThreadId = threadID
        service.threads = [
            CodexThread(
                id: threadID,
                title: "Large existing chat",
                preview: "Existing history",
                syncState: .live
            )
        ]

        service.markThreadHistoryDeferredAfterTimeout(threadId: threadID)

        XCTAssertFalse(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertFalse(service.hydratedThreadIDs.contains(threadID))
        XCTAssertTrue(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .loading)
    }

    func testRepairClearsPersistedAuthoritativeEmptyHistoryState() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        service.threads = [
            CodexThread(
                id: threadID,
                title: "Previously poisoned chat",
                preview: "Existing history",
                syncState: .live
            )
        ]
        service.hydratedThreadIDs.insert(threadID)
        service.initialTurnsLoadedByThreadID.insert(threadID)
        service.markThreadLocalHistoryStartAuthoritative(threadID, clearRemoteCursor: true)

        service.repairEmptyThreadHistoryLoadStateIfNeeded(threadId: threadID)

        XCTAssertFalse(service.hydratedThreadIDs.contains(threadID))
        XCTAssertFalse(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertFalse(service.hasAuthoritativeLocalHistoryStart(threadId: threadID))
        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .loading)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceThreadDisplayPhaseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}
