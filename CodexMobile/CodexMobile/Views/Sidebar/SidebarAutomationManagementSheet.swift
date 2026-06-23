// FILE: SidebarAutomationManagementSheet.swift
// Purpose: Presents automation detail, create, edit, and delete flows from the sidebar list.
// Layer: View Component
// Exports: SidebarAutomationDetailSheet, SidebarAutomationEditorSheet
// Depends on: SwiftUI, CodexAutomation, CodexAutomationDraft, AppFont

import SwiftUI

struct SidebarAutomationDetailSheet: View {
    let automationID: String
    let loadAutomation: (String) async throws -> CodexAutomation
    let updateAutomation: (CodexAutomationDraft) async throws -> CodexAutomation
    let deleteAutomation: (String) async throws -> Void
    let onUpdated: (CodexAutomation) -> Void
    let onDeleted: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase: LoadPhase = .loading
    @State private var isShowingEditor = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Automation")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }

                    if loadedAutomation != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Edit") { isShowingEditor = true }
                                .disabled(isDeleting)
                        }
                    }
                }
        }
        .task(id: automationID) {
            await load()
        }
        .sheet(isPresented: $isShowingEditor) {
            if let automation = loadedAutomation {
                SidebarAutomationEditorSheet(
                    title: "Edit Automation",
                    initialDraft: CodexAutomationDraft(automation: automation),
                    save: updateAutomation,
                    onSaved: { updated in
                        phase = .loaded(updated)
                        onUpdated(updated)
                    }
                )
            }
        }
        .confirmationDialog(
            "Delete Automation?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Automation", role: .destructive) {
                Task { await deleteCurrentAutomation() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the automation from this Mac.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let automation):
            detailForm(automation)
        case .failed:
            ContentUnavailableView(
                "Unable to load automation",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private func detailForm(_ automation: CodexAutomation) -> some View {
        Form {
            Section {
                LabeledContent("Status", value: automation.normalizedStatus)
                LabeledContent("Schedule", value: CodexAutomationScheduleFormatter.summary(for: automation.rrule))
                if let updatedAt = automation.updatedAt {
                    LabeledContent("Updated", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section("Prompt") {
                Text(automation.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? automation.prompt ?? "" : "No prompt")
                    .font(AppFont.body())
                    .foregroundStyle(automation.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? .primary : .secondary)
                    .textSelection(.enabled)
            }

            Section("Workspaces") {
                if automation.cwds.isEmpty {
                    Text("No workspace")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(automation.cwds, id: \.self) { cwd in
                        Text(cwd)
                            .font(AppFont.caption(weight: .regular))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Runtime") {
                LabeledContent("Environment", value: automation.executionEnvironment ?? "worktree")
                if let model = automation.model {
                    LabeledContent("Model", value: model)
                }
                if let reasoningEffort = automation.reasoningEffort {
                    LabeledContent("Reasoning", value: reasoningEffort)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Delete Automation", role: .destructive) {
                    isConfirmingDelete = true
                }
                .disabled(isDeleting)
            }
        }
    }

    private var loadedAutomation: CodexAutomation? {
        if case .loaded(let automation) = phase {
            return automation
        }
        return nil
    }

    private func load() async {
        phase = .loading
        do {
            phase = .loaded(try await loadAutomation(automationID))
        } catch is CancellationError {
            return
        } catch {
            phase = .failed
        }
    }

    private func deleteCurrentAutomation() async {
        guard !isDeleting else { return }

        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            try await deleteAutomation(automationID)
            onDeleted(automationID)
            dismiss()
        } catch {
            errorMessage = "Unable to delete automation"
        }
    }
}

struct SidebarAutomationEditorSheet: View {
    let title: String
    let save: (CodexAutomationDraft) async throws -> CodexAutomation
    let onSaved: (CodexAutomation) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: CodexAutomationDraft
    @State private var workspaceText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        title: String,
        initialDraft: CodexAutomationDraft,
        save: @escaping (CodexAutomationDraft) async throws -> CodexAutomation,
        onSaved: @escaping (CodexAutomation) -> Void
    ) {
        self.title = title
        self.save = save
        self.onSaved = onSaved
        _draft = State(initialValue: initialDraft)
        _workspaceText = State(initialValue: initialDraft.cwds.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Picker("Status", selection: $draft.status) {
                        Text("Active").tag("ACTIVE")
                        Text("Paused").tag("PAUSED")
                    }
                }

                Section("Prompt") {
                    TextEditor(text: $draft.prompt)
                        .font(AppFont.body())
                        .frame(minHeight: 140)
                }

                Section("Schedule") {
                    TextField("Rule", text: $draft.rrule)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text(CodexAutomationScheduleFormatter.summary(for: draft.rrule))
                        .font(AppFont.caption(weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Section("Workspaces") {
                    TextEditor(text: $workspaceText)
                        .font(AppFont.caption(weight: .regular))
                        .frame(minHeight: 72)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Runtime") {
                    Picker("Environment", selection: $draft.executionEnvironment) {
                        Text("Worktree").tag("worktree")
                        Text("Local").tag("local")
                    }

                    TextField("Model", text: modelBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("Reasoning", selection: reasoningBinding) {
                        Text("Default").tag("")
                        Text("None").tag("none")
                        Text("Minimal").tag("minimal")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                        Text("Extra High").tag("xhigh")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving" : "Save") {
                        Task { await saveDraft() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { draft.model ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.model = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private var reasoningBinding: Binding<String> {
        Binding(
            get: { draft.reasoningEffort ?? "" },
            set: { value in
                draft.reasoningEffort = value.isEmpty ? nil : value
            }
        )
    }

    private func saveDraft() async {
        guard canSave, !isSaving else { return }

        var cleanedDraft = draft
        cleanedDraft.name = cleanedDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanedDraft.prompt = cleanedDraft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanedDraft.rrule = cleanedDraft.rrule.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanedDraft.cwds = parseWorkspaces(workspaceText)

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let automation = try await save(cleanedDraft)
            onSaved(automation)
            dismiss()
        } catch {
            errorMessage = "Unable to save automation"
        }
    }

    private func parseWorkspaces(_ raw: String) -> [String] {
        raw
            .split { character in
                character == "\n" || character == ","
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private enum LoadPhase {
    case loading
    case loaded(CodexAutomation)
    case failed
}

