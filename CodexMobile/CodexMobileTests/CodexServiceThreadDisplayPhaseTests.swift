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

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceThreadDisplayPhaseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}
