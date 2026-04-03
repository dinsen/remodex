// FILE: MyMacsView.swift
// Purpose: Top-level management page for paired Macs and explicit Mac switching.
// Layer: View
// Exports: MyMacsView
// Depends on: SwiftUI, CodexService

import SwiftUI

struct MyMacsView: View {
    @Environment(CodexService.self) private var codex

    let onScanQRCode: () -> Void
    let onSwitchMac: (String) -> Void
    let onForgetMac: (String) -> Void

    @State private var pendingForgetDeviceId: String?
    @State private var pendingSwitchDeviceId: String?

    private var sortedTrustedMacs: [CodexTrustedMacRecord] {
        codex.trustedMacRegistry.records.values.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId
            let rhsIsCurrent = rhs.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId
            if lhsIsCurrent != rhsIsCurrent {
                return lhsIsCurrent
            }

            return (lhs.lastUsedAt ?? lhs.lastPairedAt) > (rhs.lastUsedAt ?? rhs.lastPairedAt)
        }
    }

    var body: some View {
        List {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                Section("Current Mac") {
                    TrustedPairSummaryView(presentation: trustedPairPresentation)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }

            Section("Paired Macs") {
                if sortedTrustedMacs.isEmpty {
                    Text("No paired Macs yet.")
                        .font(AppFont.body())
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedTrustedMacs, id: \.macDeviceId) { trustedMac in
                        Button {
                            handleSwitchSelection(for: trustedMac.macDeviceId)
                        } label: {
                            MyMacRowView(
                                trustedMac: trustedMac,
                                isCurrent: trustedMac.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId,
                                isConnected: trustedMac.macDeviceId == codex.normalizedRelayMacDeviceId && codex.isConnected
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(trustedMac.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingForgetDeviceId = trustedMac.macDeviceId
                            } label: {
                                Text("Forget")
                            }
                        }
                    }
                }
            }

            Section {
                Button("Scan QR Code") {
                    onScanQRCode()
                }
                .font(AppFont.body(weight: .semibold))
            }
        }
        .font(AppFont.body())
        .navigationTitle("My Macs")
        .confirmationDialog(
            "Switch Mac?",
            isPresented: Binding(
                get: { pendingSwitchDeviceId != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingSwitchDeviceId = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Switch Mac", role: .destructive) {
                if let pendingSwitchDeviceId {
                    onSwitchMac(pendingSwitchDeviceId)
                }
                pendingSwitchDeviceId = nil
            }
            Button("Cancel", role: .cancel) {
                pendingSwitchDeviceId = nil
            }
        } message: {
            Text("Switching Macs will disconnect the current session, stop any in-progress runs, and may discard unfinished output.")
        }
        .alert(
            "Forget this Mac?",
            isPresented: Binding(
                get: { pendingForgetDeviceId != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingForgetDeviceId = nil
                    }
                }
            ),
            actions: {
                Button("Forget", role: .destructive) {
                    if let pendingForgetDeviceId {
                        onForgetMac(pendingForgetDeviceId)
                    }
                    pendingForgetDeviceId = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingForgetDeviceId = nil
                }
            },
            message: {
                Text("The paired Mac will be removed from this iPhone.")
            }
        )
    }

    private var requiresSwitchConfirmation: Bool {
        !codex.runningThreadIDs.isEmpty
            || !codex.protectedRunningFallbackThreadIDs.isEmpty
            || !codex.activeTurnIdByThread.isEmpty
    }

    private func handleSwitchSelection(for deviceId: String) {
        if requiresSwitchConfirmation {
            pendingSwitchDeviceId = deviceId
            return
        }
        onSwitchMac(deviceId)
    }
}

private struct MyMacRowView: View {
    let trustedMac: CodexTrustedMacRecord
    let isCurrent: Bool
    let isConnected: Bool

    private var primaryName: String {
        let nickname = SidebarMacNicknameStore.nickname(for: trustedMac.macDeviceId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty {
            return nickname
        }

        let systemName = trustedMac.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let systemName, !systemName.isEmpty {
            return systemName
        }

        return "Mac"
    }

    private var secondaryName: String? {
        let nickname = SidebarMacNicknameStore.nickname(for: trustedMac.macDeviceId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let systemName = trustedMac.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nickname.isEmpty,
              let systemName,
              !systemName.isEmpty else {
            return nil
        }
        return systemName
    }

    private var statusText: String {
        if isConnected {
            return "Connected"
        }
        if isCurrent {
            return "Current"
        }
        return "Saved"
    }

    private var timestampText: String? {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let referenceDate = trustedMac.lastUsedAt ?? trustedMac.lastPairedAt
        return formatter.localizedString(for: referenceDate, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(primaryName)
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isCurrent {
                        Text("Current")
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if let secondaryName {
                    Text(secondaryName)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(statusText)
                    if let timestampText {
                        Text("· \(timestampText)")
                    }
                }
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
