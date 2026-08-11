# Codex Host Pin Compatibility Implementation Plan

> **Execution rule:** Do not use subagents. Execute the tasks inline in the isolated worktree. Steps use checkbox (`- [ ]`) syntax for tracking. Do not run a full test suite or simulator UI automation.

**Goal:** Show Codex Desktop's ordered host pins when the app-server Pinned section is empty or unavailable, then permanently prefer the supported native app-server source after a complete native result proves it authoritative.

**Architecture:** Add one narrow, read-only `bridge/hostPins/read` RPC that validates and atomically reads only `$CODEX_HOME/.codex-global-state.json` → `pinned-thread-ids`. Extend the existing serialized native-pin coordinator with Mac-scoped host cache and an authority latch. While authority is undecided, a complete non-empty native result or an empty-to-empty confirmation latches native authority; a complete empty native result contradicted by valid host IDs activates a read-only host fallback. Host rows missing from normal hydration are fetched with authoritative app-server `thread/read`, never from JSONL.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest, Codex app-server JSON-RPC, Node.js `node:test`, local Mac bridge filesystem APIs.

**Approved design:** `Docs/superpowers/specs/2026-08-11-codex-host-pins-compatibility-design.md`

---

## Scope and baseline

The current branch already contains the original native-pin implementation and its approved follow-up corrections. Preserve those commits and their boundaries. Do not rewrite or squash them:

| Existing boundary | Commit | Keep unchanged unless this plan names a correction |
| --- | --- | --- |
| Relay section filtering and metadata | `7d5e2f6` `fix: preserve native pinned thread sections` | Keep section order, bounded section metadata, and the no-JSONL rule for section-filtered lists |
| Thread section model | `8a2765a` `feat: decode Codex thread sections` | Keep optional `CodexThreadSection` and `sectionEnteredAt` decoding |
| Native lookup/cache | `31fb993` `feat: synchronize native Codex pin state` | Keep complete-page replacement and confirmed-cache behavior |
| Native Pin/Unpin mutation | `619a47c` `feat: write pin changes back to Codex` | Keep serialized confirmed-response mutation behavior when native authority is active |
| Sidebar presentation | `53cada8` `feat: show native pins above projects` | Keep the flat leading section, root-only icon, and project exclusion boundary |
| Hydration coalescing | `26a8f3f` `fix: coalesce native pin hydration` | Keep one shared hydration path for full and capped refreshes |
| Legacy iOS discard | `bd59eb5` `fix: discard legacy iOS pins` | Complete the discard at coalesced Mac-device migration; never restore the old queue |
| Native order | `f102eac` `fix: preserve native Codex pin order` | Keep ascending `section_position` and response/page order |
| Fixture repair | `7b5ac06` `test: repair stale iOS test fixtures` | Keep the current focused test baseline |

The correction starts at current local `main`. It does not add hosted-service assumptions, remote domains, selected-repository filtering, or a general file reader.

## File map

| File | Responsibility in this correction |
| --- | --- |
| `phodex-bridge/src/host-pins-handler.js` | Validate and atomically read the one host pin field; never write or expose arbitrary files |
| `phodex-bridge/src/bridge.js` | Route `bridge/hostPins/read` and keep authoritative `thread/read` metadata free of JSONL augmentation |
| `phodex-bridge/test/bridge.test.js` | Extend the already-approved focused relay test file with host-read and authoritative-read cases; do not add a broad bridge test command |
| `CodexMobile/CodexMobile/Services/CodexService.swift` | Add observable/effective pin state, host cache state, authority state, and Mac-scoped key constants |
| `CodexMobile/CodexMobile/Services/CodexService+MacContext.swift` | Load, persist, migrate, and discard pin state without reviving legacy iOS keys |
| `CodexMobile/CodexMobile/Services/CodexService+NativePins.swift` | Own native probing, host compatibility probing, authority decisions, hydration, cache replacement, and mutation gating |
| `CodexMobile/CodexMobile/Services/CodexService+ThreadsTurns.swift` | Change only the shared host-row `thread/read` hydration integration if the existing service extension boundary requires it |
| `CodexMobile/CodexMobile/Services/CodexService+Sync.swift` | Preserve the existing calls into the shared pin hydration path; change only if a stale-generation guard needs to cover reconnect sync |
| `CodexMobile/CodexMobile/Views/SidebarView.swift` | Pass the pin mutation availability state into the sidebar action surface |
| `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadListView.swift` | Thread the disabled Pin/Unpin reason through the existing row tree without changing grouping |
| `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadRowView.swift` | Keep the current root-only badge and provide the disabled mutation reason to the context menu |
| `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadContextMenu.swift` | Render a clear disabled Pin/Unpin entry while host compatibility is active |
| `CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift` | TDD coverage for authority, bridge RPC decoding, native source-kind compatibility, hydration, stale-state retention, and mutation gating |
| `CodexMobile/CodexMobileTests/CodexThreadRenamePersistenceTests.swift` | TDD coverage for Mac-scoped host/native caches and legacy-key discard |
| `CodexMobile/CodexMobileTests/SidebarThreadGroupingTests.swift` | Preserve exact host/native order, root/descendant exclusion, and existing icon-facing grouping invariants |
| `CodexMobile/CodexMobileTests/CodexTrustedMacSelectionTests.swift` | Update the existing coalesced-device legacy-pin expectation if it still asserts migration of old iOS pin keys; this file is not added to the approved execution command |

The Xcode project uses a synchronized source group. Do not edit `project.pbxproj` unless the build proves that the new Swift file is not picked up automatically.

## Test policy

Use TDD for every behavior change: add the smallest failing test, run the exact focused command and record the expected failure, implement the smallest change, then rerun the same command for green. All shell commands use `rtk`.

The only permitted relay verification is the existing targeted test in `phodex-bridge/test/bridge.test.js`, extended with narrow host-pin cases in that same file. Do not run `rtk npm test` or the full Node test directory.

The only permitted Xcode verification surfaces are:

- `CodexServiceThreadListTests`;
- `CodexThreadRenamePersistenceTests`; and
- `SidebarThreadGroupingTests`.

Do not run the full Xcode suite, `CodexTrustedMacSelectionTests` as a separate suite, simulator UI automation, RocketSim, or a manual UI run. The Xcode commands below use the existing project-specific source exclusions from the native-pin plan when needed; they still run only the three approved suites or the named tests inside them.

## Task 1: Add the narrow read-only bridge boundary

**Files:**

- Create: `phodex-bridge/src/host-pins-handler.js`
- Modify: `phodex-bridge/src/bridge.js`
- Modify: `phodex-bridge/test/bridge.test.js`

- [ ] **Step 1: Add the failing host-read tests in the approved relay test file.**

Import the handler into `bridge.test.js` and add focused tests with injected temporary `CODEX_HOME`/filesystem dependencies:

1. `handleHostPinsRequest returns only ordered pinned IDs and never writes` writes a global-state object containing `"pinned-thread-ids": ["thread-a", "thread-b"]` plus unrelated keys, sends an empty params object, and asserts the response contains only schema version, source, and the exact ordered IDs. Track every filesystem write method and assert that none is called.
2. `handleHostPinsRequest rejects arbitrary path input` sends params containing a path injection and asserts `host_pins_malformed`; the handler must not read the requested path or return any file content.
3. `handleHostPinsRequest rejects malformed or racing global state without partial IDs` covers a missing key, an invalid ID, an oversized payload, and a file whose before/after metadata changes on both bounded read attempts. Each case must return the stable bridge error code and no partial array.
4. `sanitizeThreadHistoryImagesForRelay keeps authoritative thread/read metadata` creates a `thread/read` request with `includeTurns: false` and a conflicting JSONL cwd, then asserts that the app-server thread metadata is not replaced by JSONL augmentation. Keep the existing approved test `sanitizeThreadHistoryImagesForRelay preserves section-filtered thread/list order and metadata` unchanged and passing.

- [ ] **Step 2: Run the relay tests to prove RED.**

From `phodex-bridge` run:

~~~bash
rtk node --test --test-name-pattern="handleHostPinsRequest|authoritative thread/read|sanitizeThreadHistoryImagesForRelay preserves section-filtered thread/list order and metadata" ./test/bridge.test.js
~~~

Expected: the new host-handler import or cases fail because the RPC boundary and authoritative-read context do not exist. The existing section-filtered test may remain green; the command is still RED overall.

- [ ] **Step 3: Implement the bounded host-pin handler.**

In `host-pins-handler.js`:

Use fixed bounds of 1 MiB (1,048,576 UTF-8 bytes), 512 IDs, and 256
characters per ID. The initial read plus one retry are the only two allowed
file-read attempts.

- accept only `bridge/hostPins/read`;
- require absent, `null`, or empty-object params;
- resolve `path.join(resolveCodexHome(), ".codex-global-state.json")` internally;
- use a bounded open/stat/read/stat/close cycle with one retry when file identity, size, or timestamps change;
- cap the file size and ID count;
- require an object containing the exact `pinned-thread-ids` array;
- require unique IDs matching the existing safe thread-ID pattern and length limit;
- treat an empty array as valid and all malformed/partial arrays as errors; and
- return `{ schemaVersion: 1, source: "codex-host", pinnedThreadIds }` without paths, metadata, unrelated keys, or raw errors.

Use injected `fsModule`, `codexHome`, and retry/stat dependencies only for tests. Do not add a write dependency. Map missing/unreadable, malformed, and unstable reads to `host_pins_unavailable`, `host_pins_malformed`, and `host_pins_racing`. Keep error messages free of paths and IDs.

- [ ] **Step 4: Route the handler before generic app-server forwarding.**

In `bridge.js`, require the handler and invoke it in `handleApplicationMessage` before `forwardInboundRequestToCodex`. A bridge that does not know the method must return the existing method-not-found behavior; it must not forward a host-file request to Codex as an arbitrary app-server method.

Extend `rememberForwardedRequestMethod` with the minimum `thread/read` `includeTurns` context needed by the sanitizer. For `thread/read` with `includeTurns: false`, skip JSONL cwd/history augmentation while retaining normal bounded relay compaction. This keeps host hydration authoritative without changing the host RPC boundary.

- [ ] **Step 5: Run the same relay command to prove GREEN.**

~~~bash
rtk node --test --test-name-pattern="handleHostPinsRequest|authoritative thread/read|sanitizeThreadHistoryImagesForRelay preserves section-filtered thread/list order and metadata" ./test/bridge.test.js
~~~

Expected: all matched tests pass. Do not run other Node tests.

- [ ] **Step 6: Commit the bridge boundary.**

~~~bash
rtk git add phodex-bridge/src/host-pins-handler.js phodex-bridge/src/bridge.js phodex-bridge/test/bridge.test.js
rtk git commit -m "fix: add read-only Codex host pin bridge"
~~~

## Task 2: Add Mac-scoped source state and finish legacy discard

**Files:**

- Modify: `CodexMobile/CodexMobile/Services/CodexService.swift`
- Modify: `CodexMobile/CodexMobile/Services/CodexService+MacContext.swift`
- Modify: `CodexMobile/CodexMobileTests/CodexThreadRenamePersistenceTests.swift`
- Modify if required by the existing expectation: `CodexMobile/CodexMobileTests/CodexTrustedMacSelectionTests.swift`

- [ ] **Step 1: Add failing persistence tests.**

Add these cases to the approved `CodexThreadRenamePersistenceTests` suite:

- `testHostCompatibilityStateIsMacScopedAndReloadsInOrder`: seed host IDs, host snapshots, native IDs, and authority for two Mac IDs; reload each scope; assert no cross-Mac mixing and exact order.
- `testNativeAuthorityDropsHostCacheOnReload`: seed both caches with native authority; load the scope; assert effective IDs are native and host keys are deleted or ignored.
- `testLegacyPinsAreDiscardedDuringCoalescedMacMigration`: seed old `codex.pinnedThreadIDs`/snapshot keys on a stale Mac ID, coalesce that Mac into a fresh ID, and assert the old keys are deleted rather than merged. Keep confirmed native/host state that was stored under the new keys.
- `testUndecidedStateUsesLastConfirmedNativeCacheUntilProbe`: seed the current native cache without an authority marker and assert it is the first-paint effective state while the live authority decision is still pending.

If `CodexTrustedMacSelectionTests.testTrustMacMigratesPinnedDefaultsFromCoalescedMacId` still asserts that old iOS pins are copied, replace that expectation with the discard behavior. Do not add that suite to the approved execution command.

- [ ] **Step 2: Run the persistence tests to prove RED.**

~~~bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  'EXCLUDED_SOURCE_FILE_NAMES=TurnTimelineReducerTests.swift CodexThreadStartProjectBindingTests.swift' \
  test \
  -only-testing:CodexMobileTests/CodexThreadRenamePersistenceTests/testHostCompatibilityStateIsMacScopedAndReloadsInOrder \
  -only-testing:CodexMobileTests/CodexThreadRenamePersistenceTests/testNativeAuthorityDropsHostCacheOnReload \
  -only-testing:CodexMobileTests/CodexThreadRenamePersistenceTests/testLegacyPinsAreDiscardedDuringCoalescedMacMigration \
  -only-testing:CodexMobileTests/CodexThreadRenamePersistenceTests/testUndecidedStateUsesLastConfirmedNativeCacheUntilProbe
~~~

Expected: RED because host state, authority, and the coalesced legacy discard boundary are not implemented.

- [ ] **Step 3: Add explicit state and keys.**

In `CodexService.swift`, add:

~~~swift
enum CodexPinnedStateAuthority: String, Codable, Equatable {
    case undecided
    case hostCompatibility
    case native
}

var confirmedHostPinnedThreadIDs: [String] = []
@ObservationIgnored var confirmedHostPinnedThreadSnapshotsByRootID: [String: [CodexThread]] = [:]
@ObservationIgnored var pinnedStateAuthority: CodexPinnedStateAuthority = .undecided

static let hostPinnedThreadIDsDefaultsKey = "codex.hostPinnedThreadIDs"
static let hostPinnedThreadSnapshotsDefaultsKey = "codex.hostPinnedThreadSnapshots"
static let pinnedStateAuthorityDefaultsKey = "codex.pinnedStateAuthority"
~~~

Keep `pinnedThreadIDs` as the observable effective order and keep the existing native cache keys. Add one computed mutation reason that returns exactly `Update Codex to synchronize pins.` for host compatibility or unavailable native mutation capability.

- [ ] **Step 4: Make load/reset/migration source-aware.**

In `CodexService+MacContext.swift`:

- load and validate the new host IDs, host snapshots, native IDs, native snapshots, and authority under the selected Mac ID;
- rebuild the effective view from native when authority is `native`, from host when it is `hostCompatibility`, and from the current confirmed native cache when authority is `undecided`;
- clear host cache when native authority is loaded;
- clear all new fields on in-memory Mac reset;
- migrate the new cache dictionaries and authority with the same Mac-device coalescing flow; target native authority wins over undecided/host state; and
- replace generic old-pin migration with deletion for both old iOS keys. Never copy or merge `codex.pinnedThreadIDs` or `codex.pinnedThreadSnapshots`, either from unscoped defaults or from a stale Mac ID.

Persist source state in a deterministic order: write the confirmed cache first, write the authority marker last, and clear the obsolete source cache only after the new confirmed state is durable. This is a crash-safe ordering choice, not a new database abstraction.

- [ ] **Step 5: Run the same persistence command to prove GREEN.**

Use the command from Step 2. Expected: all four named tests pass. Do not run `CodexTrustedMacSelectionTests` separately.

- [ ] **Step 6: Commit the state boundary.**

~~~bash
rtk git add CodexMobile/CodexMobile/Services/CodexService.swift CodexMobile/CodexMobile/Services/CodexService+MacContext.swift CodexMobile/CodexMobileTests/CodexThreadRenamePersistenceTests.swift CodexMobile/CodexMobileTests/CodexTrustedMacSelectionTests.swift
rtk git commit -m "fix: scope Codex pin compatibility state"
~~~

If the trusted-Mac test did not need an expectation change, omit it from `git add`.

## Task 3: Implement the authority decision and host fallback

**Files:**

- Modify: `CodexMobile/CodexMobile/Services/CodexService+NativePins.swift`
- Modify: `CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift`

- [ ] **Step 1: Add failing authority and fallback tests.**

Use `requestTransportOverride` and small response helpers. Add or update these tests in `CodexServiceThreadListTests`:

- `testHostFallbackPreservesHostOrderWhenNativePinnedSectionIsEmpty`: return a valid host response with `host-a`, `host-b`, and an empty complete native `Pinned` response; assert effective order is exactly `host-a`, `host-b`, the authority is `hostCompatibility`, and no create/move request occurs.
- `testNativeAuthorityRequiresCompleteNativeEvidence`: return a partial native page, a malformed page, or a missing section and assert the service does not latch native or clear a confirmed source. Return a complete non-empty native result and assert it latches native.
- `testNativeAuthorityIgnoresStaleHostAfterLatch`: first latch native, then make the host response contain old IDs and make native return an empty complete section; assert the effective native cache becomes empty and host IDs never return.
- `testEmptyNativeAndEmptyHostLatchesNative`: return complete empty results from both sources and assert native authority is recorded.
- `testMissingMalformedRacingAndOfflineHostReadsRetainConfirmedState`: seed a host cache, then exercise bridge unavailable, malformed payload, racing error, and disconnected errors; assert IDs and order remain unchanged.
- `testNativePinnedThreadListRetainsAllSourceKindsAndAscendingOrderOnRetry`: keep the current native-order assertion and require the modern ten-source list, the legacy five-source retry, `sectionId`, `sortKey`, `sortDirection`, and cursor on every page.

- [ ] **Step 2: Run the authority tests to prove RED.**

~~~bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  'EXCLUDED_SOURCE_FILE_NAMES=TurnTimelineReducerTests.swift CodexThreadStartProjectBindingTests.swift' \
  test \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testHostFallbackPreservesHostOrderWhenNativePinnedSectionIsEmpty \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testNativeAuthorityRequiresCompleteNativeEvidence \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testNativeAuthorityIgnoresStaleHostAfterLatch \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testEmptyNativeAndEmptyHostLatchesNative \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testMissingMalformedRacingAndOfflineHostReadsRetainConfirmedState \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testNativePinnedThreadListRetainsAllSourceKindsAndAscendingOrderOnRetry
~~~

Expected: RED because the service has no host RPC reader or authority predicate and currently clears native state for an empty section.

- [ ] **Step 3: Add a pure authority decision.**

Keep the decision independent of transport and persistence. Its inputs must distinguish `complete(ids)`, `missingSection`, `unsupported`, `malformed`, and `incomplete` native results from `valid(ids)`, `unavailable`, `malformed`, and `racing` host results. Implement the exact table in the design:

~~~text
complete native with IDs                  -> native
complete native empty + valid empty host -> native
complete native empty + valid nonempty host -> hostCompatibility
native missing/unsupported + valid host  -> hostCompatibility
any host failure                         -> keep current confirmed authority
~~~

Do not treat a method-not-found from `bridge/hostPins/read` as an app-server native failure. Host RPC errors are compatibility-source failures and retain the current source.

- [ ] **Step 4: Read and validate the host RPC.**

Add a `sendRequest` call for `bridge/hostPins/read` with an empty object. Decode `schemaVersion`, `source`, and `pinnedThreadIds`; require the expected source and an ordered bounded string array. Map the bridge error codes and disconnected errors to a host-read result without placing IDs or paths in logs. A valid empty array is a confirmed result; a missing key is malformed.

- [ ] **Step 5: Refactor native synchronization around the decision.**

Keep the existing native request construction exactly compatible:

~~~swift
[
    "sectionId": .string(sectionID),
    "sortKey": .string("section_position"),
    "sortDirection": .string("asc"),
    "sourceKinds": .array(sourceKinds.map(JSONValue.string)),
    "cursor": cursor,
    "limit": .integer(100),
]
~~~

Run the native probe to completion before committing any new cache. While authority is not `native`, collect the host result needed by the decision. When the predicate selects native, write the complete native cache, latch native, clear host cache, and rebuild the effective state. When it selects host, write the exact host ID order, set `hostCompatibility`, and leave native cache intact for future authority probing. On all incomplete/error results, preserve the currently active cache.

Keep `nativePinOperationGate` around the full probe-and-commit operation. If existing refresh paths can outlive the gate, add a monotonic pin-state generation and discard a completion that is older than the last committed generation. A late host read must never overwrite a later native commit.

- [ ] **Step 6: Run the same authority command to prove GREEN.**

Use the command from Step 2. Expected: all named authority and native-order tests pass.

- [ ] **Step 7: Commit authority selection.**

~~~bash
rtk git add CodexMobile/CodexMobile/Services/CodexService+NativePins.swift CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift
rtk git commit -m "fix: add Codex host pin authority fallback"
~~~

## Task 4: Hydrate missing host rows through authoritative `thread/read`

**Files:**

- Modify: `CodexMobile/CodexMobile/Services/CodexService+NativePins.swift`
- Modify only if needed at the existing call boundary: `CodexMobile/CodexMobile/Services/CodexService+ThreadsTurns.swift`
- Modify only if needed at the existing reconnect call boundary: `CodexMobile/CodexMobile/Services/CodexService+Sync.swift`
- Modify: `CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift`

- [ ] **Step 1: Add failing hydration tests.**

Add these cases:

- `testHostFallbackHydratesMissingRowsThroughThreadRead`: native section is empty, host returns two IDs, the normal `thread/list` returns neither, and `thread/read` returns both rows. Assert the service's merged threads contain both rows in the host order and no JSONL marker or section mutation request is involved.
- `testHostHydrationPreservesOrderWhenThreadReadsCompleteOutOfOrder`: suspend the second `thread/read` until after the first response; assert the effective IDs and Pinned group input remain host order, not completion order.
- `testFailedHostRowReadKeepsPriorSnapshotAndRetriesLater`: seed one host row, make its read fail, assert the prior row remains; then return a new authoritative row on the next refresh and assert the snapshot updates.
- `testHostHydrationUsesThreadReadWithoutJSONLFallback`: assert the request is `{ "threadId": id, "includeTurns": false }` and that the service never calls a rollout or local-list fallback to manufacture the row.

- [ ] **Step 2: Run the hydration tests to prove RED.**

~~~bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  'EXCLUDED_SOURCE_FILE_NAMES=TurnTimelineReducerTests.swift CodexThreadStartProjectBindingTests.swift' \
  test \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testHostFallbackHydratesMissingRowsThroughThreadRead \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testHostHydrationPreservesOrderWhenThreadReadsCompleteOutOfOrder \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testFailedHostRowReadKeepsPriorSnapshotAndRetriesLater \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testHostHydrationUsesThreadReadWithoutJSONLFallback
~~~

Expected: RED because host fallback currently returns no rows when the app-server section is empty and no thread-read hydration exists.

- [ ] **Step 3: Implement bounded ordered hydration.**

Keep `refreshNativePinsForThreadHydration()` as the shared entry point used by both `listThreads` and reconnect/background sync. For active host IDs:

1. use the current live row or confirmed host snapshot when present;
2. issue `thread/read` only for missing rows, with `includeTurns: false`;
3. retry the existing snake-case spelling only for a matching compatibility error;
4. decode only `result.thread` and require the returned ID to equal the request;
5. store results by requested ID, then flatten by the original host ID array; and
6. retain the ID and prior snapshot on a per-row failure, without inventing a placeholder from JSONL.

Use a bounded task group if concurrency is needed, but make the final flattening order explicit. Do not allow task completion order to define the sidebar order.

Merge returned root metadata into the normal thread collection before `reconcileLocalThreadsWithServer`. Let the existing grouping code discover and nest descendants from the complete available thread set. Do not add a second project-exclusion algorithm.

- [ ] **Step 4: Run the hydration command to prove GREEN.**

Use the command from Step 2. Expected: all four named hydration tests pass.

- [ ] **Step 5: Commit the hydration boundary.**

~~~bash
rtk git add CodexMobile/CodexMobile/Services/CodexService+NativePins.swift CodexMobile/CodexMobile/Services/CodexService+ThreadsTurns.swift CodexMobile/CodexMobile/Services/CodexService+Sync.swift CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift
rtk git commit -m "fix: hydrate Codex host pins through thread read"
~~~

If either integration file is unchanged, omit it from `git add`.

## Task 5: Disable Pin/Unpin in the read-only fallback

**Files:**

- Modify: `CodexMobile/CodexMobile/Services/CodexService+NativePins.swift`
- Modify: `CodexMobile/CodexMobile/Views/SidebarView.swift`
- Modify: `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadListView.swift`
- Modify: `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadRowView.swift`
- Modify: `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadContextMenu.swift`
- Modify: `CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift`

- [ ] **Step 1: Add failing mutation-gating tests.**

Add:

- `testHostFallbackRejectsPinWithoutCreatingOrMovingSection`: seed active host compatibility, invoke `setThreadPinned`, assert the exact update error and assert no `threadSection/create` or `thread/section/move` request.
- `testHostFallbackRejectsUnpinWithoutChangingConfirmedOrder`: seed host IDs, invoke Unpin, assert the same error and unchanged order.
- `testNativeAuthorityKeepsExistingPinMutationContract`: retain the current Pin/Unpin tests for section creation, `beforeThreadId`, null unpin section, confirmation-before-display, serialized mutations, and failed-refresh retention.

- [ ] **Step 2: Run the mutation tests to prove RED.**

~~~bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  'EXCLUDED_SOURCE_FILE_NAMES=TurnTimelineReducerTests.swift CodexThreadStartProjectBindingTests.swift' \
  test \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testHostFallbackRejectsPinWithoutCreatingOrMovingSection \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testHostFallbackRejectsUnpinWithoutChangingConfirmedOrder \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests/testNativeAuthorityKeepsExistingPinMutationContract
~~~

Expected: RED because `setThreadPinned` currently proceeds from the active effective IDs without a host-read-only guard.

- [ ] **Step 3: Guard the service mutation API.**

At the start of the serialized mutation operation, after any required authority probe but before section creation or move:

~~~swift
guard pinnedStateAuthority == .native,
      nativePinCapability == .available else {
    throw CodexServiceError.invalidInput("Update Codex to synchronize pins.")
}
~~~

Keep archived-root and direct-subagent validation. Keep the existing native response-confirmed cache update and post-success refresh behavior. A failed post-success refresh must still leave the confirmed native response visible.

- [ ] **Step 4: Disable the existing menu action with the same reason.**

Thread a `pinMutationDisabledReason` through the existing sidebar row tree. For host compatibility, render the current Pin/Unpin entry as a disabled UIKit `UIAction` whose title/status includes `Update Codex to synchronize pins.` Do not add a new pin button, change the row icon, or hide the error behind a silent no-op. Direct service callers still receive the exact error.

Keep the action omitted for archived and subagent rows as it is today. Keep the existing `Image(systemName: "pin.fill")` row badge at 18 points and keep its accessibility-hidden behavior.

- [ ] **Step 5: Run the mutation command to prove GREEN.**

Use the command from Step 2. Expected: all three named tests pass.

- [ ] **Step 6: Commit the mutation boundary.**

~~~bash
rtk git add CodexMobile/CodexMobile/Services/CodexService+NativePins.swift CodexMobile/CodexMobile/Views/SidebarView.swift CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadListView.swift CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadRowView.swift CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadContextMenu.swift CodexMobile/CodexMobileTests/CodexServiceThreadListTests.swift
rtk git commit -m "fix: disable pin mutations during host compatibility"
~~~

## Task 6: Preserve grouping and approved sidebar behavior

**Files:**

- Modify only if a regression test proves it is necessary: `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadGrouping.swift`
- Modify: `CodexMobile/CodexMobileTests/SidebarThreadGroupingTests.swift`

- [ ] **Step 1: Keep the existing grouping regression coverage.**

Retain and, if needed, strengthen the existing tests `testPinnedRootsAppearOnceInNativeOrderAndSubtreesLeaveProjects` and `testEmptyPinnedOrderOmitsPinnedGroup`. The assertions must prove:

- supplied host/native order is unchanged;
- each pinned root appears once;
- known descendants appear only under the pinned root;
- pinned roots and descendants do not appear in project/rootless groups; and
- an empty effective order produces no Pinned group.

The current grouping implementation already has this boundary. Prefer test-only strengthening; do not refactor it or introduce source-specific grouping logic.

- [ ] **Step 2: Run only the approved grouping suite.**

~~~bash
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  'EXCLUDED_SOURCE_FILE_NAMES=TurnTimelineReducerTests.swift CodexThreadStartProjectBindingTests.swift' \
  test -only-testing:CodexMobileTests/SidebarThreadGroupingTests
~~~

Expected: the existing and strengthened grouping tests pass. No simulator UI run is needed.

- [ ] **Step 3: Commit only if grouping tests changed.**

~~~bash
rtk git add CodexMobile/CodexMobileTests/SidebarThreadGroupingTests.swift CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadGrouping.swift
rtk git commit -m "test: preserve Codex host pin grouping"
~~~

Omit the commit if the existing tests already cover the correction and no file changed.

## Final approved verification and handoff

- [ ] **Step 1: Run the one approved focused relay command.**

~~~bash
cd phodex-bridge
rtk node --test --test-name-pattern="handleHostPinsRequest|authoritative thread/read|sanitizeThreadHistoryImagesForRelay preserves section-filtered thread/list order and metadata" ./test/bridge.test.js
~~~

Expected: all matched bridge tests pass. Do not run the full bridge suite.

- [ ] **Step 2: Run the three approved Xcode suites only.**

~~~bash
cd ..
rtk xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  'EXCLUDED_SOURCE_FILE_NAMES=TurnTimelineReducerTests.swift CodexThreadStartProjectBindingTests.swift' \
  test \
  -only-testing:CodexMobileTests/CodexServiceThreadListTests \
  -only-testing:CodexMobileTests/CodexThreadRenamePersistenceTests \
  -only-testing:CodexMobileTests/SidebarThreadGroupingTests
~~~

Expected: only the three approved suites run and pass. Do not append a full-suite target, `CodexTrustedMacSelectionTests`, UI automation, or a simulator launch.

- [ ] **Step 3: Check the final diff and changed-file scope.**

~~~bash
rtk git diff --check
rtk git status --short
rtk git diff --stat origin/main...HEAD
~~~

Expected: no whitespace errors; all intended correction commits are present; only the bridge handler, the named service/UI/test files, and the optional project membership change are modified. No production log contains a live pin ID or host path.

## Acceptance checklist

- [ ] A valid host `pinned-thread-ids` array appears in exact order.
- [ ] Host reads use the fixed local path and never write it.
- [ ] Missing, malformed, racing, unsupported, and offline reads retain the last confirmed state.
- [ ] Missing host rows use authoritative app-server `thread/read`; JSONL never adds pins.
- [ ] All native user-facing source kinds and the legacy retry preserve section order.
- [ ] Native authority is latched only by the explicit complete-result predicate.
- [ ] A later native empty/error result cannot resurrect stale host pins after the latch.
- [ ] Legacy iOS pin IDs and snapshots are discarded during load and Mac-device coalescing.
- [ ] Host compatibility disables Pin/Unpin with the exact update error and sends no move/create RPC.
- [ ] Native Pin/Unpin retains existing confirmed mutation semantics.
- [ ] Pinned roots and descendants remain out of project groups and the existing 18-point root-only UI remains unchanged.
- [ ] Only the approved relay test and three approved Xcode suites are run.
