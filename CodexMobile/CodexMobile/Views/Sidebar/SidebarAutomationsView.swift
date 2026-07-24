// FILE: SidebarAutomationsView.swift
// Purpose: Renders Codex app automations inside the sidebar scope area.
// Layer: View Component
// Exports: SidebarAutomationsView, CodexAutomationScheduleFormatter
// Depends on: SwiftUI, CodexAutomation, AppFont, RemodexIcon

import Foundation
import SwiftUI

struct SidebarAutomationsView: View {
    let query: String
    let isConnected: Bool
    let loadAutomations: () async throws -> CodexAutomationList
    let setAutomationEnabled: (String, Bool) async throws -> CodexAutomation
    let loadAutomation: (String) async throws -> CodexAutomation
    let createAutomation: (CodexAutomationDraft) async throws -> CodexAutomation
    let updateAutomation: (CodexAutomationDraft) async throws -> CodexAutomation
    let deleteAutomation: (String) async throws -> Void

    @State private var state: LoadState = .idle
    @State private var pendingToggleIDs: Set<String> = []
    @State private var actionErrorMessage: String?
    @State private var activeSheet: AutomationSheet?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .task(id: isConnected) {
            await loadIfNeeded(force: false)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .create:
                SidebarAutomationEditorSheet(
                    title: "New Automation",
                    initialDraft: CodexAutomationDraft(),
                    save: createAutomation,
                    onSaved: upsertLoadedAutomation
                )
            case .detail(let id):
                SidebarAutomationDetailSheet(
                    automationID: id,
                    loadAutomation: loadAutomation,
                    updateAutomation: updateAutomation,
                    deleteAutomation: deleteAutomation,
                    onUpdated: upsertLoadedAutomation,
                    onDeleted: removeLoadedAutomation
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isConnected {
            messageView(title: "Connect to view automations", systemName: "bolt.horizontal.circle")
        } else {
            switch state {
            case .idle, .loading:
                loadingRows
            case .loaded(let list):
                loadedContent(list)
            case .failed(let message):
                errorView(message)
            }
        }
    }

    @ViewBuilder
    private func loadedContent(_ list: CodexAutomationList) -> some View {
        let filtered = filteredAutomations(list.automations)
        if filtered.isEmpty {
            newAutomationButton

            messageView(
                title: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No automations"
                    : "No matching automations",
                systemName: "calendar.badge.clock"
            )
        } else {
            newAutomationButton

            ForEach(filtered) { automation in
                SidebarAutomationRow(
                    automation: automation,
                    isTogglePending: pendingToggleIDs.contains(automation.id),
                    setEnabled: { enabled in
                        Task { await setAutomationRowEnabled(automation, enabled: enabled) }
                    },
                    openAutomation: {
                        activeSheet = .detail(automation.id)
                    }
                )
            }

            if !list.errors.isEmpty {
                Text("\(list.errors.count) automation file could not be read.")
                    .font(AppFont.caption(weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            if let actionErrorMessage {
                Text(actionErrorMessage)
                    .font(AppFont.caption(weight: .regular))
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
    }

    private var newAutomationButton: some View {
        Button {
            activeSheet = .create
        } label: {
            Label("New Automation", systemImage: "plus")
                .font(AppFont.subheadline(weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.bottom, 2)
    }

    private var loadingRows: some View {
        ForEach(0..<3, id: \.self) { _ in
            SidebarAutomationPlaceholderRow()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            messageView(title: message, systemName: "exclamationmark.triangle")

            Button {
                Task { await loadIfNeeded(force: true) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(AppFont.subheadline(weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    private func messageView(title: String, systemName: String) -> some View {
        HStack(spacing: 10) {
            RemodexIcon.image(systemName: systemName, size: 17, weight: .regular)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            Text(title)
                .font(AppFont.subheadline(weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.top, 12)
    }

    private func filteredAutomations(_ automations: [CodexAutomation]) -> [CodexAutomation] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return automations
        }

        return automations.filter { automation in
            automation.name.localizedCaseInsensitiveContains(normalizedQuery)
                || automation.id.localizedCaseInsensitiveContains(normalizedQuery)
                || (automation.status?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                || (automation.rrule?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                || automation.cwds.contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
    }

    private func loadIfNeeded(force: Bool) async {
        guard isConnected else {
            state = .idle
            return
        }
        if !force, case .loaded = state {
            return
        }

        state = .loading
        do {
            state = .loaded(try await loadAutomations())
        } catch is CancellationError {
            return
        } catch {
            state = .failed("Unable to load automations")
        }
    }

    private func setAutomationRowEnabled(_ automation: CodexAutomation, enabled: Bool) async {
        guard !pendingToggleIDs.contains(automation.id) else {
            return
        }

        pendingToggleIDs.insert(automation.id)
        actionErrorMessage = nil
        upsertLoadedAutomation(automation.replacingStatus(enabled ? "ACTIVE" : "PAUSED"))
        defer { pendingToggleIDs.remove(automation.id) }

        do {
            let updatedAutomation = try await setAutomationEnabled(automation.id, enabled)
            upsertLoadedAutomation(updatedAutomation)
        } catch is CancellationError {
            upsertLoadedAutomation(automation)
        } catch {
            upsertLoadedAutomation(automation)
            actionErrorMessage = "Unable to update automation"
        }
    }

    private func upsertLoadedAutomation(_ automation: CodexAutomation) {
        guard case .loaded(let list) = state else {
            return
        }

        state = .loaded(list.upsertingAutomation(automation))
    }

    private func removeLoadedAutomation(id: String) {
        guard case .loaded(let list) = state else {
            return
        }

        state = .loaded(list.removingAutomation(id: id))
    }
}

private extension SidebarAutomationsView {
    enum LoadState {
        case idle
        case loading
        case loaded(CodexAutomationList)
        case failed(String)
    }

    enum AutomationSheet: Identifiable {
        case create
        case detail(String)

        var id: String {
            switch self {
            case .create:
                return "create"
            case .detail(let id):
                return "detail-\(id)"
            }
        }
    }
}

private extension CodexAutomationList {
    func upsertingAutomation(_ automation: CodexAutomation) -> CodexAutomationList {
        var updatedAutomations = automations
        if let index = updatedAutomations.firstIndex(where: { $0.id == automation.id }) {
            updatedAutomations[index] = automation
        } else {
            updatedAutomations.insert(automation, at: 0)
        }

        return CodexAutomationList(
            automationDirectory: automationDirectory,
            automations: updatedAutomations,
            errors: errors
        )
    }

    func removingAutomation(id: String) -> CodexAutomationList {
        CodexAutomationList(
            automationDirectory: automationDirectory,
            automations: automations.filter { $0.id != id },
            errors: errors
        )
    }
}

private struct SidebarAutomationRow: View {
    let automation: CodexAutomation
    let isTogglePending: Bool
    let setEnabled: (Bool) -> Void
    let openAutomation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RemodexIcon.image(systemName: "calendar.badge.clock", size: 16, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(automation.name)
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        statusCapsule
                    }

                    Text(CodexAutomationScheduleFormatter.summary(for: automation.rrule))
                        .font(AppFont.caption(weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                automationToggle
            }

            metadataLine
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: openAutomation)
    }

    private var statusCapsule: some View {
        Text(automation.normalizedStatus)
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var automationToggle: some View {
        HStack(spacing: 6) {
            if isTogglePending {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle(isOn: Binding(
                get: { automation.isEnabled },
                set: { enabled in setEnabled(enabled) }
            )) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.green)
            .frame(width: 52)
            .disabled(isTogglePending)
            .accessibilityLabel(automation.isEnabled ? "Disable automation" : "Enable automation")
        }
    }

    private var metadataLine: some View {
        HStack(spacing: 6) {
            if let folder = automation.primaryFolderLabel {
                Text(folder)
            }

            if automation.cwdCount > 1 {
                Text("+\(automation.cwdCount - 1)")
            }

            if let executionEnvironment = automation.executionEnvironment {
                Text(executionEnvironment)
            }

            if let model = automation.model {
                Text(model)
            }
        }
        .font(AppFont.caption2(weight: .regular))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private var statusColor: Color {
        switch automation.status?.lowercased() {
        case "enabled", "active", "running":
            return .green
        case "paused", "disabled":
            return .secondary
        case "failed", "error":
            return .red
        default:
            return .orange
        }
    }
}

private struct SidebarAutomationPlaceholderRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let shimmerBandWidth: CGFloat = 88
    private static let shimmerDuration: TimeInterval = 1.45

    var body: some View {
        placeholderContent
            .foregroundStyle(Color(.tertiarySystemFill))
            .overlay {
                if !reduceMotion {
                    shimmerWave
                        .mask(placeholderContent.foregroundStyle(.white))
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }

    private var placeholderContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .frame(width: 140, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .frame(width: 48, height: 14)
            }
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .frame(width: 210, height: 12)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .frame(width: 170, height: 10)
        }
    }

    private var shimmerWave: some View {
        GeometryReader { proxy in
            let travelDistance = proxy.size.width + Self.shimmerBandWidth

            LinearGradient(
                colors: waveColors,
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Self.shimmerBandWidth)
            .offset(x: -Self.shimmerBandWidth)
            .blendMode(.plusLighter)
            .keyframeAnimator(initialValue: CGFloat.zero, repeating: true) { content, offset in
                content.offset(x: offset)
            } keyframes: { _ in
                LinearKeyframe(travelDistance, duration: Self.shimmerDuration)
            }
        }
    }

    private var waveColors: [Color] {
        let highlight = Color.white
        let edge = colorScheme == .dark ? 0.18 : 0.12
        let peak = colorScheme == .dark ? 0.86 : 0.72
        return [
            .clear,
            highlight.opacity(edge),
            highlight.opacity(peak),
            highlight.opacity(edge),
            .clear,
        ]
    }
}

nonisolated enum CodexAutomationScheduleFormatter {
    static func summary(for rrule: String?) -> String {
        guard let rrule = rrule?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rrule.isEmpty else {
            return "No schedule"
        }

        let fields = parse(rrule)
        let frequency = fields["FREQ"] ?? ""
        let interval = Int(fields["INTERVAL"] ?? "") ?? 1
        var parts: [String] = [frequencySummary(frequency: frequency, interval: interval)]

        if let days = fields["BYDAY"], !days.isEmpty {
            parts.append(days.split(separator: ",").map(dayName).joined(separator: ", "))
        }

        if let hour = Int(fields["BYHOUR"] ?? ""),
           let minute = Int(fields["BYMINUTE"] ?? "0") {
            parts.append(String(format: "%02d:%02d", hour, minute))
        }

        return parts
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static func parse(_ rrule: String) -> [String: String] {
        let body = rrule.hasPrefix("RRULE:") ? String(rrule.dropFirst("RRULE:".count)) : rrule
        var fields: [String: String] = [:]
        for pair in body.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0].uppercased()] = parts[1]
        }
        return fields
    }

    private static func frequencySummary(frequency: String, interval: Int) -> String {
        switch frequency {
        case "HOURLY":
            return interval <= 1 ? "Every hour" : "Every \(interval) hours"
        case "DAILY":
            return interval <= 1 ? "Every day" : "Every \(interval) days"
        case "WEEKLY":
            return interval <= 1 ? "Every week" : "Every \(interval) weeks"
        case "MONTHLY":
            return interval <= 1 ? "Every month" : "Every \(interval) months"
        default:
            return frequency.isEmpty ? "Scheduled" : frequency.capitalized
        }
    }

    private static func dayName(_ raw: Substring) -> String {
        switch raw {
        case "MO": return "Mon"
        case "TU": return "Tue"
        case "WE": return "Wed"
        case "TH": return "Thu"
        case "FR": return "Fri"
        case "SA": return "Sat"
        case "SU": return "Sun"
        default: return String(raw)
        }
    }
}

#if DEBUG
#Preview("Automations") {
    ScrollView {
        SidebarAutomationsView(
            query: "",
            isConnected: true,
            loadAutomations: {
                CodexAutomationList(
                    automationDirectory: nil,
                    automations: [
                        CodexAutomation(
                            id: "weekly-review",
                            name: "Weekly Review",
                            prompt: "Summarize the week and prepare follow-up tasks.",
                            kind: "cron",
                            status: "PAUSED",
                            rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=30",
                            model: "gpt-5.3-codex",
                            reasoningEffort: "medium",
                            executionEnvironment: "worktree",
                            cwds: ["/Users/me/projects/app"],
                            cwdCount: 1,
                            createdAtMilliseconds: nil,
                            updatedAtMilliseconds: nil
                        ),
                    ],
                    errors: []
                )
            },
            setAutomationEnabled: { id, enabled in
                CodexAutomation(
                    id: id,
                    name: "Weekly Review",
                    prompt: "Summarize the week and prepare follow-up tasks.",
                    kind: "cron",
                    status: enabled ? "ACTIVE" : "PAUSED",
                    rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=30",
                    model: "gpt-5.3-codex",
                    reasoningEffort: "medium",
                    executionEnvironment: "worktree",
                    cwds: ["/Users/me/projects/app"],
                    cwdCount: 1,
                    createdAtMilliseconds: nil,
                    updatedAtMilliseconds: nil
                )
            },
            loadAutomation: { id in
                CodexAutomation(
                    id: id,
                    name: "Weekly Review",
                    prompt: "Summarize the week and prepare follow-up tasks.",
                    kind: "cron",
                    status: "PAUSED",
                    rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=30",
                    model: "gpt-5.3-codex",
                    reasoningEffort: "medium",
                    executionEnvironment: "worktree",
                    cwds: ["/Users/me/projects/app"],
                    cwdCount: 1,
                    createdAtMilliseconds: nil,
                    updatedAtMilliseconds: nil
                )
            },
            createAutomation: { draft in
                CodexAutomation(
                    id: "new-automation",
                    name: draft.name,
                    prompt: draft.prompt,
                    kind: "cron",
                    status: draft.status,
                    rrule: draft.rrule,
                    model: draft.model,
                    reasoningEffort: draft.reasoningEffort,
                    executionEnvironment: draft.executionEnvironment,
                    cwds: draft.cwds,
                    cwdCount: draft.cwds.count,
                    createdAtMilliseconds: nil,
                    updatedAtMilliseconds: nil
                )
            },
            updateAutomation: { draft in
                CodexAutomation(
                    id: draft.id ?? "weekly-review",
                    name: draft.name,
                    prompt: draft.prompt,
                    kind: "cron",
                    status: draft.status,
                    rrule: draft.rrule,
                    model: draft.model,
                    reasoningEffort: draft.reasoningEffort,
                    executionEnvironment: draft.executionEnvironment,
                    cwds: draft.cwds,
                    cwdCount: draft.cwds.count,
                    createdAtMilliseconds: nil,
                    updatedAtMilliseconds: nil
                )
            },
            deleteAutomation: { _ in }
        )
    }
}
#endif
