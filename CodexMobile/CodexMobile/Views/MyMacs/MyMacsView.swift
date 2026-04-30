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
    let onCancelSwitch: () -> Void
    let isSwitchingMac: Bool
    let isCancellingMacSwitch: Bool
    let switchingMacDeviceId: String?
    let switchNotice: String?

    @State private var pendingForgetDeviceId: String?
    @State private var pendingSwitchDeviceId: String?

    private var currentTrustedMac: CodexTrustedMacRecord? {
        codex.currentTrustedMacRecord
    }

    private var sortedTrustedMacs: [CodexTrustedMacRecord] {
        codex.trustedMacRegistry.records.values.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId
            let rhsIsCurrent = rhs.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId
            if lhsIsCurrent != rhsIsCurrent {
                return lhsIsCurrent
            }

            let lhsIsPrevious = lhs.macDeviceId == codex.normalizedPreviousTrustedMacDeviceId
            let rhsIsPrevious = rhs.macDeviceId == codex.normalizedPreviousTrustedMacDeviceId
            if lhsIsPrevious != rhsIsPrevious {
                return lhsIsPrevious
            }

            return (lhs.lastUsedAt ?? lhs.lastPairedAt) > (rhs.lastUsedAt ?? rhs.lastPairedAt)
        }
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    if let switchNotice, !switchNotice.isEmpty {
                        switchNoticeBanner(switchNotice)
                    }

                    if let currentTrustedMac {
                        sectionTitle("Current Mac")
                        currentMacCard(for: currentTrustedMac)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("Paired Macs")
                        pairedMacsCard
                    }

                    scanButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }

            if isSwitchingMac {
                switchingOverlay
            }
        }
        .navigationTitle("My Macs")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSwitchingMac)
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

    private var pairedMacsCard: some View {
        MyMacCard {
            if sortedTrustedMacs.isEmpty {
                Text("No paired Macs yet.")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sortedTrustedMacs.enumerated()), id: \.element.macDeviceId) { index, trustedMac in
                        pairedMacRow(for: trustedMac)

                        if index < sortedTrustedMacs.count - 1 {
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
            }
        }
    }

    private func currentMacCard(for trustedMac: CodexTrustedMacRecord) -> some View {
        let identity = displayIdentity(for: trustedMac)
        let status = statusLabel(for: trustedMac)
        let detail = detailLabel(for: trustedMac)

        return MyMacCard {
            HStack(alignment: .center, spacing: 12) {
                macAvatar

                VStack(alignment: .leading, spacing: 4) {
                    Text(identity.primaryName)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let secondaryName = identity.secondaryName {
                        Text(secondaryName)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text([status, detail].compactMap { $0 }.joined(separator: " · "))
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if isSwitchingMac, switchingMacDeviceId == trustedMac.macDeviceId {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private func pairedMacRow(for trustedMac: CodexTrustedMacRecord) -> some View {
        let isCurrent = trustedMac.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId
        let isPrevious = trustedMac.macDeviceId == codex.normalizedPreviousTrustedMacDeviceId
        let isSwitching = trustedMac.macDeviceId == switchingMacDeviceId
        let identity = displayIdentity(for: trustedMac)

        return HStack(alignment: .center, spacing: 12) {
            macAvatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(identity.primaryName)
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isCurrent {
                        Text("Current")
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else if isPrevious {
                        Text("Previous")
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if let secondaryName = identity.secondaryName {
                    Text(secondaryName)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text([statusLabel(for: trustedMac), detailLabel(for: trustedMac)].compactMap { $0 }.joined(separator: " · "))
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isSwitchingMac, !isCurrent else {
                    return
                }
                handleSwitchSelection(for: trustedMac.macDeviceId)
            }

            if isSwitching {
                ProgressView()
                    .controlSize(.small)
            } else if !isCurrent {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            Button {
                pendingForgetDeviceId = trustedMac.macDeviceId
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(isSwitchingMac)
        }
        .padding(.vertical, 12)
    }

    private var scanButton: some View {
        Button("Scan QR Code") {
            guard !isSwitchingMac else {
                return
            }
            onScanQRCode()
        }
        .font(AppFont.body(weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .adaptiveGlass(.regular, in: Capsule())
        .disabled(isSwitchingMac)
    }

    private var switchingOverlay: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            MyMacCard {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Switching Mac…")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    if let phaseLabel = switchingConnectionPhaseLabel {
                        Text(phaseLabel)
                            .font(AppFont.caption(weight: .medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if let secureLabel = switchingSecureStatusLabel {
                        Text(secureLabel)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if let switchingMacDeviceId,
                       let trustedMac = codex.trustedMacRecord(for: switchingMacDeviceId) {
                        Text(displayIdentity(for: trustedMac).primaryName)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button(isCancellingMacSwitch ? "Cancelling..." : "Cancel") {
                        onCancelSwitch()
                    }
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .adaptiveGlass(.regular, in: Capsule())
                    .disabled(isCancellingMacSwitch)
                }
                .frame(width: 220)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .myMacCardAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFont.body(weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func switchNoticeBanner(_ text: String) -> some View {
        MyMacCard {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(text)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var requiresSwitchConfirmation: Bool {
        !codex.runningThreadIDs.isEmpty
            || !codex.protectedRunningFallbackThreadIDs.isEmpty
            || !codex.activeTurnIdByThread.isEmpty
    }

    private func handleSwitchSelection(for deviceId: String) {
        guard !isSwitchingMac else {
            return
        }

        if requiresSwitchConfirmation {
            pendingSwitchDeviceId = deviceId
            return
        }
        onSwitchMac(deviceId)
    }

    private func displayIdentity(for trustedMac: CodexTrustedMacRecord) -> MyMacDisplayIdentity {
        let nickname = SidebarComputerNicknameStore.nickname(for: trustedMac.macDeviceId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let systemName = trustedMac.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if !nickname.isEmpty, let systemName, !systemName.isEmpty {
            return MyMacDisplayIdentity(primaryName: nickname, secondaryName: systemName)
        }

        if !nickname.isEmpty {
            return MyMacDisplayIdentity(primaryName: nickname, secondaryName: nil)
        }

        if let systemName, !systemName.isEmpty {
            return MyMacDisplayIdentity(primaryName: systemName, secondaryName: nil)
        }

        return MyMacDisplayIdentity(primaryName: "Mac", secondaryName: nil)
    }

    private func statusLabel(for trustedMac: CodexTrustedMacRecord) -> String {
        if trustedMac.macDeviceId == switchingMacDeviceId {
            return "Switching"
        }
        if trustedMac.macDeviceId == codex.normalizedRelayMacDeviceId && codex.isConnected {
            return "Connected"
        }
        if trustedMac.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId {
            return "Selected"
        }
        if trustedMac.macDeviceId == codex.normalizedPreviousTrustedMacDeviceId {
            return "Previous"
        }
        return "Saved"
    }

    private func detailLabel(for trustedMac: CodexTrustedMacRecord) -> String? {
        if trustedMac.macDeviceId == switchingMacDeviceId {
            return "Reloading chats…"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let referenceDate = trustedMac.lastUsedAt ?? trustedMac.lastPairedAt
        return formatter.localizedString(for: referenceDate, relativeTo: Date())
    }

    private var macAvatar: some View {
        Image(systemName: "desktopcomputer")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .background(
                Circle()
                    .fill(Color.primary.opacity(0.06))
            )
    }

    private var switchingConnectionPhaseLabel: String? {
        let label = codex.connectionPhaseDisplayLabel
        return label == "Offline" ? nil : label
    }

    private var switchingSecureStatusLabel: String? {
        codex.secureConnectionDisplayLabel
    }
}

private struct MyMacDisplayIdentity {
    let primaryName: String
    let secondaryName: String?
}

private struct MyMacCard<Content: View>: View {
    @Environment(\.myMacCardContentAlignment) private var contentAlignment
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: contentAlignment)
            .padding(16)
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

private struct MyMacCardContentAlignmentKey: EnvironmentKey {
    static let defaultValue: Alignment = .leading
}

private extension EnvironmentValues {
    var myMacCardContentAlignment: Alignment {
        get { self[MyMacCardContentAlignmentKey.self] }
        set { self[MyMacCardContentAlignmentKey.self] = newValue }
    }
}

private extension View {
    func myMacCardAlignment(_ alignment: Alignment) -> some View {
        environment(\.myMacCardContentAlignment, alignment)
    }
}
