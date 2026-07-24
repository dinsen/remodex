// FILE: SubscriptionService.swift
// Purpose: Owns local access state for open-source/local-first builds.
// Layer: Service
// Exports: SubscriptionService
// Depends on: Foundation, Observation

import Foundation
import Observation

enum SubscriptionBootstrapState: Equatable {
    case idle
    case loading
    case ready
    case failed
}

@MainActor
@Observable
final class SubscriptionService {
    private static let freeSendCountDefaultsKey = "codex.subscription.freeSendCount"
    private static let freeSendLimit = 5

    private var isBootstrapping = false

    private(set) var bootstrapState: SubscriptionBootstrapState = .idle
    private(set) var hasProAccess = true
    private(set) var freeSendCount = 0

    init(defaults: UserDefaults = .standard) {
        freeSendCount = defaults.integer(forKey: Self.freeSendCountDefaultsKey)
    }

    var remainingFreeSendAttempts: Int {
        max(0, Self.freeSendLimit - freeSendCount)
    }

    var hasFreeSendAccess: Bool {
        freeSendCount < Self.freeSendLimit
    }

    var hasAppAccess: Bool {
        true
    }

    // Local-first builds never spend free-send attempts.
    func consumeFreeSendAttemptIfNeeded() {
    }

    // Bootstraps local access state once at launch or from a recovery retry action.
    func bootstrap() async {
        guard !isBootstrapping else {
            return
        }

        isBootstrapping = true
        defer { isBootstrapping = false }
        hasProAccess = true
        bootstrapState = .ready
    }

    // Keeps foreground recovery call sites intact without contacting external purchase services.
    func refreshCustomerInfoSilently() async {
        guard !isBootstrapping, bootstrapState != .loading else {
            return
        }

        hasProAccess = true
        bootstrapState = .ready
    }
}
