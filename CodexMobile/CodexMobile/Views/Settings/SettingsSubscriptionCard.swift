// FILE: SettingsSubscriptionCard.swift
// Purpose: Presents Remodex Pro subscription status and purchase actions.
// Layer: Settings UI component
// Exports: SettingsSubscriptionCard
// Depends on: SwiftUI, SubscriptionService

import SwiftUI

struct SettingsSubscriptionCard: View {
    @Environment(SubscriptionService.self) private var subscriptions

    var body: some View {
        SettingsCard(
            title: "Remodex Pro",
            footer: "Local-first builds include app access without external purchase services."
        ) {
            SettingsValueRow(
                title: "Plan",
                value: subscriptions.hasProAccess ? "Active" : "Free",
                valueColor: subscriptions.hasProAccess ? .green : .secondary
            )

            SettingsInlineMessage(
                text: "Access is enabled locally; no purchase restore or account sync is required.",
                tint: .secondary
            )
        }
        .task {
            guard await SettingsPresentationRefreshPolicy.waitForInitialPresentationSettle() else {
                return
            }
            guard subscriptions.bootstrapState == .idle else {
                return
            }
            await subscriptions.bootstrap()
        }
    }
}
