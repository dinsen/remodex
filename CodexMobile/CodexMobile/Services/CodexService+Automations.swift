// FILE: CodexService+Automations.swift
// Purpose: Codex automation metadata and status updates surfaced through the local bridge.
// Layer: Service Extension
// Exports: CodexAutomation, CodexAutomationList, CodexService automation APIs
// Depends on: Foundation, JSONValue, RPC transport

import Foundation

struct CodexAutomation: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
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

    private static func decodeAutomation(_ value: JSONValue) -> CodexAutomation? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let name = object["name"]?.stringValue else {
            return nil
        }

        return CodexAutomation(
            id: id,
            name: name,
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
