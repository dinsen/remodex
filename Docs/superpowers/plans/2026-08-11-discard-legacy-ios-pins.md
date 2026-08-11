# Discard Legacy iOS Pins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Do not delegate because the user prohibited subagents.

**Goal:** Remove stale iOS-only pins without displaying or migrating them, while preserving native Codex pin synchronization and confirmed offline cache behavior.

**Architecture:** Delete legacy pin storage at the Mac-scoped persistence boundary and remove the legacy queue from service state. Build the effective sidebar state only from confirmed native pins. Keep native refresh and mutation serialization unchanged.

**Tech Stack:** Swift 6, XCTest, Observation, Codex app-server JSON-RPC

---

### Task 1: Prove legacy pins are discarded

**Files:**
- Modify: `CodexMobile/CodexMobileTests/CodexThreadRenamePersistenceTests.swift`
- Modify: `CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift`

- [ ] Replace the legacy migration persistence test with a test that seeds old Mac-scoped pin keys, loads state, and asserts that legacy pins are absent while confirmed native pins remain.
- [ ] Add a service test that seeds old pin storage, performs native synchronization, and asserts that no `threadSection/create` or `thread/section/move` request is sent for those IDs.
- [ ] Run only the two new tests and confirm they fail for the expected legacy-union or migration behavior.

Run:

```bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:CodexMobileTests/CodexThreadRenamePersistenceTests/testLegacyPinsAreDiscardedOnLoad \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testLegacyStorageNeverCreatesOrMovesNativePins
```

### Task 2: Remove legacy migration state

**Files:**
- Modify: `CodexMobile/CodexMobile/Services/CodexService.swift`
- Modify: `CodexMobile/CodexMobile/Services/CodexService+MacContext.swift`
- Modify: `CodexMobile/CodexMobile/Services/CodexService+Helpers.swift`
- Modify: `CodexMobile/CodexMobile/Services/CodexService+NativePins.swift`

- [ ] Delete legacy pin IDs and snapshots during Mac-scoped state loading.
- [ ] Remove legacy queue fields, snapshot refresh/persistence, migration RPC logic, and the temporary union.
- [ ] Keep confirmed native cache loading, persistence, refresh, and mutations unchanged.
- [ ] Rerun the two focused tests and confirm they pass.
- [ ] Run the existing targeted native pin state and grouping tests from the original plan.
- [ ] Commit with `fix: discard legacy iOS pins`.

### Task 3: Device verification and crash evidence

**Files:** None unless a crash log confirms a separate code defect.

- [ ] Build, install, and launch the updated app on Dinsen using `xcodebuildmcp`.
- [ ] Confirm the sidebar shows only the native Codex pins.
- [ ] Capture a device crash log if the app still exits after continued use.
- [ ] Do not change crash-related code without a reproducible failure and a failing regression test.
