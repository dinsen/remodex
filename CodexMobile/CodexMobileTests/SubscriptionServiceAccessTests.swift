// FILE: SubscriptionServiceAccessTests.swift
// Purpose: Verifies the local free-send gate allows 5 attempts before the hard paywall path.
// Layer: Unit Test
// Exports: SubscriptionServiceAccessTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class SubscriptionServiceAccessTests: XCTestCase {
    func testFreshInstallStartsWithLocalProAccess() {
        let service = makeService()

        XCTAssertTrue(service.hasProAccess)
        XCTAssertTrue(service.hasAppAccess)
        XCTAssertEqual(service.freeSendCount, 0)
        XCTAssertEqual(service.remainingFreeSendAttempts, 5)
        XCTAssertTrue(service.hasFreeSendAccess)
    }

    func testFreeSendAttemptsAreNotConsumedWhenLocalProAccessIsGranted() {
        let service = makeService()

        for _ in 0..<7 {
            service.consumeFreeSendAttemptIfNeeded()
        }

        XCTAssertEqual(service.freeSendCount, 0)
        XCTAssertEqual(service.remainingFreeSendAttempts, 5)
        XCTAssertTrue(service.hasFreeSendAccess)
        XCTAssertTrue(service.hasAppAccess)
    }

    private func makeService() -> SubscriptionService {
        let suiteName = "SubscriptionServiceAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return SubscriptionService(defaults: defaults)
    }
}
