// FILE: RemodexDisplayIslandCoordinator.swift
// Purpose: Owns Remodex Live Activity state, coalescing, and expiration.
// Layer: Service

import ActivityKit
import Foundation

struct RemodexDisplayIslandSnapshot: Equatable {
    let runningConversations: [RemodexDisplayIslandConversation]
    let completedConversations: [RemodexDisplayIslandConversation]
    let failedConversations: [RemodexDisplayIslandConversation]
    let nextExpirationDate: Date?

    var isEmpty: Bool {
        runningConversations.isEmpty && completedConversations.isEmpty && failedConversations.isEmpty
    }
}

@MainActor
final class RemodexDisplayIslandCoordinator {
    private struct Outcome: Equatable {
        let threadId: String
        let title: String
        let createdAt: Date
    }

    private static let maxDisplayedConversations = 3
    private static let syncDelayNanoseconds: UInt64 = 350_000_000
    private static let completedLifetime: TimeInterval = 5 * 60
    private static let failedLifetime: TimeInterval = 15 * 60
    private static let defaultStaleInterval: TimeInterval = 30 * 60
    private static let runningStartRetentionInterval: TimeInterval = 2 * 60 * 60

    private var activityID: String?
    private var lastSnapshot: RemodexDisplayIslandSnapshot?
    private var scheduledSyncTask: Task<Void, Never>?
    private var expirationSyncTask: Task<Void, Never>?

    private var completedOutcomes: [Outcome] = []
    private var failedOutcomes: [Outcome] = []
    private var lastRunningThreadIDs: Set<String> = []
    private var lastTerminalStatesByThread: [String: CodexTurnTerminalState] = [:]
    private var runningStartedAtByThread: [String: Date] = [:]
    private var runningLastSeenAtByThread: [String: Date] = [:]

    func rememberCompletion(from banner: CodexThreadCompletionBanner?, codex: CodexService) {
        guard let banner else {
            return
        }

        rememberCompletion(threadId: banner.threadId, title: banner.title, codex: codex)
    }

    func clearOutcome(for threadId: String, terminalState: CodexTurnTerminalState?) {
        completedOutcomes.removeAll { $0.threadId == threadId }
        failedOutcomes.removeAll { $0.threadId == threadId }
        lastTerminalStatesByThread[threadId] = terminalState
    }

    func sync(codex: CodexService, immediately: Bool = false) {
        if immediately {
            scheduledSyncTask?.cancel()
            scheduledSyncTask = nil
            Task { @MainActor [weak self, weak codex] in
                guard let self, let codex else {
                    return
                }
                await self.performSync(codex: codex)
            }
            return
        }

        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { @MainActor [weak self, weak codex] in
            try? await Task.sleep(nanoseconds: Self.syncDelayNanoseconds)
            guard !Task.isCancelled, let self, let codex else {
                return
            }
            await self.performSync(codex: codex)
        }
    }

    func timelineFingerprint(codex: CodexService) -> String {
        currentRunningThreadIDs(codex: codex)
            .sorted()
            .map { threadId in
                let snapshot = codex.timelineState(for: threadId).renderSnapshot
                return "\(threadId):\(snapshot.timelineChangeToken):\(runningState(for: threadId, codex: codex))"
            }
            .joined(separator: "|")
    }

    private func performSync(codex: CodexService) async {
        let now = Date()
        let snapshot = makeReconciledSnapshot(codex: codex, now: now)
        scheduleNextExpirationSyncIfNeeded(codex: codex, snapshot: snapshot, now: now)
        await apply(snapshot: snapshot, now: now)
    }

    // Reconciles transient run/outcome caches before producing ActivityKit content.
    func makeReconciledSnapshot(codex: CodexService, now: Date) -> RemodexDisplayIslandSnapshot {
        reconcileCompletions(codex: codex, now: now)
        return makeSnapshot(codex: codex, now: now)
    }

    private func reconcileCompletions(codex: CodexService, now: Date) {
        hydrateRunningStartsFromCurrentActivity(now: now)

        let currentRunningIDs = currentRunningThreadIDs(codex: codex)
        let visibleThreadIDs = visibleThreadIDs(codex: codex)
        let activeThreadIDs = currentActiveThreadIDs(codex: codex)
        // The active chat is already visible in-app, so only off-screen outcomes should become Island badges.
        let outcomeEligibleThreadIDs = visibleThreadIDs
            .subtracting(currentRunningIDs)
            .subtracting(activeThreadIDs)
        let completedIDs = lastRunningThreadIDs
            .intersection(outcomeEligibleThreadIDs)
        let terminalStates = codex.latestTurnTerminalStateByThread

        for threadId in currentRunningIDs where runningStartedAtByThread[threadId] == nil {
            runningStartedAtByThread[threadId] = now
        }
        for threadId in currentRunningIDs {
            runningLastSeenAtByThread[threadId] = now
        }
        pruneRunningStarts(
            currentRunningIDs: currentRunningIDs,
            visibleThreadIDs: visibleThreadIDs,
            terminalStates: terminalStates,
            now: now
        )

        pruneOutcomes(
            codex: codex,
            currentRunningIDs: currentRunningIDs,
            activeThreadIDs: activeThreadIDs,
            visibleThreadIDs: visibleThreadIDs,
            now: now
        )

        for threadId in completedIDs {
            let terminalState = codex.latestTurnTerminalState(for: threadId)
            switch terminalState {
            case .completed:
                rememberCompletion(threadId: threadId, codex: codex, now: now)
            case .failed:
                rememberFailure(threadId: threadId, codex: codex, now: now)
            case .stopped, nil:
                continue
            }
        }

        let visibleTerminalStates = terminalStates.filter { threadId, _ in
            outcomeEligibleThreadIDs.contains(threadId)
        }
        for (threadId, terminalState) in visibleTerminalStates {
            guard lastTerminalStatesByThread[threadId] != terminalState else {
                continue
            }

            switch terminalState {
            case .completed:
                rememberCompletion(threadId: threadId, codex: codex, now: now)
            case .failed:
                rememberFailure(threadId: threadId, codex: codex, now: now)
            case .stopped:
                clearOutcome(for: threadId, terminalState: terminalState)
            }
        }

        lastRunningThreadIDs = currentRunningIDs.intersection(visibleThreadIDs)
        lastTerminalStatesByThread = terminalStates.filter { threadId, _ in
            visibleThreadIDs.contains(threadId) && !currentRunningIDs.contains(threadId)
        }
    }

    private func pruneOutcomes(
        codex: CodexService,
        currentRunningIDs: Set<String>,
        activeThreadIDs: Set<String>,
        visibleThreadIDs: Set<String>,
        now: Date
    ) {
        completedOutcomes.removeAll { outcome in
            !visibleThreadIDs.contains(outcome.threadId)
                || currentRunningIDs.contains(outcome.threadId)
                || activeThreadIDs.contains(outcome.threadId)
                || codex.latestTurnTerminalState(for: outcome.threadId) == .failed
                || codex.latestTurnTerminalState(for: outcome.threadId) == .stopped
                || now.timeIntervalSince(outcome.createdAt) >= Self.completedLifetime
        }
        failedOutcomes.removeAll { outcome in
            !visibleThreadIDs.contains(outcome.threadId)
                || currentRunningIDs.contains(outcome.threadId)
                || activeThreadIDs.contains(outcome.threadId)
                || codex.latestTurnTerminalState(for: outcome.threadId) == .completed
                || codex.latestTurnTerminalState(for: outcome.threadId) == .stopped
                || now.timeIntervalSince(outcome.createdAt) >= Self.failedLifetime
        }
    }

    private func pruneRunningStarts(
        currentRunningIDs: Set<String>,
        visibleThreadIDs: Set<String>,
        terminalStates: [String: CodexTurnTerminalState],
        now: Date
    ) {
        let retainedThreadIDs = Set(runningStartedAtByThread.keys.filter { threadId in
            guard visibleThreadIDs.contains(threadId) else {
                return false
            }
            if currentRunningIDs.contains(threadId) {
                return true
            }
            if terminalStates[threadId] != nil {
                return false
            }
            guard let lastSeenAt = runningLastSeenAtByThread[threadId] else {
                return false
            }
            return now.timeIntervalSince(lastSeenAt) < Self.runningStartRetentionInterval
        })

        runningStartedAtByThread = runningStartedAtByThread.filter { threadId, _ in
            retainedThreadIDs.contains(threadId)
        }
        runningLastSeenAtByThread = runningLastSeenAtByThread.filter { threadId, _ in
            retainedThreadIDs.contains(threadId)
        }
    }

    private func makeSnapshot(codex: CodexService, now: Date) -> RemodexDisplayIslandSnapshot {
        let runningConversations = currentRunningThreadIDs(codex: codex)
            .compactMap { threadId in
                conversation(
                    threadId: threadId,
                    state: runningState(for: threadId, codex: codex),
                    runningStartedAt: runningStartedAtByThread[threadId],
                    codex: codex
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let completedConversations = completedOutcomes.compactMap { outcome in
            conversation(threadId: outcome.threadId, fallbackTitle: outcome.title, state: "Ready", codex: codex)
        }
        let failedConversations = failedOutcomes.compactMap { outcome in
            conversation(threadId: outcome.threadId, fallbackTitle: outcome.title, state: "Failed", codex: codex)
        }

        return RemodexDisplayIslandSnapshot(
            runningConversations: Array(runningConversations.prefix(Self.maxDisplayedConversations)),
            completedConversations: Array(completedConversations.prefix(Self.maxDisplayedConversations)),
            failedConversations: Array(failedConversations.prefix(Self.maxDisplayedConversations)),
            nextExpirationDate: nextExpirationDate(now: now)
        )
    }

    private func rememberCompletion(
        threadId: String,
        title: String? = nil,
        codex: CodexService,
        now: Date = Date()
    ) {
        let resolvedTitle = title
            ?? codex.threads.first(where: { $0.id == threadId })?.displayTitle
            ?? CodexThread.defaultDisplayTitle
        let outcome = Outcome(threadId: threadId, title: resolvedTitle, createdAt: now)

        failedOutcomes.removeAll { $0.threadId == outcome.threadId }
        completedOutcomes.removeAll { $0.threadId == outcome.threadId }
        completedOutcomes.insert(outcome, at: 0)
        if completedOutcomes.count > Self.maxDisplayedConversations {
            completedOutcomes = Array(completedOutcomes.prefix(Self.maxDisplayedConversations))
        }
    }

    private func rememberFailure(
        threadId: String,
        title: String? = nil,
        codex: CodexService,
        now: Date = Date()
    ) {
        let resolvedTitle = title
            ?? codex.threads.first(where: { $0.id == threadId })?.displayTitle
            ?? CodexThread.defaultDisplayTitle
        let outcome = Outcome(threadId: threadId, title: resolvedTitle, createdAt: now)

        completedOutcomes.removeAll { $0.threadId == outcome.threadId }
        failedOutcomes.removeAll { $0.threadId == outcome.threadId }
        failedOutcomes.insert(outcome, at: 0)
        if failedOutcomes.count > Self.maxDisplayedConversations {
            failedOutcomes = Array(failedOutcomes.prefix(Self.maxDisplayedConversations))
        }
    }

    private func currentRunningThreadIDs(codex: CodexService) -> Set<String> {
        codex.runningThreadIDs
            .union(Set(codex.activeTurnIdByThread.keys))
            .intersection(visibleThreadIDs(codex: codex))
    }

    private func visibleThreadIDs(codex: CodexService) -> Set<String> {
        Set(codex.threads.map(\.id))
    }

    private func currentActiveThreadIDs(codex: CodexService) -> Set<String> {
        guard let activeThreadId = codex.activeThreadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !activeThreadId.isEmpty else {
            return []
        }

        return [activeThreadId]
    }

    private func runningState(for threadId: String, codex: CodexService) -> String {
        let messages = codex.timelineState(for: threadId).renderSnapshot.messages
        let isFinalAnswerStreaming = messages.contains { message in
            message.role == .assistant
                && message.kind == .chat
                && message.isStreaming
                && message.assistantPhase == "final_answer"
                && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return isFinalAnswerStreaming ? "Finishing" : "Running"
    }

    private func conversation(
        threadId: String,
        fallbackTitle: String? = nil,
        state: String,
        runningStartedAt: Date? = nil,
        codex: CodexService
    ) -> RemodexDisplayIslandConversation? {
        let thread = codex.threads.first { $0.id == threadId }
        let rawTitle = thread?.displayTitle ?? fallbackTitle ?? CodexThread.defaultDisplayTitle
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = detail(for: thread)

        return RemodexDisplayIslandConversation(
            id: threadId,
            title: title.isEmpty ? CodexThread.defaultDisplayTitle : title,
            detail: detail,
            state: state,
            runningStartedAt: runningStartedAt
        )
    }

    private func detail(for thread: CodexThread?) -> String {
        guard let cwd = thread?.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return "Remodex"
        }

        let lastPathComponent = URL(fileURLWithPath: cwd).lastPathComponent
        return lastPathComponent.isEmpty ? "Remodex" : lastPathComponent
    }

    private func nextExpirationDate(now: Date) -> Date? {
        let completedExpiration = completedOutcomes
            .map { $0.createdAt.addingTimeInterval(Self.completedLifetime) }
            .filter { $0 > now }
            .min()
        let failedExpiration = failedOutcomes
            .map { $0.createdAt.addingTimeInterval(Self.failedLifetime) }
            .filter { $0 > now }
            .min()

        switch (completedExpiration, failedExpiration) {
        case (.some(let completed), .some(let failed)):
            return min(completed, failed)
        case (.some(let completed), .none):
            return completed
        case (.none, .some(let failed)):
            return failed
        case (.none, .none):
            return nil
        }
    }

    private func scheduleNextExpirationSyncIfNeeded(
        codex: CodexService,
        snapshot: RemodexDisplayIslandSnapshot,
        now: Date
    ) {
        expirationSyncTask?.cancel()
        guard let nextExpirationDate = snapshot.nextExpirationDate else {
            expirationSyncTask = nil
            return
        }

        let delay = max(0, nextExpirationDate.timeIntervalSince(now))
        let nanoseconds = UInt64(delay * 1_000_000_000)
        expirationSyncTask = Task { @MainActor [weak self, weak codex] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, let codex else {
                return
            }
            self.sync(codex: codex, immediately: true)
        }
    }

    private func hydrateRunningStartsFromCurrentActivity(now: Date) {
        guard let activity = currentActivity else {
            return
        }

        for conversation in activity.content.state.runningConversations {
            guard let runningStartedAt = conversation.runningStartedAt else {
                continue
            }
            if let existingStartedAt = runningStartedAtByThread[conversation.id] {
                runningStartedAtByThread[conversation.id] = min(existingStartedAt, runningStartedAt)
            } else {
                runningStartedAtByThread[conversation.id] = runningStartedAt
            }
            runningLastSeenAtByThread[conversation.id] = now
        }
    }

    private func apply(snapshot: RemodexDisplayIslandSnapshot, now: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAllActivities()
            lastSnapshot = nil
            return
        }

        guard !snapshot.isEmpty else {
            await endAllActivities()
            lastSnapshot = nil
            return
        }

        guard snapshot != lastSnapshot || currentActivity == nil else {
            return
        }

        let content = ActivityContent(
            state: RemodexDisplayIslandAttributes.ContentState(
                runningConversations: snapshot.runningConversations,
                completedConversations: snapshot.completedConversations,
                failedConversations: snapshot.failedConversations,
                updatedAt: now
            ),
            staleDate: snapshot.nextExpirationDate ?? now.addingTimeInterval(Self.defaultStaleInterval)
        )

        if let activity = currentActivity {
            await activity.update(content)
            activityID = activity.id
        } else {
            do {
                let activity = try Activity<RemodexDisplayIslandAttributes>.request(
                    attributes: RemodexDisplayIslandAttributes(title: "Remodex"),
                    content: content,
                    pushType: nil
                )
                activityID = activity.id
            } catch {
                activityID = nil
            }
        }

        lastSnapshot = snapshot
    }

    private var currentActivity: Activity<RemodexDisplayIslandAttributes>? {
        if let activityID,
           let matchingActivity = Activity<RemodexDisplayIslandAttributes>.activities.first(where: { $0.id == activityID }) {
            return matchingActivity
        }

        return Activity<RemodexDisplayIslandAttributes>.activities.first
    }

    private func endAllActivities() async {
        for activity in Activity<RemodexDisplayIslandAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activityID = nil
    }
}
