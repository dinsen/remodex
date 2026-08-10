# Native Codex Pins Implementation Plan

> **Execution rule:** Do not use subagents. Execute coding and commands in a separate user-visible Codex task with GPT-5.6 Luna at Max reasoning. Review the implementation in a separate read-only Codex task with GPT-5.6 Sol at High reasoning. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Codex's native `Pinned` section the sole writable source of truth and show its root threads once, in native order, above all projects in the iOS sidebar.

**Architecture:** Add section-aware relay transport and model decoding, then isolate native pin lookup, migration, caching, refresh, and serialized mutations in a focused `CodexService` extension. Existing sidebar grouping consumes one effective ordered pin list: a temporary deduplicated legacy/native union during migration, otherwise the last fully confirmed native list. Views remain presentation-only and wait for confirmed service mutations before changing grouping.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest, Codex app-server JSON-RPC, Node.js relay tests.

**Approved design:** `Docs/superpowers/specs/2026-08-10-native-codex-pins-design.md`

---

## Task workflow

1. Create one isolated implementation task with GPT-5.6 Luna at Max reasoning. Give it this plan, the approved design, repository instructions, acceptance criteria, verification commands, risks, and non-goals.
2. Keep all coding, shell commands, commits, and test execution in that implementation task. Do not delegate any step to a subagent.
3. After implementation and targeted verification, create a separate GPT-5.6 Sol task at High reasoning. Give it the approved design, this plan, the implementation commit range, the diff, and test evidence. Keep this review task read-only.
4. If Sol finds a verified issue, send the finding back to the Luna implementation task. Let Luna fix and verify it, then ask the same Sol review task to review the new diff.
5. Finish only after Sol explicitly approves. Then archive both tasks and remove only the task-owned worktree after confirming that all intended changes are committed.

## Task 1: Preserve section queries and metadata through the local relay

**Files:**
- Modify: `phodex-bridge/test/bridge.test.js`
- Modify: `phodex-bridge/src/bridge.js`

- [ ] **Step 1: Write the failing relay regression test**

Add a focused test that passes a `thread/list` result through the exported/supported relay sanitization path with request context:

```js
{
  sectionId: "pinned-section",
  sortKey: "section_position",
  cursor: null,
  limit: 100,
}
```

Use two server rows in a deliberate section order, each with:

```js
section: { id: "pinned-section", name: "Pinned", extra: "drop-me" },
sectionEnteredAt: 1_786_383_000,
```

Also create an unrelated local JSONL rollout candidate. Assert that the result keeps the two server rows in order, does not inject the rollout row, retains only `section.id` and `section.name`, and retains `sectionEnteredAt`.

- [ ] **Step 2: Run the focused Node test and confirm it fails**

Run from `phodex-bridge`:

```bash
rtk node --test --test-name-pattern="section-filtered thread/list" ./test/bridge.test.js
```

Expected: FAIL because request tracking drops section context, JSONL augmentation can add/reorder rows, and compaction drops section metadata.

- [ ] **Step 3: Implement the minimal relay fix**

In `rememberForwardedRequestMethod`, retain normalized `sectionId` and `sortKey` for `thread/list` requests in addition to cursor/limit/source kinds.

In `sanitizeThreadListForRelay`:

- detect a non-empty `sectionId`;
- skip local JSONL augmentation for section-filtered results;
- preserve the app-server result order.

Add `section` and `sectionEnteredAt` to `RELAY_THREAD_LIST_MOBILE_KEYS`. Compact `section` explicitly to bounded string `id` and `name` fields rather than passing arbitrary nested data. Preserve a valid numeric `sectionEnteredAt`.

- [ ] **Step 4: Run the focused test and confirm it passes**

```bash
rtk node --test --test-name-pattern="section-filtered thread/list" ./test/bridge.test.js
```

Expected: PASS.

- [ ] **Step 5: Commit the relay boundary**

```bash
rtk git add phodex-bridge/src/bridge.js phodex-bridge/test/bridge.test.js
rtk git commit -m "fix: preserve native pinned thread sections"
```

## Task 2: Decode native thread-section metadata

**Files:**
- Modify: `CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift`
- Modify: `CodexMobile/CodexMobile/Models/CodexThread.swift`

- [ ] **Step 1: Add a failing decode test**

Extend an existing thread-list decode fixture with:

```json
"section": { "id": "pinned-section", "name": "Pinned" },
"sectionEnteredAt": 1786383000
```

Assert the decoded thread exposes the section ID/name and the decoded date. Also assert a row without those keys decodes with both properties nil.

- [ ] **Step 2: Run only the new XCTest and confirm it fails**

```bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:CodexMobileTests/CodexServiceThreadListTests/testDecodeThreadSectionMetadata
```

Expected: FAIL to compile or assert because `CodexThread` has no section fields.

- [ ] **Step 3: Add the model fields**

Define a small `CodexThreadSection: Codable, Hashable, Sendable` containing `id` and `name`. Add optional `section` and `sectionEnteredAt` fields to `CodexThread`, its initializer, coding keys, custom decoder, and encoder. Reuse the model's existing date-decoding helper for wire compatibility.

- [ ] **Step 4: Rerun the targeted decode test**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit the model boundary**

```bash
rtk git add CodexMobile/CodexMobile/Models/CodexThread.swift CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift
rtk git commit -m "feat: decode Codex thread sections"
```

## Task 3: Build native pin lookup, cache, and legacy migration with TDD

**Files:**
- Modify: `CodexMobile/CodexMobileTests/CodexThreadRenamePersistenceTests.swift`
- Modify: `CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift`
- Modify: `CodexMobile/CodexMobile/Services/CodexService.swift`
- Modify: `CodexMobile/CodexMobile/Services/CodexService+MacContext.swift`
- Modify: `CodexMobile/CodexMobile/Services/CodexService+Helpers.swift`
- Create: `CodexMobile/CodexMobile/Services/CodexService+NativePins.swift`
- Modify if required by the project file layout: `CodexMobile/CodexMobile.xcodeproj/project.pbxproj`

- [ ] **Step 1: Replace local-pin persistence expectations with explicit native/legacy state tests**

Use fresh Mac-scoped defaults per test. Cover:

- old `codex.pinnedThreadIDs` and snapshot keys load as the retained legacy migration queue;
- new native cache keys load as the last confirmed native IDs/snapshots;
- effective displayed IDs are a stable deduplicated `legacy order + native order` while legacy data remains;
- clearing completed legacy storage leaves only native cache state after reload;
- reset/Mac switching does not blend caches between Macs.

Do not test or retain synchronous `pinThread`/`unpinThread` as writable local APIs.

- [ ] **Step 2: Add failing RPC-state-machine tests using `requestTransportOverride`**

Add small JSON-RPC fixture helpers and cover these request/result sequences:

1. `threadSection/list` finds `Pinned`, then paginated `thread/list` requests include `sectionId`, `sortKey: section_position`, and all user-facing `sourceKinds`; returned IDs preserve page/native order. A compatibility case verifies the existing legacy source-kind fallback retains the section filter and ordering.
2. Successful lookup with no Pinned section and no migration clears stale native cache without calling `threadSection/create`.
3. Migration with no Pinned section creates it, refreshes, computes legacy-only IDs, sends `thread/section/move` in reverse legacy order using the current first native ID as `beforeThreadId`, refreshes, and clears legacy data only after all IDs are confirmed.
4. Partial migration failure keeps all legacy IDs/snapshots and the effective deduplicated union.
5. Retry re-reads native state and moves only still-missing IDs.
6. Unsupported method/parameter errors retain the last confirmed cache and classify the runtime as requiring a Codex update.

- [ ] **Step 3: Run only the new persistence and service tests and confirm failure**

```bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:CodexMobileTests/CodexThreadRenamePersistenceTests/testLegacyPinsLoadAsMigrationUnion \
  -only-testing:CodexMobileTests/CodexThreadRenamePersistenceTests/testCompletedMigrationClearsLegacyStorage \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testNativePinnedThreadsPreserveSectionOrder \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testMissingSectionClearsStaleNativeCacheWithoutCreation \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testLegacyPinMigrationIsOrderedAndIdempotent \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testPartialLegacyPinMigrationRetainsUnion \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testUnsupportedNativePinsRetainConfirmedCache
```

Expected: FAIL because the native state machine and cache split do not exist.

- [ ] **Step 4: Introduce explicit pin state without creating a second writable source**

In `CodexService.swift`, keep `pinnedThreadIDs` as the observable effective display order used by grouping. Add internal state for:

- confirmed native ordered IDs and snapshots;
- retained legacy ordered IDs and snapshots;
- resolved Pinned section ID;
- unsupported/available capability state;
- one serialized pin-operation task/actor boundary.

Retain the old defaults keys solely as migration input. Add new Mac-scoped native-cache keys. In `CodexService+MacContext.swift`, load/reset/migrate both stores independently, then rebuild the effective union. Persist only response- or refresh-confirmed native state to the new keys; remove legacy keys only after confirmed migration completion.

- [ ] **Step 5: Implement the focused native-pin service**

In `CodexService+NativePins.swift`, implement single-responsibility helpers for:

- paginating `threadSection/list` and exact-name resolution of `Pinned`;
- lazily calling `threadSection/create` only for migration or Pin;
- paginating `thread/list` with `sectionId`, `section_position`, and the same explicit all-user-facing `sourceKinds` policy as normal thread hydration until `nextCursor` is nil; do not rely on Codex's narrower default;
- retrying with the existing legacy source-kind set when an older runtime rejects expanded subagent kinds, while keeping the section filter and section ordering on the retry;
- atomically replacing confirmed native cache only after a complete successful fetch;
- rebuilding effective IDs/snapshots as deduplicated legacy-first/native-second during migration;
- reverse-order, missing-only, idempotent legacy migration;
- classifying method-not-found/incompatible-parameter responses without destroying confirmed state.

Keep JSON parsing and RPC parameter construction in this service layer. Remove the old synchronous local mutations from `CodexService+Helpers.swift`, retaining only grouping/snapshot helpers that operate on effective confirmed state.

- [ ] **Step 6: Run the targeted native-state tests**

Run the command from Step 3.

Expected: PASS.

- [ ] **Step 7: Commit the service foundation**

```bash
rtk git add CodexMobile/CodexMobile/Services CodexMobile/CodexMobileTests/CodexThreadRenamePersistenceTests.swift CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift CodexMobile/CodexMobile.xcodeproj/project.pbxproj
rtk git commit -m "feat: synchronize native Codex pin state"
```

If the Xcode group discovers Swift files automatically and `project.pbxproj` is unchanged, omit it from `git add`.

## Task 4: Add serialized Pin/Unpin mutations and thread-refresh integration

**Files:**
- Modify: `CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift`
- Modify: `CodexMobile/CodexMobile/Services/CodexService+NativePins.swift`
- Modify: `CodexMobile/CodexMobile/Services/CodexService+ThreadsTurns.swift`
- Modify: `CodexMobile/CodexMobile/Services/CodexService+Sync.swift`
- Modify: `CodexMobile/CodexMobile/Views/SidebarView.swift`

- [ ] **Step 1: Add failing mutation and refresh tests**

Using an actor-backed request recorder so assertions are concurrency-safe, test:

- Pin resolves/creates the section as needed and moves the root before the current first native pin;
- Unpin sends a null `sectionId` and omits `beforeThreadId`;
- no visible/cache mutation occurs before the move response succeeds;
- failed/timeout mutation leaves confirmed grouping unchanged;
- Pin/Unpin waits for migration and fails if migration remains incomplete;
- rapid mutations are serialized in invocation order;
- a native refresh started before a move cannot complete afterward and overwrite the move-confirmed cache with stale state;
- after a successful move, deterministic confirmed cache mutation is applied immediately;
- if the subsequent full refresh fails, the confirmed mutation remains visible/persisted and only background sync error state is reported;
- dedicated pinned rows absent from the normal recent-thread page are merged into hydration before reconciliation.

- [ ] **Step 2: Run only those new tests and confirm failure**

```bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testPinMovesRootBeforeCurrentFirstPin \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testUnpinMovesRootToNullSection \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testPinWaitsForLegacyMigration \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testPinsDoNotChangeBeforeMoveConfirmation \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testMutationFailureLeavesConfirmedPinsUnchanged \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testUnsupportedMutationRequestsCodexUpdate \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testSuccessfulMutationSurvivesFailedRefresh \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testPinMutationsAreSerialized \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testStaleRefreshCannotOverwriteConfirmedMutation \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testPinnedHydrationMergesRowsOutsideRecentPage
```

Expected: FAIL because mutations and native hydration are not connected.

- [ ] **Step 3: Implement the async mutation API**

Expose one async service API such as:

```swift
func setThreadPinned(_ threadID: String, pinned: Bool) async throws
```

Resolve the root ID, reject archived/subagent direct pinning, serialize against migration, native refreshes, and other mutations, and call `thread/section/move`. For Pin, send the resolved section ID and current first native root as `beforeThreadId`; for Unpin, send JSON null for `sectionId` and omit `beforeThreadId`.

After a successful response, update and persist the confirmed native IDs/snapshots deterministically, rebuild the effective view, then attempt a complete native refresh. Treat a failed post-success refresh as background reconciliation trouble, not mutation failure. Map unsupported protocol errors to the existing user-visible error route with an explicit “Update Codex to synchronize pins” message.

- [ ] **Step 4: Integrate native pin refresh into every existing full thread refresh path**

Have both reconnect/background synchronization in `CodexService+Sync.swift` and pull/full list hydration in `CodexService+ThreadsTurns.swift` invoke the shared native pin refresh/migration operation. Route every native pin refresh through the same serialization boundary as migration and mutations (or attach a monotonic generation token and discard an obsolete completion) so an older refresh can never replace a newer move-confirmed cache. Merge dedicated pinned rows into the normal server thread collection before reconciliation so old pins outside recent pagination remain available.

On refresh failure, preserve confirmed native cache/snapshots and continue normal thread reconciliation. When local archive/remove bookkeeping currently calls `unpinThread`, replace it with internal displayed-snapshot pruning only; “Remove from Phone” must not mutate Codex's native section.

- [ ] **Step 5: Wire the sidebar menu to confirmed async mutations**

In `SidebarView.swift`, replace synchronous `pinThread`/`unpinThread` calls and immediate manual regrouping with a `Task` calling `setThreadPinned`. Let observed `pinnedThreadIDs` changes rebuild grouping only after confirmation. Route errors through the existing connection/error presentation without reporting a successful move as failed solely because its follow-up refresh failed.

- [ ] **Step 6: Rerun the mutation/hydration tests**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 7: Commit the integration**

```bash
rtk git add CodexMobile/CodexMobile/Services CodexMobile/CodexMobile/Views/SidebarView.swift CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift
rtk git commit -m "feat: write pin changes back to Codex"
```

## Task 5: Render one flat Pinned list above Projects

**Files:**
- Modify: `CodexMobile/CodexMobileTests/SidebarThreadGroupingTests.swift`
- Modify: `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadGrouping.swift`
- Modify: `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadListView.swift`
- Modify: `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadRowView.swift`
- Modify: `CodexMobile/CodexMobile/Views/Sidebar/SidebarPinIcon.swift`

- [ ] **Step 1: Strengthen grouping tests around the approved hierarchy**

Add/adjust tests asserting:

- the Pinned group is first and preserves the supplied native root order;
- every pinned root appears exactly once;
- pinned roots and their visible descendants are absent from all project groups;
- descendants remain nested under their pinned root but are not treated as pinned roots;
- archived roots do not render in Pinned;
- an empty pin list omits the Pinned group.

- [ ] **Step 2: Run the focused grouping tests**

```bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:CodexMobileTests/SidebarThreadGroupingTests
```

Expected: existing coverage may partly pass; the stricter exact-once/native-order assertions must fail if grouping regresses.

- [ ] **Step 3: Keep grouping flat and remove project decoration from pinned rows**

Make the smallest grouping changes required to retain the native root order and exclude each pinned subtree from projects. In `SidebarThreadListView`, do not compute or render `pinnedProjectLabel`, a folder, or project hierarchy for pinned rows. Preserve expansion for nested subagent descendants.

- [ ] **Step 4: Render the filled pin only for pinned roots**

In `SidebarThreadRowView`, show the row badge only when `isPinned && !thread.isSubagent`. Implement `SidebarPinIcon.rowBadge` with the real SwiftUI `Image(systemName: "pin.fill")`, 18-point sizing, and project-folder-equivalent visual weight. Keep the existing outlined/custom icon behavior for unrelated header/menu uses.

Mark the icon decorative with `.accessibilityHidden(true)` and expose `Pinned` through the row's accessibility value/label. Unpinned roots and descendants receive neither the icon nor the pinned accessibility value.

- [ ] **Step 5: Rerun the focused grouping tests and targeted build tests**

```bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:CodexMobileTests/SidebarThreadGroupingTests \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testSuccessfulMutationSurvivesFailedRefresh
```

Expected: PASS, including compilation of the changed SwiftUI rows.

- [ ] **Step 6: Commit the presentation**

```bash
rtk git add CodexMobile/CodexMobile/Views/Sidebar CodexMobile/CodexMobileTests/SidebarThreadGroupingTests.swift
rtk git commit -m "feat: show native pins above projects"
```

## Task 6: Targeted verification and review

**Files:**
- Review all files changed by Tasks 1–5.

- [ ] **Step 1: Run the focused relay regression**

```bash
cd phodex-bridge
rtk node --test --test-name-pattern="section-filtered thread/list" ./test/bridge.test.js
cd ..
```

Expected: PASS.

- [ ] **Step 2: Run only the user-approved pin-related Xcode tests**

```bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests \
  -only-testing:CodexMobileTests/CodexThreadRenamePersistenceTests \
  -only-testing:CodexMobileTests/SidebarThreadGroupingTests
```

Expected: PASS. Do not broaden this to the full Xcode suite or a simulator UI run.

- [ ] **Step 3: Inspect the final diff against the invariants**

```bash
rtk git status --short
rtk git diff --check
rtk git diff --stat HEAD~5..HEAD
```

Confirm manually from the diff:

- no local-only writable pin API remains;
- native order is never activity-sorted or JSONL-augmented;
- cache replacement happens only on full refresh success or confirmed move response;
- partial migration retains all legacy data;
- pinned roots render only once above Projects with filled root-only icons;
- no selected-repository filtering or hosted-service assumptions were introduced.

- [ ] **Step 4: Request an independent Sol High implementation review**

Create a separate read-only Codex task using GPT-5.6 Sol with High reasoning. Provide the approved spec, this plan, the implementation commit range, final diff, and exact test evidence. Ask it to verify spec alignment, migration safety, refresh/mutation ordering, relay ordering, UI hierarchy, and remaining risks.

If it finds a verified issue, send the finding to the GPT-5.6 Luna Max implementation task. Let Luna make the fix and run the smallest affected tests. Return the updated diff and evidence to the same Sol review task. Do not use subagents at any point.

- [ ] **Step 5: Record final evidence**

Report the exact targeted commands and their pass/fail results, remaining compatibility risk around experimental Codex section APIs, and the final commit range. Do not claim full-suite coverage.
