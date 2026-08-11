# Native Codex Pin Order Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not delegate because the user prohibited subagents.

**Goal:** Make Remodex display pinned roots in Codex's exact top-to-bottom section order, including manual reordering observed on refresh.

**Architecture:** Keep the existing native pin data flow unchanged. Make the pinned section query explicit by requesting ascending `section_position`; continue preserving response and page order through the confirmed cache and sidebar.

**Tech Stack:** Swift 6, XCTest, Codex app-server JSON-RPC

---

### Task 1: Request Codex's top-to-bottom pinned order

**Files:**
- Modify: `CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift:234-295`
- Modify: `CodexMobile/CodexMobile/Services/CodexService+NativePins.swift:326-339`

- [ ] **Step 1: Write the failing request test**

Extend `testNativePinnedThreadsPreserveSectionOrder` with:

```swift
XCTAssertEqual(
    threadListParams.map { $0["sortDirection"]?.stringValue },
    Array(repeating: "asc", count: 3)
)
```

This checks the initial all-source-kinds request, the compatibility retry, and the second page.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  'EXCLUDED_SOURCE_FILE_NAMES=TurnTimelineReducerTests.swift CodexThreadStartProjectBindingTests.swift' \
  test -only-testing:CodexMobileTests/CodexServiceThreadListTests/testNativePinnedThreadsPreserveSectionOrder
```

Expected: FAIL because every captured `sortDirection` is `nil` instead of `"asc"`.

- [ ] **Step 3: Add the minimal implementation**

Add this field beside `sortKey` in `fetchNativePinnedThreadsPage`:

```swift
"sortDirection": .string("asc"),
```

- [ ] **Step 4: Rerun the focused test and verify GREEN**

Run the command from Step 2.

Expected: 1 passed, 0 failed.

- [ ] **Step 5: Run the approved targeted pin tests**

Run:

```bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  'EXCLUDED_SOURCE_FILE_NAMES=TurnTimelineReducerTests.swift CodexThreadStartProjectBindingTests.swift' \
  test \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests \
  -only-testing:CodexMobileTests/CodexThreadRenamePersistenceTests \
  -only-testing:CodexMobileTests/SidebarThreadGroupingTests \
  -skip-testing:CodexMobileTests/CodexServiceThreadListTests/testListThreadsFlushesPendingRuntimeOptionRefreshAfterHydration \
  -skip-testing:CodexMobileTests/CodexServiceThreadListTests/testSortThreadsUsesUpdatedAtBeforeCreatedAtFallback \
  -skip-testing:CodexMobileTests/CodexServiceThreadListTests/testUserRenameSurvivesStaleThreadListRefreshForPinnedThread \
  -skip-testing:CodexMobileTests/SidebarThreadGroupingTests/testMakeGroupsMarksCodexManagedWorktreesInLabelAndIconWhenOriginIsUnknown \
  -skip-testing:CodexMobileTests/SidebarThreadGroupingTests/testMakeProjectChoicesKeepUnresolvedWorktreeSelectionCompactWithoutShowingPathInLabel
```

Expected: 78 passed, 0 failed. Do not run the full Xcode suite or simulator UI.

- [ ] **Step 6: Verify and commit**

Run:

```bash
rtk git diff --check
rtk git status --short
```

Commit only the test and implementation:

```bash
rtk git add CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift \
  CodexMobile/CodexMobile/Services/CodexService+NativePins.swift
rtk git commit -m "fix: preserve native Codex pin order"
```
