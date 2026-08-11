// FILE: CodexServiceThreadListTests.swift
// Purpose: Verifies thread-list fetch shape and local ordering so sidebar results stay recent-activity ordered.
// Layer: Unit Test
// Exports: CodexServiceThreadListTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceThreadListTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testDecodeThreadSectionMetadata() throws {
        let data = Data(#"""
        [
          {
            "id": "thread-pinned",
            "section": { "id": "pinned-section", "name": "Pinned" },
            "sectionEnteredAt": 1786383000
          },
          {
            "id": "thread-unsectioned"
          }
        ]
        """#.utf8)

        let threads = try JSONDecoder().decode([CodexThread].self, from: data)

        XCTAssertEqual(threads[0].section?.id, "pinned-section")
        XCTAssertEqual(threads[0].section?.name, "Pinned")
        XCTAssertEqual(threads[0].sectionEnteredAt, Date(timeIntervalSince1970: 1_786_383_000))
        XCTAssertNil(threads[1].section)
        XCTAssertNil(threads[1].sectionEnteredAt)
    }

    func testListThreadsRequestsInitialAndCursorPagesAndAppServerSourceKinds() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var requestParams: [RPCObject] = []
        var requestCount = 0

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }

            requestCount += 1
            let activeRequestParams = params?.objectValue ?? [:]
            requestParams.append(activeRequestParams)

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([]),
                    "nextCursor": requestCount == 1 ? .string("cursor-page-2") : .null,
                ]),
                includeJSONRPC: false
            )
        }

        try await service.listThreads()

        XCTAssertEqual(requestParams.map { $0["limit"]?.intValue }, [10, 10])
        XCTAssertEqual(requestParams.compactMap { $0["cursor"] }, [.null, .string("cursor-page-2")])
        XCTAssertEqual(requestParams.map { $0["sortKey"]?.stringValue }, ["updated_at", "updated_at"])
        XCTAssertNil(requestParams.last?["archived"])
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(
            requestParams.last?["sourceKinds"]?.arrayValue?.compactMap(\.stringValue),
            [
                "cli",
                "vscode",
                "appServer",
                "exec",
                "subAgent",
                "subAgentReview",
                "subAgentCompact",
                "subAgentThreadSpawn",
                "subAgentOther",
                "unknown",
            ]
        )
    }

    func testListThreadsPublishesInitialBatchBeforeNextCursorPageReturns() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var requestedLimits: [Int] = []
        var requestedCursors: [JSONValue] = []
        var secondPageRequestStarted = false
        var allowSecondPageResponse: CheckedContinuation<Void, Never>?

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            let requestLimit = params?.objectValue?["limit"]?.intValue
            if let requestLimit {
                requestedLimits.append(requestLimit)
            }
            if let cursor = params?.objectValue?["cursor"] {
                requestedCursors.append(cursor)
            }

            if requestLimit == 10, params?.objectValue?["cursor"] == .null {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "threads": .array([
                            .object([
                                "id": .string("thread-initial"),
                                "title": .string("Initial thread"),
                                "updatedAt": .string("2026-07-03T12:00:00Z"),
                            ]),
                        ]),
                        "nextCursor": .string("cursor-page-2"),
                    ]),
                    includeJSONRPC: false
                )
            }

            if requestLimit == 10, params?.objectValue?["cursor"] == .string("cursor-page-2") {
                secondPageRequestStarted = true
                await withCheckedContinuation { continuation in
                    allowSecondPageResponse = continuation
                }

                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "threads": .array([
                            .object([
                                "id": .string("thread-expanded"),
                                "title": .string("Expanded thread"),
                                "updatedAt": .string("2026-07-03T13:00:00Z"),
                            ]),
                            .object([
                                "id": .string("thread-initial"),
                                "title": .string("Initial thread"),
                                "updatedAt": .string("2026-07-03T12:00:00Z"),
                            ]),
                        ]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            }

            XCTFail("Unexpected thread/list limit \(requestLimit.map { String($0) } ?? "nil")")
            return RPCMessage(id: .string(UUID().uuidString), result: .object(["threads": .array([])]), includeJSONRPC: false)
        }

        let refreshTask = Task { @MainActor in
            try await service.listThreads()
        }

        await waitUntil { secondPageRequestStarted }
        XCTAssertEqual(service.threads.map(\.id), ["thread-initial"])
        XCTAssertTrue(service.isLoadingThreads)

        guard let allowSecondPageResponse else {
            XCTFail("Expected second thread/list page request to be waiting")
            refreshTask.cancel()
            return
        }

        allowSecondPageResponse.resume()
        try await refreshTask.value

        XCTAssertEqual(requestedLimits, [10, 10])
        XCTAssertEqual(requestedCursors, [.null, .string("cursor-page-2")])
        XCTAssertEqual(service.threads.map(\.id), ["thread-expanded", "thread-initial"])
        XCTAssertFalse(service.isLoadingThreads)
    }

    func testListThreadsRetriesLegacySourceKindsWhenRuntimeRejectsSubagentSources() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var capturedSourceKinds: [[String]] = []

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }

            let sourceKinds = params?.objectValue?["sourceKinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            capturedSourceKinds.append(sourceKinds)

            if capturedSourceKinds.count == 1 {
                throw CodexServiceError.rpcError(RPCError(
                    code: -32600,
                    message: "Invalid request: unknown variant `subAgent` for sourceKinds"
                ))
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("thread-active"),
                            "title": .string("Active thread"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        try await service.listThreads(limit: service.recentActiveThreadListLimit)

        XCTAssertEqual(capturedSourceKinds.count, 2)
        XCTAssertTrue(capturedSourceKinds[0].contains("subAgent"))
        XCTAssertEqual(capturedSourceKinds[1], ["cli", "vscode", "appServer", "exec", "unknown"])
        XCTAssertEqual(service.threads.map(\.id), ["thread-active"])
    }

    func testListThreadsPublishesActiveThreadsFromSingleFetch() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            XCTAssertNil(params?.objectValue?["archived"])

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("thread-active"),
                            "title": .string("Active thread"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        try await service.listThreads(limit: service.recentActiveThreadListLimit)
        XCTAssertEqual(service.threads.map(\.id), ["thread-active"])
        XCTAssertFalse(service.isLoadingThreads)
    }

    func testSuccessfulThreadListRestoresCachedSidebarBeforeColdServerReply() async throws {
        let suiteName = "CodexServiceThreadListTests.cache.\(UUID().uuidString)"
        let cacheMacDeviceID = "test-mac-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        prepareThreadListCacheScope(service, macDeviceID: cacheMacDeviceID)
        defer { service.threadListPersistence.delete(macDeviceId: cacheMacDeviceID) }
        service.isConnected = true
        service.isInitialized = true
        service.requestTransportOverride = { method, _ in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("cached-thread"),
                            "title": .string("Cached sidebar title"),
                            "cwd": .string("/tmp/remodex"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }
        try await service.listThreads()
        await waitUntil {
            service.threadListPersistence
                .load(macDeviceId: cacheMacDeviceID)
                .contains(where: { $0.id == "cached-thread" })
        }

        let reloadedService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(reloadedService, macDeviceID: cacheMacDeviceID)
        Self.retainedServices.append(service)
        Self.retainedServices.append(reloadedService)

        XCTAssertEqual(reloadedService.threads.map(\.id), ["cached-thread"])
        XCTAssertEqual(reloadedService.thread(for: "cached-thread")?.displayTitle, "Cached sidebar title")
    }

    func testThreadListSnapshotRoundTripsUnixDatesWithoutChangingSortOrder() throws {
        let cacheMacDeviceID = "test-mac-\(UUID().uuidString)"
        let persistence = CodexThreadListPersistence()
        defer { persistence.delete(macDeviceId: cacheMacDeviceID) }
        let createdAt = Date(timeIntervalSince1970: 1_752_000_000.125)
        let updatedAt = Date(timeIntervalSince1970: 1_752_086_400.875)

        persistence.save(
            [
                CodexThread(
                    id: "dated-thread",
                    title: "Dated thread",
                    createdAt: createdAt,
                    updatedAt: updatedAt
                ),
            ],
            macDeviceId: cacheMacDeviceID
        )

        let restoredThread = try XCTUnwrap(
            persistence.load(macDeviceId: cacheMacDeviceID).first
        )
        XCTAssertEqual(
            try XCTUnwrap(restoredThread.createdAt).timeIntervalSince1970,
            createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(restoredThread.updatedAt).timeIntervalSince1970,
            updatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testFreshThreadListReconcilesOverCachedSidebarMetadata() async throws {
        let suiteName = "CodexServiceThreadListTests.reconcile-cache.\(UUID().uuidString)"
        let cacheMacDeviceID = "test-mac-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let initialService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(initialService, macDeviceID: cacheMacDeviceID)
        defer { initialService.threadListPersistence.delete(macDeviceId: cacheMacDeviceID) }
        initialService.threads = [
            CodexThread(id: "cached-thread", title: "Old title"),
            CodexThread(id: "stale-cached-thread", title: "No longer returned"),
        ]
        initialService.persistCurrentMacThreadListSnapshot()

        let reloadedService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(reloadedService, macDeviceID: cacheMacDeviceID)
        XCTAssertEqual(reloadedService.thread(for: "cached-thread")?.displayTitle, "Old title")
        XCTAssertNotNil(reloadedService.thread(for: "stale-cached-thread"))
        reloadedService.isConnected = true
        reloadedService.isInitialized = true
        reloadedService.requestTransportOverride = { method, _ in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("cached-thread"),
                            "title": .string("Fresh server title"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        try await reloadedService.listThreads()
        reloadedService.persistCurrentMacThreadListSnapshot()
        Self.retainedServices.append(initialService)
        Self.retainedServices.append(reloadedService)

        XCTAssertEqual(reloadedService.thread(for: "cached-thread")?.displayTitle, "Fresh server title")
        XCTAssertNil(reloadedService.thread(for: "stale-cached-thread"))
    }

    func testRestoredThreadStateFollowsCurrentLocalArchiveDefaults() {
        let suiteName = "CodexServiceThreadListTests.archive-cache.\(UUID().uuidString)"
        let cacheMacDeviceID = "test-mac-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let initialService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(initialService, macDeviceID: cacheMacDeviceID)
        defer { initialService.threadListPersistence.delete(macDeviceId: cacheMacDeviceID) }
        initialService.threads = [
            CodexThread(
                id: "formerly-archived-thread",
                title: "Unarchived before relaunch",
                syncState: .archivedLocal
            ),
        ]
        initialService.persistCurrentMacThreadListSnapshot()

        let reloadedService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(reloadedService, macDeviceID: cacheMacDeviceID)
        Self.retainedServices.append(initialService)
        Self.retainedServices.append(reloadedService)

        XCTAssertEqual(reloadedService.thread(for: "formerly-archived-thread")?.syncState, .live)
    }

    func testActiveCachedOnlyThreadStaysUnconfirmedUntilItIsNoLongerOpen() {
        let suiteName = "CodexServiceThreadListTests.active-cache.\(UUID().uuidString)"
        let cacheMacDeviceID = "test-mac-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let initialService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(initialService, macDeviceID: cacheMacDeviceID)
        defer { initialService.threadListPersistence.delete(macDeviceId: cacheMacDeviceID) }
        initialService.threads = [CodexThread(id: "cached-active-thread", title: "Cached active")]
        initialService.persistCurrentMacThreadListSnapshot()

        let reloadedService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(reloadedService, macDeviceID: cacheMacDeviceID)
        reloadedService.activeThreadId = "cached-active-thread"
        reloadedService.reconcileLocalThreadsWithServer([])

        XCTAssertNotNil(reloadedService.thread(for: "cached-active-thread"))
        XCTAssertTrue(reloadedService.restoredThreadSnapshotIDs.contains("cached-active-thread"))

        reloadedService.activeThreadId = nil
        reloadedService.reconcileLocalThreadsWithServer([])
        reloadedService.persistCurrentMacThreadListSnapshot()
        Self.retainedServices.append(initialService)
        Self.retainedServices.append(reloadedService)

        XCTAssertNil(reloadedService.thread(for: "cached-active-thread"))
        XCTAssertFalse(reloadedService.restoredThreadSnapshotIDs.contains("cached-active-thread"))
    }

    func testRealtimeSyncRequestsInitialPageFirstWhenLocalThreadListIsEmpty() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var requestedLimits: [Int] = []

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            if let limit = params?.objectValue?["limit"]?.intValue {
                requestedLimits.append(limit)
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["threads": .array([])]),
                includeJSONRPC: false
            )
        }

        await service.syncThreadsList()

        XCTAssertEqual(requestedLimits, [10])
    }

    func testRealtimeSyncKeepsPopulatedThreadListRequestsCapped() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: "thread-existing", title: "Existing thread"),
        ]

        var activeRequestParams: RPCObject?
        var requestCount = 0

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            requestCount += 1
            activeRequestParams = params?.objectValue

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["threads": .array([])]),
                includeJSONRPC: false
            )
        }

        await service.syncThreadsList()

        XCTAssertEqual(activeRequestParams?["limit"]?.intValue, 10)
        XCTAssertNil(activeRequestParams?["archived"])
        XCTAssertEqual(activeRequestParams?["sortKey"]?.stringValue, "updated_at")
        XCTAssertEqual(requestCount, 1)
    }

    func testPostConnectSyncRequestsInitialThreadListPageFirst() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var requestedLimits: [Int] = []

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            if let limit = params?.objectValue?["limit"]?.intValue {
                requestedLimits.append(limit)
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["threads": .array([])]),
                includeJSONRPC: false
            )
        }

        await service.performPostConnectSyncPass()
        await waitUntil { requestedLimits.count >= 2 }

        XCTAssertEqual(requestedLimits, [10, 10])
    }

    func testPostConnectStartsExpandedThreadListBeforeActiveCatchupFinishes() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var requestedLimits: [Int] = []
        var catchupStarted = false
        var allowCatchupResponse: CheckedContinuation<Void, Never>?

        service.requestTransportOverride = { method, params in
            if method == "thread/list" {
                if let limit = params?.objectValue?["limit"]?.intValue {
                    requestedLimits.append(limit)
                }

                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "threads": .array([
                            .object([
                                "id": .string("thread-active"),
                                "title": .string("Active thread"),
                            ]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            }

            if method == "thread/turns/list" {
                catchupStarted = true
                await withCheckedContinuation { continuation in
                    allowCatchupResponse = continuation
                }

                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turns": .array([])]),
                    includeJSONRPC: false
                )
            }

            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        let postConnectTask = Task { @MainActor in
            await service.performPostConnectSyncPass()
        }

        await waitUntil { catchupStarted && requestedLimits == [10, 10] }
        XCTAssertTrue(catchupStarted)
        XCTAssertEqual(requestedLimits, [10, 10])

        allowCatchupResponse?.resume()
        await postConnectTask.value
    }

    func testRealtimeSyncDoesNotRequestThreadListDuringConnectionBootstrap() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.isBootstrappingConnectionSync = true

        var threadListRequestCount = 0

        service.requestTransportOverride = { method, _ in
            if method == "thread/list" {
                threadListRequestCount += 1
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["threads": .array([])]),
                includeJSONRPC: false
            )
        }

        service.startSyncLoop()
        try await Task.sleep(nanoseconds: 20_000_000)
        service.stopSyncLoop()

        XCTAssertEqual(threadListRequestCount, 0)
    }

    func testConcurrentListThreadsShareInFlightRequest() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var requestCount = 0
        var requestedLimits: [Int] = []

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            requestCount += 1
            if let limit = params?.objectValue?["limit"]?.intValue {
                requestedLimits.append(limit)
            }
            try await Task.sleep(nanoseconds: 50_000_000)

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("thread-active"),
                            "title": .string("Active thread"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let firstRefresh = Task { @MainActor in try await service.listThreads() }
        let secondRefresh = Task { @MainActor in try await service.listThreads() }

        try await firstRefresh.value
        try await secondRefresh.value

        XCTAssertEqual(requestedLimits, [10])
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(service.threads.map(\.id), ["thread-active"])
        XCTAssertFalse(service.isLoadingThreads)
    }

    func testRealtimeSyncSharesInFlightListThreadsRequest() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: "thread-existing", title: "Existing thread"),
        ]

        var requestCount = 0

        service.requestTransportOverride = { method, _ in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            requestCount += 1
            try await Task.sleep(nanoseconds: 50_000_000)

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("thread-active"),
                            "title": .string("Active thread"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let sidebarRefresh = Task { @MainActor in
            try await service.listThreads(limit: service.recentActiveThreadListLimit)
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        await service.syncThreadsList()
        try await sidebarRefresh.value

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(service.threads.map(\.id), ["thread-active"])
    }

    func testListThreadsFlushesPendingRuntimeOptionRefreshAfterHydration() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.pendingRuntimeOptionRefresh = true

        var threadListRequestCount = 0
        var modelListRequestCount = 0
        var didReturnThreadListResponse = false
        var didLoadModelsBeforeThreadListReturned = false

        service.requestTransportOverride = { method, _ in
            switch method {
            case "thread/list":
                threadListRequestCount += 1
                try await Task.sleep(nanoseconds: 20_000_000)
                didReturnThreadListResponse = true
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["threads": .array([])]),
                    includeJSONRPC: false
                )
            case "model/list":
                modelListRequestCount += 1
                didLoadModelsBeforeThreadListReturned = !didReturnThreadListResponse
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["items": .array([])]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        try await service.listThreads()
        await waitUntil { modelListRequestCount > 0 }

        XCTAssertEqual(threadListRequestCount, 1)
        XCTAssertEqual(modelListRequestCount, 1)
        XCTAssertFalse(didLoadModelsBeforeThreadListReturned)
        XCTAssertFalse(service.pendingRuntimeOptionRefresh)
        XCTAssertNil(service.runtimeOptionRefreshTask)
        XCTAssertNil(service.runtimeOptionRefreshToken)
        XCTAssertEqual(
            TurnComposerMetaMapper.orderedModels(from: service.availableModels).prefix(3).map(\.id),
            ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        )
        XCTAssertEqual(service.selectedModelId, "gpt-5.6-sol")
    }

    func testSortThreadsUsesUpdatedAtBeforeCreatedAtFallback() {
        let service = makeService()
        let laterByUpdatedAt = CodexThread(
            id: "later-by-updated-at",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let laterByCreatedAt = CodexThread(
            id: "later-by-created-at",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: nil
        )
        let oldestThread = CodexThread(
            id: "oldest-thread",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: nil
        )

        let sorted = service.sortThreads([oldestThread, laterByCreatedAt, laterByUpdatedAt])

        XCTAssertEqual(
            sorted.map(\.id),
            ["later-by-updated-at", "later-by-created-at", "oldest-thread"]
        )
    }

    func testUserRenameSurvivesStaleThreadListRefreshForPinnedThread() {
        let service = makeService()
        service.threads = [
            CodexThread(
                id: "pinned-thread",
                title: "Original server title",
                name: "Original server title",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20),
                cwd: "/Users/dev/project"
            ),
        ]
        service.pinThread("pinned-thread")

        service.renameThread("pinned-thread", name: "Renamed locally")
        service.reconcileLocalThreadsWithServer([
            CodexThread(
                id: "pinned-thread",
                title: "Original server title",
                name: "Original server title",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 30),
                cwd: "/Users/dev/project"
            ),
        ])

        XCTAssertEqual(service.thread(for: "pinned-thread")?.displayTitle, "Renamed locally")
        XCTAssertEqual(service.pinnedThreadSnapshotsByRootID["pinned-thread"]?.first?.displayTitle, "Renamed locally")
    }

    func testMetadataOnlyThreadListReconcileDoesNotRefreshExistingTimelineState() {
        let service = makeService()
        let threadID = "thread-stable"
        let oldUpdatedAt = Date(timeIntervalSince1970: 10)
        let newUpdatedAt = Date(timeIntervalSince1970: 20)
        let timelineState = ThreadTimelineState(threadID: threadID)
        timelineState.messageRevision = 999

        service.threads = [
            CodexThread(
                id: threadID,
                title: "Stable thread",
                updatedAt: oldUpdatedAt,
                cwd: "/tmp/repo"
            ),
        ]
        service.messageRevisionByThread[threadID] = 7
        service.threadTimelineStateByThread[threadID] = timelineState

        service.reconcileLocalThreadsWithServer([
            CodexThread(
                id: threadID,
                title: "Stable thread",
                updatedAt: newUpdatedAt,
                cwd: "/tmp/repo"
            ),
        ])

        XCTAssertEqual(service.thread(for: threadID)?.updatedAt, newUpdatedAt)
        XCTAssertEqual(timelineState.messageRevision, 999)
    }

    func testThreadListReconcileRefreshesTimelineStateWhenWorkingDirectoryChanges() {
        let service = makeService()
        let threadID = "thread-cwd-changed"
        let timelineState = ThreadTimelineState(threadID: threadID)
        timelineState.messageRevision = 999

        service.threads = [
            CodexThread(
                id: threadID,
                title: "Cwd thread",
                cwd: "/tmp/old-repo"
            ),
        ]
        service.messageRevisionByThread[threadID] = 7
        service.threadTimelineStateByThread[threadID] = timelineState

        service.reconcileLocalThreadsWithServer([
            CodexThread(
                id: threadID,
                title: "Cwd thread",
                cwd: "/tmp/new-repo"
            ),
        ])

        XCTAssertEqual(service.thread(for: threadID)?.gitWorkingDirectory, "/tmp/new-repo")
        XCTAssertEqual(timelineState.messageRevision, 7)
    }

    func testThreadListReconcileRevivesNonPersistedMissingThreadArchive() {
        let service = makeService()
        service.threads = [
            CodexThread(
                id: "thread-temporary-missing",
                title: "Still Live",
                cwd: "/tmp/repo"
            ),
        ]

        service.handleMissingThread("thread-temporary-missing")
        XCTAssertEqual(service.thread(for: "thread-temporary-missing")?.syncState, .archivedLocal)

        service.reconcileLocalThreadsWithServer([
            CodexThread(
                id: "thread-temporary-missing",
                title: "Still Live",
                cwd: "/tmp/repo"
            ),
        ])

        XCTAssertEqual(service.thread(for: "thread-temporary-missing")?.syncState, .live)
    }

    func testThreadListReconcileKeepsPersistedUserArchiveArchived() {
        let service = makeService()
        service.threads = [
            CodexThread(
                id: "thread-user-archived",
                title: "Archived",
                cwd: "/tmp/repo"
            ),
        ]

        service.archiveThread("thread-user-archived")
        service.reconcileLocalThreadsWithServer([
            CodexThread(
                id: "thread-user-archived",
                title: "Archived",
                cwd: "/tmp/repo"
            ),
        ])

        XCTAssertEqual(service.thread(for: "thread-user-archived")?.syncState, .archivedLocal)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceThreadListTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func prepareThreadListCacheScope(_ service: CodexService, macDeviceID: String) {
        service.macScopedContextOverrideDeviceId = macDeviceID
        service.clearInMemoryMacScopedState()
        service.loadMacScopedDefaultsState(for: macDeviceID)
        service.loadThreadListSnapshot(for: macDeviceID)
    }

    private func waitUntil(_ condition: () -> Bool, maxPollCount: Int = 50) async {
        for _ in 0..<maxPollCount {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
