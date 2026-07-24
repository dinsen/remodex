// FILE: CodexService+Automations.swift
// Purpose: Codex automation metadata and status updates surfaced through the local bridge.
// Layer: Service Extension
// Exports: CodexAutomation, CodexAutomationList, CodexService automation APIs
// Depends on: Foundation, JSONValue, RPC transport

import Foundation

struct CodexAutomation: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let prompt: String?
    let kind: String?
    let status: String?
    let rrule: String?
    let model: String?
    let reasoningEffort: String?
    let executionEnvironment: String?
    let cwds: [String]
    let cwdCount: Int
    let createdAtMilliseconds: Int?
    let updatedAtMilliseconds: Int?

    var normalizedStatus: String {
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else {
            return "Unknown"
        }

        return status
            .lowercased()
            .split(separator: "_")
            .map { word in
                word.prefix(1).uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
    }

    var isEnabled: Bool {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "enabled", "running":
            return true
        default:
            return false
        }
    }

    var primaryFolderLabel: String? {
        cwds.first?.pathDisplayName
    }

    func replacingStatus(_ status: String) -> CodexAutomation {
        CodexAutomation(
            id: id,
            name: name,
            prompt: prompt,
            kind: kind,
            status: status,
            rrule: rrule,
            model: model,
            reasoningEffort: reasoningEffort,
            executionEnvironment: executionEnvironment,
            cwds: cwds,
            cwdCount: cwdCount,
            createdAtMilliseconds: createdAtMilliseconds,
            updatedAtMilliseconds: updatedAtMilliseconds
        )
    }

    var updatedAt: Date? {
        Self.date(milliseconds: updatedAtMilliseconds)
    }

    var createdAt: Date? {
        Self.date(milliseconds: createdAtMilliseconds)
    }

    private static func date(milliseconds: Int?) -> Date? {
        guard let milliseconds else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

struct CodexAutomationDraft: Equatable, Sendable {
    var id: String?
    var name: String
    var prompt: String
    var status: String
    var rrule: String
    var executionEnvironment: String
    var model: String?
    var reasoningEffort: String?
    var cwds: [String]

    init(
        id: String? = nil,
        name: String = "",
        prompt: String = "",
        status: String = "ACTIVE",
        rrule: String = "FREQ=HOURLY;INTERVAL=24;BYMINUTE=0",
        executionEnvironment: String = "worktree",
        model: String? = nil,
        reasoningEffort: String? = nil,
        cwds: [String] = []
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.status = status
        self.rrule = rrule
        self.executionEnvironment = executionEnvironment
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.cwds = cwds
    }

    init(automation: CodexAutomation) {
        self.init(
            id: automation.id,
            name: automation.name,
            prompt: automation.prompt ?? "",
            status: automation.status ?? "ACTIVE",
            rrule: automation.rrule ?? "FREQ=HOURLY;INTERVAL=24;BYMINUTE=0",
            executionEnvironment: automation.executionEnvironment ?? "worktree",
            model: automation.model,
            reasoningEffort: automation.reasoningEffort,
            cwds: automation.cwds
        )
    }

    var rpcParams: [String: JSONValue] {
        var params: [String: JSONValue] = [
            "name": .string(name),
            "prompt": .string(prompt),
            "status": .string(status),
            "rrule": .string(rrule),
            "executionEnvironment": .string(executionEnvironment),
            "cwds": .array(cwds.map(JSONValue.string)),
        ]
        if let id {
            params["id"] = .string(id)
        }
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["model"] = .string(model)
        }
        if let reasoningEffort, !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["reasoningEffort"] = .string(reasoningEffort)
        }
        return params
    }
}

struct CodexAutomationListError: Equatable, Sendable {
    let id: String
    let message: String
}

struct CodexAutomationList: Equatable, Sendable {
    let automationDirectory: String?
    let automations: [CodexAutomation]
    let errors: [CodexAutomationListError]
}

extension CodexService {
    func fetchAutomations() async throws -> CodexAutomationList {
        let response = try await sendRequest(method: "automation/list", params: .object([:]))
        guard let object = response.result?.objectValue,
              let rawAutomations = object["automations"]?.arrayValue else {
            throw CodexServiceError.invalidResponse("automation/list response missing automations")
        }

        let automations = rawAutomations.compactMap(Self.decodeAutomation)
        let errors = object["errors"]?.arrayValue?.compactMap(Self.decodeAutomationListError) ?? []
        return CodexAutomationList(
            automationDirectory: object["automationDirectory"]?.stringValue,
            automations: automations,
            errors: errors
        )
    }

    func setAutomationEnabled(id: String, enabled: Bool) async throws -> CodexAutomation {
        let response = try await sendRequest(
            method: "automation/setEnabled",
            params: .object([
                "id": .string(id),
                "enabled": .bool(enabled),
            ])
        )
        guard let object = response.result?.objectValue,
              let rawAutomation = object["automation"],
              let automation = Self.decodeAutomation(rawAutomation) else {
            throw CodexServiceError.invalidResponse("automation/setEnabled response missing automation")
        }

        return automation
    }

    func fetchAutomation(id: String) async throws -> CodexAutomation {
        let response = try await sendRequest(
            method: "automation/read",
            params: .object(["id": .string(id)])
        )
        return try Self.decodeAutomationResponse(response, method: "automation/read")
    }

    func createAutomation(_ draft: CodexAutomationDraft) async throws -> CodexAutomation {
        let response = try await sendRequest(
            method: "automation/create",
            params: .object(draft.rpcParams)
        )
        return try Self.decodeAutomationResponse(response, method: "automation/create")
    }

    func updateAutomation(_ draft: CodexAutomationDraft) async throws -> CodexAutomation {
        let response = try await sendRequest(
            method: "automation/update",
            params: .object(draft.rpcParams)
        )
        return try Self.decodeAutomationResponse(response, method: "automation/update")
    }

    func deleteAutomation(id: String) async throws {
        let response = try await sendRequest(
            method: "automation/delete",
            params: .object(["id": .string(id)])
        )
        guard response.error == nil else {
            throw CodexServiceError.invalidResponse("automation/delete failed")
        }
    }

    private static func decodeAutomationResponse(_ response: RPCMessage, method: String) throws -> CodexAutomation {
        guard let object = response.result?.objectValue,
              let rawAutomation = object["automation"],
              let automation = Self.decodeAutomation(rawAutomation) else {
            throw CodexServiceError.invalidResponse("\(method) response missing automation")
        }

        return automation
    }

    private static func decodeAutomation(_ value: JSONValue) -> CodexAutomation? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let name = object["name"]?.stringValue else {
            return nil
        }

        return CodexAutomation(
            id: id,
            name: name,
            prompt: object["prompt"]?.stringValue,
            kind: object["kind"]?.stringValue,
            status: object["status"]?.stringValue,
            rrule: object["rrule"]?.stringValue,
            model: object["model"]?.stringValue,
            reasoningEffort: object["reasoningEffort"]?.stringValue,
            executionEnvironment: object["executionEnvironment"]?.stringValue,
            cwds: object["cwds"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            cwdCount: object["cwdCount"]?.intValue ?? 0,
            createdAtMilliseconds: object["createdAt"]?.intValue,
            updatedAtMilliseconds: object["updatedAt"]?.intValue
        )
    }

    private static func decodeAutomationListError(_ value: JSONValue) -> CodexAutomationListError? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue else {
            return nil
        }

        return CodexAutomationListError(
            id: id,
            message: object["message"]?.stringValue ?? "Unable to read automation"
        )
    }
}
