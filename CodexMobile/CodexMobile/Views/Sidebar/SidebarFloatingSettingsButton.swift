// FILE: SidebarFloatingSettingsButton.swift
// Purpose: Floating shortcuts used to open top-level sidebar destinations.
// Layer: View Component
// Exports: SidebarFloatingSettingsButton, SidebarFloatingMacsButton, SidebarMacConnectionStatusView

import SwiftUI

private struct SidebarFloatingCircleButton: View {
    let colorScheme: ColorScheme
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticFeedback.shared.triggerImpactFeedback()
            action()
        }) {
            Image(systemName: systemImage)
                .font(AppFont.system(size: 17, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .frame(width: 44, height: 44)
                .adaptiveGlass(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SidebarFloatingSettingsButton: View {
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        SidebarFloatingCircleButton(
            colorScheme: colorScheme,
            systemImage: "gearshape.fill",
            accessibilityLabel: "Settings",
            action: action
        )
    }
}

struct SidebarFloatingMacsButton: View {
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        SidebarFloatingCircleButton(
            colorScheme: colorScheme,
            systemImage: "desktopcomputer",
            accessibilityLabel: "My Macs",
            action: action
        )
    }
}

struct SidebarMacConnectionStatusView: View {
    let name: String
    let systemName: String?
    let isConnected: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(statusTitle)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(name)
                .font(AppFont.mono(.subheadline))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: 170, alignment: .trailing)
    }

    private var statusTitle: String {
        isConnected ? "Connected to Mac" : "Saved Mac"
    }
}
