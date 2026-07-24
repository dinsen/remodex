// FILE: SubscriptionGateView.swift
// Purpose: Local-access fallback shown only if app access is unavailable.
// Layer: View
// Exports: SubscriptionGateView, SubscriptionBootstrapFailureView
// Depends on: SwiftUI, SubscriptionService

import SwiftUI

struct SubscriptionGateView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SubscriptionService.self) private var subscriptions

    var body: some View {
        localAccessFallback(
            title: "Remodex Access",
            message: "This local-first build enables app access without external purchase services.",
            primaryButtonTitle: "Continue"
        ) {
            Task {
                await subscriptions.bootstrap()
            }
        }
    }

    private func localAccessFallback(
        title: String,
        message: String,
        primaryButtonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 20) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(spacing: 10) {
                    Text(title)
                        .font(AppFont.system(size: 24, weight: .bold))
                        .multilineTextAlignment(.center)

                    Text(message)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                Button(primaryButtonTitle, action: action)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(ctaForegroundColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(ctaBackgroundColor, in: Capsule())
                    .buttonStyle(.plain)
                    .disabled(subscriptions.bootstrapState == .loading)

                OpenSourceBadge(style: colorScheme == .dark ? .light : .dark)
            }
            .padding(.horizontal, 24)
        }
    }

    private var ctaBackgroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var ctaForegroundColor: Color {
        colorScheme == .dark ? .black : .white
    }
}

struct SubscriptionBootstrapFailureView: View {
    @Environment(SubscriptionService.self) private var subscriptions

    var body: some View {
        SubscriptionGateView()
            .task {
                guard subscriptions.bootstrapState == .failed else {
                    return
                }

                await subscriptions.bootstrap()
            }
    }
}

#Preview {
    SubscriptionGateView()
        .environment(SubscriptionService())
}
