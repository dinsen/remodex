// FILE: CodexAccessModeTests.swift
// Purpose: Guards the runtime access-mode strings used by fork/send fallbacks.
// Layer: Unit Test
// Exports: CodexAccessModeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class CodexAccessModeTests: XCTestCase {
    func testSandboxLegacyValuesMatchRuntimeEnums() {
        XCTAssertEqual(CodexAccessMode.onRequest.sandboxLegacyValue, "workspace-write")
        XCTAssertEqual(CodexAccessMode.autoReview.sandboxLegacyValue, "workspace-write")
        XCTAssertEqual(CodexAccessMode.fullAccess.sandboxLegacyValue, "danger-full-access")
    }

    func testDisplayNamesAndPickerTitlesMatchAccessModeIntent() {
        XCTAssertEqual(CodexAccessMode.onRequest.displayName, "Ask")
        XCTAssertEqual(CodexAccessMode.autoReview.displayName, "Approve for me")
        XCTAssertEqual(CodexAccessMode.fullAccess.displayName, "Full access")
        XCTAssertEqual(CodexAccessMode.onRequest.pickerTitle, "Ask for approval")
        XCTAssertEqual(CodexAccessMode.autoReview.pickerTitle, "Approve for me")
        XCTAssertEqual(CodexAccessMode.fullAccess.pickerTitle, "Full access")
    }

    func testAutoReviewKeepsOnRequestApprovalPolicy() {
        XCTAssertEqual(CodexAccessMode.autoReview.approvalPolicyCandidates, ["on-request", "onRequest"])
    }

    func testApprovalReviewersMatchAccessModeIntent() {
        XCTAssertEqual(CodexAccessMode.onRequest.approvalsReviewerCandidates, ["user", nil])
        XCTAssertEqual(
            CodexAccessMode.autoReview.approvalsReviewerCandidates,
            ["auto_review", "guardian_subagent"]
        )
        XCTAssertEqual(CodexAccessMode.fullAccess.approvalsReviewerCandidates, ["user", nil])
    }
}
