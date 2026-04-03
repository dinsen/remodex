// FILE: AIChangeSetPersistence.swift
// Purpose: Persists assistant-scoped revertable change sets between app launches.
// Layer: Service
// Exports: AIChangeSetPersistence
// Depends on: Foundation, AIChangeSetModels

import Foundation

struct AIChangeSetPersistence {
    private let fileName = "codex-ai-change-sets-v1.json"

    // Loads the stored change-set ledger from disk. Returns an empty array on failure.
    func load(macDeviceId: String? = nil) -> [AIChangeSet] {
        let decoder = JSONDecoder()
        for fileURL in storeURLs(macDeviceId: macDeviceId) {
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }

            if let decoded = try? decoder.decode([AIChangeSet].self, from: data) {
                return decoded
            }
        }

        return []
    }

    // Persists the full change-set ledger atomically to keep revert metadata durable.
    func save(_ value: [AIChangeSet], macDeviceId: String? = nil) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else {
            return
        }

        let fileURL = storeURL(macDeviceId: macDeviceId)
        ensureParentDirectoryExists(for: fileURL)
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func storeURL(macDeviceId: String?) -> URL {
        storeURLs(macDeviceId: macDeviceId)[0]
    }

    private func storeURLs(macDeviceId: String?) -> [URL] {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        let rootDirectory = base.appendingPathComponent(bundleID, isDirectory: true)
        let scopedDirectory: URL
        if let normalizedMacDeviceId = normalizedMacDeviceId(macDeviceId) {
            scopedDirectory = rootDirectory
                .appendingPathComponent("mac", isDirectory: true)
                .appendingPathComponent(normalizedMacDeviceId, isDirectory: true)
        } else {
            scopedDirectory = rootDirectory
        }

        let scopedURL = scopedDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard normalizedMacDeviceId(macDeviceId) != nil else {
            return [scopedURL]
        }

        let legacyURL = rootDirectory.appendingPathComponent(fileName, isDirectory: false)
        return [scopedURL, legacyURL]
    }

    private func ensureParentDirectoryExists(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func normalizedMacDeviceId(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
