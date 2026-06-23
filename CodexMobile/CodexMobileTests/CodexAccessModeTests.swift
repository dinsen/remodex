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
        XCTAssertEqual(CodexAccessMode.fullAccess.sandboxLegacyValue, "danger-full-access")
    }

    func testDisplayNamesMatchCodexAppWording() {
        XCTAssertEqual(CodexAccessMode.onRequest.displayName, "Approve for me")
        XCTAssertEqual(CodexAccessMode.onRequest.menuTitle, "Approve for me")
        XCTAssertEqual(CodexAccessMode.fullAccess.displayName, "Full access")
        XCTAssertEqual(CodexAccessMode.fullAccess.menuTitle, "Full access")
    }
}
