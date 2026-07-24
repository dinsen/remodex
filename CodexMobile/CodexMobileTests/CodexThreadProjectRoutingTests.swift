// FILE: CodexThreadProjectRoutingTests.swift
// Purpose: Verifies same-thread project rebind behavior for managed worktree handoff flows.
// Layer: Unit Test
// Exports: CodexThreadProjectRoutingTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadProjectRoutingTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testStartThreadIfReadyWaitsForRuntimeInitializationDuringReconnect() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = false

        var didStartThread = false
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/start")
            XCTAssertTrue(service.isInitialized)
            didStartThread = true
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("thread-new"),
                        "cwd": .string("/tmp/remodex-local"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let readinessTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            service.isInitialized = true
        }
        defer { readinessTask.cancel() }

        let thread = try await service.startThreadIfReady(preferredProjectPath: "/tmp/remodex-local")

        XCTAssertTrue(didStartThread)
        XCTAssertEqual(thread.id, "thread-new")
        XCTAssertEqual(service.activeThreadId, "thread-new")
    }

    func testRootlessStartUsesDocumentsCodexPathWhenRuntimeReturnsHomeCwd() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        let rootlessPath = "/Users/me/Documents/Codex/2026-05-25/i-just-created-this"
        var requestedMethods: [String] = []

        service.requestTransportOverride = { method, params in
            requestedMethods.append(method)
            switch method {
            case "project/createRootlessChatRoot":
                XCTAssertEqual(params?.objectValue?["promptHint"]?.stringValue, "i just created this")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["path": .string(rootlessPath)]),
                    includeJSONRPC: false
                )
            case "thread/start":
                XCTAssertEqual(params?.objectValue?["cwd"]?.stringValue, rootlessPath)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("thread-rootless"),
                            "cwd": .string("/Users/me"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.invalidResponse("Unexpected method \(method)")
            }
        }

        let thread = try await service.startThreadIfReady(rootlessChatPromptHint: "i just created this")

        XCTAssertEqual(requestedMethods, ["project/createRootlessChatRoot", "thread/start"])
        XCTAssertEqual(thread.cwd, rootlessPath)
        XCTAssertEqual(service.thread(for: "thread-rootless")?.cwd, rootlessPath)
        XCTAssertEqual(service.currentAuthoritativeProjectPath(for: "thread-rootless"), rootlessPath)
    }

    func testRootlessStartFailsInsteadOfStartingWithoutCwdWhenRootlessFolderCannotBeCreated() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        var requestedMethods: [String] = []

        service.requestTransportOverride = { method, _ in
            requestedMethods.append(method)
            switch method {
            case "project/createRootlessChatRoot":
                throw CodexServiceError.rpcError(
                    RPCError(code: -32000, message: "project/createRootlessChatRoot unavailable")
                )
            case "thread/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("thread-home"),
                            "cwd": .string("/Users/me"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        do {
            _ = try await service.startThreadIfReady(rootlessChatPromptHint: "quick chat")
            XCTFail("Expected rootless start to fail before thread/start without cwd")
        } catch {
            XCTAssertEqual(requestedMethods, ["project/createRootlessChatRoot"])
            XCTAssertTrue(service.threads.isEmpty)
        }
    }

    func testStartThreadRejectsMissingProjectPathBeforeThreadStart() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        var requestedMethods: [String] = []

        service.requestTransportOverride = { method, _ in
            requestedMethods.append(method)
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        do {
            _ = try await service.startThread()
            XCTFail("Expected startThread without a project path to fail before thread/start")
        } catch let error as CodexServiceError {
            guard case .invalidInput = error else {
                XCTFail("Expected invalidInput, got \(error)")
                return
            }
            XCTAssertTrue(requestedMethods.isEmpty)
            XCTAssertTrue(service.threads.isEmpty)
        }
    }

    func testStartTurnWithoutThreadCreatesRootlessThreadInsteadOfHomeThread() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        let rootlessPath = "/Users/me/Documents/Codex/2026-05-25/follow-up"
        var requestedMethods: [String] = []
        var threadStartParams: RPCObject?
        var turnStartParams: RPCObject?

        service.requestTransportOverride = { method, params in
            requestedMethods.append(method)
            switch method {
            case "project/createRootlessChatRoot":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["path": .string(rootlessPath)]),
                    includeJSONRPC: false
                )
            case "thread/start":
                threadStartParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("thread-rootless"),
                            "cwd": .string("/Users/me"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "turn/start":
                turnStartParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-rootless")]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        try await service.startTurn(
            userInput: "follow up",
            threadId: nil,
            shouldAppendUserMessage: false
        )

        XCTAssertEqual(requestedMethods, ["project/createRootlessChatRoot", "thread/start", "turn/start"])
        XCTAssertEqual(threadStartParams?["cwd"]?.stringValue, rootlessPath)
        XCTAssertEqual(turnStartParams?["threadId"]?.stringValue, "thread-rootless")
        XCTAssertEqual(service.thread(for: "thread-rootless")?.gitWorkingDirectory, rootlessPath)
    }

    func testMoveThreadToProjectPathKeepsRebindWhenResumeFailsOnlyBecauseRolloutIsMissing() async throws {
        let service = makeService()
        let originalThread = CodexThread(
            id: "thread-1",
            title: "Source",
            cwd: "/tmp/remodex-local"
        )
        service.upsertThread(originalThread)
        service.activeThreadId = "thread-1"
        service.resumedThreadIDs = ["thread-1"]

        var resumeRequests: [[String: JSONValue]] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/resume")
            resumeRequests.append(params?.objectValue ?? [:])
            throw CodexServiceError.rpcError(
                RPCError(code: -32600, message: "no rollout found for thread id thread-1")
            )
        }

        let movedThread = try await service.moveThreadToProjectPath(
            threadId: "thread-1",
            projectPath: "/tmp/remodex-worktree"
        )

        XCTAssertEqual(resumeRequests.count, 1)
        XCTAssertEqual(resumeRequests.first?["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(resumeRequests.first?["cwd"]?.stringValue, "/tmp/remodex-worktree")
        XCTAssertEqual(movedThread.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.thread(for: "thread-1")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.currentAuthoritativeProjectPath(for: "thread-1"), "/tmp/remodex-worktree")
        XCTAssertEqual(service.activeThreadId, "thread-1")
        XCTAssertFalse(service.resumedThreadIDs.contains("thread-1"))
    }

    func testRolloutMissingFallbackStillRejectsImmediateStaleServerProjectPath() async throws {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-local"
            )
        )
        service.activeThreadId = "thread-1"

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/resume")
            throw CodexServiceError.rpcError(
                RPCError(code: -32600, message: "no rollout found for thread id thread-1")
            )
        }

        _ = try await service.moveThreadToProjectPath(
            threadId: "thread-1",
            projectPath: "/tmp/remodex-worktree"
        )

        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-local"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(service.thread(for: "thread-1")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.currentAuthoritativeProjectPath(for: "thread-1"), "/tmp/remodex-worktree")

        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-worktree"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(service.thread(for: "thread-1")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertNil(service.currentAuthoritativeProjectPath(for: "thread-1"))
    }

    func testServerStateCannotOverwriteAuthoritativeRebindUntilMatchingPathArrives() {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-local"
            )
        )

        service.beginAuthoritativeProjectPathTransition(
            threadId: "thread-1",
            projectPath: "/tmp/remodex-worktree"
        )

        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-local"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(service.thread(for: "thread-1")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.currentAuthoritativeProjectPath(for: "thread-1"), "/tmp/remodex-worktree")

        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-worktree"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(service.thread(for: "thread-1")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertNil(service.currentAuthoritativeProjectPath(for: "thread-1"))
    }

    func testManagedWorktreeAssociationPersistsAcrossLocalHandoffs() async throws {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-local"
            )
        )

        var resumeResponses: [String] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/resume")
            let cwd = params?.objectValue?["cwd"]?.stringValue ?? ""
            resumeResponses.append(cwd)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("thread-1"),
                        "cwd": .string(cwd),
                        "title": .string("Source"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let worktreePath = "/Users/me/.codex/worktrees/a1b2/remodex"
        _ = try await service.moveThreadToProjectPath(threadId: "thread-1", projectPath: worktreePath)
        _ = try await service.moveThreadToProjectPath(threadId: "thread-1", projectPath: "/tmp/remodex-local")

        XCTAssertEqual(resumeResponses, [worktreePath, "/tmp/remodex-local"])
        XCTAssertEqual(service.associatedManagedWorktreePath(for: "thread-1"), worktreePath)
    }

    func testManagedWorktreeAssociationIsScopedPerMac() {
        let suiteName = "CodexThreadProjectRoutingTests.macScope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = makeService(defaults: defaults)
        let macA = "mac-a-\(UUID().uuidString)"
        let macB = "mac-b-\(UUID().uuidString)"

        service.setCurrentTrustedMacDeviceId(macA)
        service.rememberAssociatedManagedWorktreePath("/tmp/worktree-a", for: "thread-a")
        service.planSessionSourceByThread["thread-a"] = .requested

        service.setCurrentTrustedMacDeviceId(macB)
        service.loadMacScopedDefaultsState(for: macB)
        service.rememberAssociatedManagedWorktreePath("/tmp/worktree-b", for: "thread-b")
        service.planSessionSourceByThread["thread-b"] = .compatibilityFallback

        service.setCurrentTrustedMacDeviceId(macA)
        service.loadMacScopedDefaultsState(for: macA)
        XCTAssertEqual(service.associatedManagedWorktreePath(for: "thread-a"), "/tmp/worktree-a")
        XCTAssertNil(service.associatedManagedWorktreePath(for: "thread-b"))
        XCTAssertEqual(service.planSessionSourceByThread["thread-a"], .requested)
        XCTAssertNil(service.planSessionSourceByThread["thread-b"])

        service.setCurrentTrustedMacDeviceId(macB)
        service.loadMacScopedDefaultsState(for: macB)
        XCTAssertEqual(service.associatedManagedWorktreePath(for: "thread-b"), "/tmp/worktree-b")
        XCTAssertNil(service.associatedManagedWorktreePath(for: "thread-a"))
        XCTAssertEqual(service.planSessionSourceByThread["thread-b"], .compatibilityFallback)
        XCTAssertNil(service.planSessionSourceByThread["thread-a"])
    }

    func testClearInMemoryMacScopedStateClearsAuthoritativeProjectPathTransitions() {
        let service = makeService()

        service.beginAuthoritativeProjectPathTransition(
            threadId: "thread-1",
            projectPath: "/tmp/remodex-worktree"
        )

        service.clearInMemoryMacScopedState()

        XCTAssertNil(service.currentAuthoritativeProjectPath(for: "thread-1"))
    }

    func testThreadResumePreservesRequestedProjectPathWhenRuntimeReturnsHomeCwd() async throws {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "project-thread",
                title: "Project Chat",
                cwd: "/Users/me/projects/app"
            )
        )

        var resumeParams: RPCObject?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/resume")
            resumeParams = params?.objectValue
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("project-thread"),
                        "title": .string("Project Chat"),
                        "cwd": .string("/Users/me"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let resumedThread = try await service.ensureThreadResumed(
            threadId: "project-thread",
            force: true
        )

        XCTAssertEqual(resumeParams?["cwd"]?.stringValue, "/Users/me/projects/app")
        XCTAssertEqual(resumedThread?.gitWorkingDirectory, "/Users/me/projects/app")
        XCTAssertEqual(service.thread(for: "project-thread")?.gitWorkingDirectory, "/Users/me/projects/app")
    }

    func testProjectlessThreadResumeDoesNotInjectCwd() async throws {
        let service = makeService()
        service.upsertThread(CodexThread(id: "quick-chat", title: "Quick Chat", cwd: nil))

        var resumeParams: RPCObject?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/resume")
            resumeParams = params?.objectValue
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("quick-chat"),
                        "title": .string("Quick Chat"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let resumedThread = try await service.ensureThreadResumed(
            threadId: "quick-chat",
            force: true
        )

        XCTAssertNil(resumeParams?["cwd"])
        XCTAssertNil(resumedThread?.gitWorkingDirectory)
        XCTAssertNil(service.thread(for: "quick-chat")?.gitWorkingDirectory)
    }

    func testProjectlessThreadTurnStartDoesNotInjectCwd() async throws {
        let service = makeService()
        service.upsertThread(CodexThread(id: "quick-chat", title: "Quick Chat", cwd: nil))

        var recordedMethods: [String] = []
        var resumeParams: RPCObject?
        var turnStartParams: RPCObject?
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/resume":
                resumeParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("quick-chat"),
                            "title": .string("Quick Chat"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "turn/start":
                turnStartParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-quick-chat")]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        try await service.startTurn(
            userInput: "follow up",
            threadId: "quick-chat",
            shouldAppendUserMessage: false
        )

        XCTAssertEqual(recordedMethods, ["thread/resume", "turn/start"])
        XCTAssertNil(resumeParams?["cwd"])
        XCTAssertNil(turnStartParams?["cwd"])
        XCTAssertEqual(turnStartParams?["threadId"]?.stringValue, "quick-chat")
        XCTAssertNil(service.thread(for: "quick-chat")?.gitWorkingDirectory)
    }

    func testProjectThreadTurnStartIncludesCurrentProjectCwdWhenAlreadyResumed() async throws {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "project-thread",
                title: "Project Chat",
                cwd: "/Users/me/projects/app"
            )
        )
        service.resumedThreadIDs.insert("project-thread")

        var recordedMethods: [String] = []
        var turnStartParams: RPCObject?
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "turn/start":
                turnStartParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-project")]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        try await service.startTurn(
            userInput: "follow up",
            threadId: "project-thread",
            shouldAppendUserMessage: false
        )

        XCTAssertEqual(recordedMethods, ["turn/start"])
        XCTAssertEqual(turnStartParams?["threadId"]?.stringValue, "project-thread")
        XCTAssertEqual(turnStartParams?["cwd"]?.stringValue, "/Users/me/projects/app")
        XCTAssertEqual(service.activeThreadId, "project-thread")
    }

    func testProjectThreadTurnStartRetriesWithoutCwdWhenRuntimeRejectsCwdField() async throws {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "project-thread",
                title: "Project Chat",
                cwd: "/Users/me/projects/app"
            )
        )
        service.resumedThreadIDs.insert("project-thread")

        var turnStartParams: [RPCObject] = []
        service.requestTransportOverride = { method, params in
            switch method {
            case "turn/start":
                let paramsObject = params?.objectValue ?? [:]
                turnStartParams.append(paramsObject)
                if turnStartParams.count == 1 {
                    throw CodexServiceError.rpcError(
                        RPCError(code: -32602, message: "unknown field cwd")
                    )
                }
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-project")]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        try await service.startTurn(
            userInput: "follow up",
            threadId: "project-thread",
            shouldAppendUserMessage: false
        )

        XCTAssertEqual(turnStartParams.count, 2)
        XCTAssertEqual(turnStartParams[0]["cwd"]?.stringValue, "/Users/me/projects/app")
        XCTAssertNil(turnStartParams[1]["cwd"])
        XCTAssertEqual(service.activeThreadId, "project-thread")
    }

    func testContinuationThreadInheritsMissingThreadProjectPath() async throws {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "archived-thread",
                title: "Source",
                cwd: "/Users/me/projects/app"
            )
        )

        var recordedMethods: [String] = []
        var startParams: RPCObject?
        var turnStartParams: RPCObject?
        var turnStartThreadIDs: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/resume":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, "archived-thread")
                throw CodexServiceError.rpcError(
                    RPCError(code: -32600, message: "thread not found: archived-thread")
                )
            case "thread/start":
                startParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("continuation-thread"),
                            "title": .string("Continuation"),
                            "cwd": .string("/Users/me"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "turn/start":
                let threadID = params?.objectValue?["threadId"]?.stringValue
                turnStartThreadIDs.append(threadID ?? "")
                if threadID == "archived-thread" {
                    throw CodexServiceError.rpcError(
                        RPCError(code: -32600, message: "thread not found: archived-thread")
                    )
                }
                turnStartParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-continuation")]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        try await service.startTurn(
            userInput: "continue here",
            threadId: "archived-thread",
            shouldAppendUserMessage: false
        )

        XCTAssertEqual(recordedMethods, ["thread/resume", "turn/start", "thread/start", "turn/start"])
        XCTAssertEqual(startParams?["cwd"]?.stringValue, "/Users/me/projects/app")
        XCTAssertEqual(turnStartThreadIDs, ["archived-thread", "continuation-thread"])
        XCTAssertEqual(turnStartParams?["threadId"]?.stringValue, "continuation-thread")
        XCTAssertEqual(service.thread(for: "archived-thread")?.syncState, .archivedLocal)
        XCTAssertEqual(service.thread(for: "continuation-thread")?.gitWorkingDirectory, "/Users/me/projects/app")
        XCTAssertEqual(service.activeThreadId, "continuation-thread")
    }

    func testFailedContinuationRecoveryKeepsOriginalProjectThreadVisible() async throws {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "project-thread",
                title: "Source",
                cwd: "/Users/me/projects/app"
            )
        )

        var recordedMethods: [String] = []
        var continuationStartParams: RPCObject?
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/resume":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, "project-thread")
                throw CodexServiceError.rpcError(
                    RPCError(code: -32600, message: "thread not found: project-thread")
                )
            case "turn/start":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, "project-thread")
                XCTAssertEqual(params?.objectValue?["cwd"]?.stringValue, "/Users/me/projects/app")
                throw CodexServiceError.rpcError(
                    RPCError(code: -32600, message: "thread not found: project-thread")
                )
            case "thread/start":
                continuationStartParams = params?.objectValue
                throw CodexServiceError.rpcError(
                    RPCError(code: -32000, message: "connection dropped while creating continuation")
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        do {
            try await service.startTurn(
                userInput: "continue here",
                threadId: "project-thread"
            )
            XCTFail("Expected continuation recovery to fail")
        } catch {
            XCTAssertEqual(recordedMethods, ["thread/resume", "turn/start", "thread/start"])
            XCTAssertEqual(continuationStartParams?["cwd"]?.stringValue, "/Users/me/projects/app")
            XCTAssertEqual(service.thread(for: "project-thread")?.syncState, .live)
            XCTAssertEqual(service.thread(for: "project-thread")?.gitWorkingDirectory, "/Users/me/projects/app")
            XCTAssertEqual(service.activeThreadId, "project-thread")
            XCTAssertEqual(service.messages(for: "project-thread").last?.deliveryState, .failed)
        }
    }

    func testContinuationThreadUsesCapturedProjectPathWhenSourceRowLosesCwdDuringRecovery() async throws {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "project-thread",
                title: "Source",
                cwd: "/Users/me/projects/app"
            )
        )

        var recordedMethods: [String] = []
        var continuationStartParams: RPCObject?
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/resume":
                throw CodexServiceError.rpcError(
                    RPCError(code: -32600, message: "thread not found: project-thread")
                )
            case "turn/start":
                let threadID = params?.objectValue?["threadId"]?.stringValue
                if threadID == "project-thread" {
                    XCTAssertEqual(params?.objectValue?["cwd"]?.stringValue, "/Users/me/projects/app")
                    service.threads = [
                        CodexThread(
                            id: "project-thread",
                            title: "Source"
                        ),
                    ]
                    throw CodexServiceError.rpcError(
                        RPCError(code: -32600, message: "thread not found: project-thread")
                    )
                }
                XCTAssertEqual(threadID, "continuation-thread")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-continuation")]),
                    includeJSONRPC: false
                )
            case "thread/start":
                continuationStartParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("continuation-thread"),
                            "title": .string("Continuation"),
                            "cwd": .string("/Users/me"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        try await service.startTurn(
            userInput: "continue here",
            threadId: "project-thread",
            shouldAppendUserMessage: false
        )

        XCTAssertEqual(recordedMethods, ["thread/resume", "turn/start", "thread/start", "turn/start"])
        XCTAssertEqual(continuationStartParams?["cwd"]?.stringValue, "/Users/me/projects/app")
        XCTAssertEqual(service.thread(for: "continuation-thread")?.gitWorkingDirectory, "/Users/me/projects/app")
        XCTAssertEqual(service.activeThreadId, "continuation-thread")
    }

    private func makeService(defaults: UserDefaults? = nil) -> CodexService {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else {
            let suiteName = "CodexThreadProjectRoutingTests.\(UUID().uuidString)"
            let isolatedDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            isolatedDefaults.removePersistentDomain(forName: suiteName)
            resolvedDefaults = isolatedDefaults
        }

        let service = CodexService(defaults: resolvedDefaults)
        Self.retainedServices.append(service)
        return service
    }
}
