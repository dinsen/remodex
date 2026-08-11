# Codex Host Pins Compatibility Design

## Status

Approved correction design for the native Codex pin implementation. This document
extends the existing native-pin work. It does not authorize production or test
changes by itself.

## Goal

Show the ordered pins that Codex Desktop currently stores in
`$CODEX_HOME/.codex-global-state.json` under `pinned-thread-ids`, while keeping
the supported app-server `Pinned` section as the preferred writable source once
that source is demonstrably authoritative.

The current Desktop state contains seven ordered pin IDs in this host file. The
number is runtime data. The implementation must not hardcode it.

## Current gap

The existing implementation on `main` already:

- queries the app-server `Pinned` section with `section_position` and ascending
  order;
- preserves native response and page order;
- merges dedicated native rows into normal thread hydration;
- discards old iOS-only pin storage on normal Mac-scoped state load; and
- renders one flat Pinned section with a root-only, 18-point `pin.fill` badge.

The remaining compatibility defect is that Desktop host pins and app-server
section pins are separate, feature-gated state. The app-server `Pinned` section
can therefore be present but empty while Desktop still has valid host pins. The
current service treats that empty app-server result as authoritative and never
reads the host state.

This correction adds a read-only compatibility source. It does not make the
host file a writable database and does not migrate pins by writing JSONL or by
issuing `thread/section/move` requests.

## Invariants

1. The host file is read-only to Remodex. The bridge never writes, renames,
   deletes, or repairs `$CODEX_HOME/.codex-global-state.json`.
2. The bridge exposes one purpose-built RPC for the one supported host-state
   field. It does not expose arbitrary paths, arbitrary JSON, or a generic file
   reader.
3. A valid host array is displayed in exactly its source order. No recency sort,
   alphabetical sort, local reorder, or JSONL-derived insertion is allowed.
4. Host IDs are compatibility input, not a second writable iOS pin store.
   Legacy iOS pin IDs and snapshots remain discarded and are never merged into
   either source.
5. A host pin whose row is absent from the normal thread page is hydrated with
   authoritative app-server `thread/read`. JSONL rollout data is not used to
   discover, add, or complete host pins.
6. A pinned root and every available descendant stay together in the Pinned
   section and are excluded from project and rootless-chat sections. Descendants
   do not receive a pin badge.
7. The current root-only UI remains unchanged: the existing 18-point filled
   `pin.fill` row icon, existing Pinned header, existing status metadata, and
   existing expansion behavior remain in use.
8. Missing, malformed, racing, unsupported, or offline reads never clear a last
   confirmed source. A valid empty host array is different from a missing or
   malformed host field and is allowed to confirm empty host state.
9. Pin and Unpin are unavailable while host compatibility is the active source.
   The service rejects direct mutation attempts with the clear error
   `Update Codex to synchronize pins.` The sidebar presents the same reason on
   the disabled action.
10. No live pin ID, host-file path, raw host JSON, or pairing-like value is
    written to bridge or iOS logs.

## Sources and authority

The service keeps separate confirmed caches for the two sources:

- `native`: the ordered IDs and snapshots returned by a complete app-server
  `Pinned` section query;
- `hostCompatibility`: the ordered IDs returned by the bridge host-state RPC and
  the rows successfully hydrated from app-server `thread/read`.

The observable `pinnedThreadIDs` and `pinnedThreadSnapshotsByRootID` remain the
single effective view consumed by sidebar grouping. They are rebuilt from the
active source. They are not a new writable store.

The persisted authority state is Mac-scoped and has three values:

| State | Display source | Mutation | Host reads |
| --- | --- | --- | --- |
| `undecided` | The last confirmed cache, preferring the existing confirmed native cache during the first corrected launch | Probe after synchronization; never write locally | Allowed while deciding |
| `hostCompatibility` | Last confirmed host ID order and snapshots | Disabled with the update error | Allowed for refresh |
| `native` | Last confirmed app-server native order and snapshots | Allowed when the native RPC path is available | Never read or merged again |

The decision is made by a pure, testable authority function after one serialized
synchronization generation has collected its results:

| Native probe | Host probe | Decision |
| --- | --- | --- |
| Complete `Pinned` query with one or more valid native rows | Any valid or unavailable host result | Latch `native`; native order wins |
| Complete empty `Pinned` query | Valid empty host array, or a host array exactly equal to the empty native order | Latch `native` with an empty list |
| Complete empty `Pinned` query | Valid non-empty host array | Select `hostCompatibility`; keep the host order and do not create or move a section |
| Missing `Pinned` section, unsupported native method, malformed native result, or incomplete native pagination | Valid host array | Select or retain `hostCompatibility`; do not clear a confirmed host cache |
| Any native result | Missing, malformed, racing, unsupported, or offline host read | Keep the currently confirmed source. If there is no confirmed source, show no pins and retry later |

A complete non-empty native query is evidence that the supported app-server path
is returning canonical section members. A complete empty native query is only
authoritative when it does not contradict a valid non-empty host snapshot. This
allows the current Desktop-only state to work without treating an empty,
feature-gated section as a migration signal.

When `native` is latched, the service persists that decision before exposing it,
clears the compatibility cache, and never falls back to host state because of a
later native error or empty refresh. This is the stale-host barrier. A later
valid native empty result clears the native cache; a missing or failed result
retains it.

If the corrected build starts with an existing native cache but no authority
marker, it treats the cache as the last confirmed display while it probes. It
does not mark native authority until the decision above succeeds. If a live
probe shows an empty native section and valid host pins, the host source replaces
the provisional display and records `hostCompatibility`.

## Bridge RPC boundary

### Request

```json
{
  "id": "rpc-id",
  "method": "bridge/hostPins/read",
  "params": {}
}
```

`params` must be absent, `null`, or an empty object. It must not contain a path,
file name, key name, thread ID, or read options. The bridge resolves the file
itself as:

```text
resolveCodexHome()/.codex-global-state.json
```

`resolveCodexHome()` continues to use the local `CODEX_HOME` environment value
or the local default. The client cannot override it.

### Successful response

```json
{
  "schemaVersion": 1,
  "source": "codex-host",
  "pinnedThreadIds": ["thread-a", "thread-b"]
}
```

The bridge reads only the exact `pinned-thread-ids` property. It returns no file
path, file metadata, raw object, or unrelated global-state keys. It preserves
array order and accepts a valid empty array.

### Validation and atomicity

The handler validates the full snapshot before returning it:

The correction fixes the bounds at 1 MiB (1,048,576 UTF-8 bytes), 512 IDs, and
256 characters per ID. It performs two total read attempts: the initial
snapshot and one retry after a detected file change.

- the root must be a JSON object;
- `pinned-thread-ids` must be present and an array;
- the array must stay below a fixed bounded count;
- every entry must be a non-empty string matching the existing safe thread-ID
  shape and bounded length; and
- duplicate IDs make the snapshot malformed instead of silently changing its
  order.

The read uses a bounded file handle, checks file identity/size/timestamps before
and after reading, and retries once when the file changes during the read. A
second unstable read returns a stable `host_pins_racing` bridge error. Oversized,
invalid JSON, missing keys, invalid IDs, and invalid request parameters return
stable error codes without returning partial IDs.

The handler accepts injected filesystem and home-directory dependencies only in
unit tests. Production code has no arbitrary-file mode. It does not call any
JSONL or rollout reader and has no write-capable dependency.

### Errors and privacy

The bridge uses the existing app-facing JSON-RPC error envelope with these
bounded error codes:

- `host_pins_unavailable` for a missing or unreadable host file;
- `host_pins_malformed` for an invalid request or invalid file shape; and
- `host_pins_racing` after the bounded atomic-read retries.

Errors contain a short user-safe message. They do not contain the path, raw
JSON, IDs, or filesystem exception text. Bridge diagnostics may count a read or
record one of these error codes, but must not log values from the array.

The existing section-filtered `thread/list` relay sanitizer remains important for
the native path: it keeps server order, preserves bounded section metadata, and
does not add JSONL rows when `sectionId` is present. An authoritative
`thread/read` used to hydrate a host row must likewise bypass JSONL metadata
augmentation so the returned row remains app-server metadata. This is a relay
sanitization rule, not a new file-access surface.

## Native app-server path

The native probe continues to use the existing methods and commit boundaries:

1. `threadSection/list` resolves the exact section name `Pinned`.
2. A complete `thread/list` query uses `sectionId`,
   `sortKey: "section_position"`, `sortDirection: "asc"`, all pages, and the
   explicit source-kind policy below.
3. The cache is replaced only after every page succeeds and decodes into valid
   rows. A partial page sequence cannot clear the last confirmed state.
4. A missing section is a non-authoritative result while the authority is
   undecided. It is not permission to create an empty section during refresh.
5. Section creation and `thread/section/move` remain native-only mutation
   operations and are never used by host compatibility.

The modern source-kind list remains:

```text
cli, vscode, appServer, exec, subAgent, subAgentReview,
subAgentCompact, subAgentThreadSpawn, subAgentOther, unknown
```

If an older runtime rejects the expanded subagent variants, the existing retry
uses this legacy list without dropping the section filter or order:

```text
cli, vscode, appServer, exec, unknown
```

This policy applies to every user-facing native `thread/list` page. Host
hydration uses `thread/read`, which has no source-kind parameter and therefore
does not narrow the source set.

## Host fallback hydration

When `hostCompatibility` is selected, the service keeps the host ID array as the
display order. For each ID it:

1. reuses a live row or confirmed snapshot when one is available;
2. otherwise sends authoritative app-server `thread/read` with
   `{ "threadId": id, "includeTurns": false }`;
3. retries the existing snake-case parameter spelling only when the runtime
   reports that compatibility error;
4. accepts only a `result.thread` whose decoded ID equals the requested ID; and
5. merges the returned row into the normal thread collection and the host
   snapshot cache without sorting the host ID list.

The seven current pins therefore produce seven ordered reads when their rows
are not already available, but the implementation uses bounded loops and does
not rely on the current count. A failed individual read keeps that ID in the
confirmed order and reuses its prior snapshot if one exists. An ID with no row
yet is not synthesized from a rollout file and is retried on a later refresh.

The existing grouping pipeline receives the effective root ID order. It walks
the available parent-child relationships, renders each pinned root once, nests
known descendants below that root, and excludes the entire available subtree
from project and rootless-chat groups. A host ID that resolves to a subagent is
not promoted to a new root; it is treated as an invalid pin row and retained
only for retry/cache diagnostics without changing project grouping.

## Persistence and legacy state

All compatibility and native pin keys remain Mac-scoped. Add keys for:

- host ordered IDs;
- host root snapshots; and
- the persisted authority state.

The existing native cache keys remain in use. The old
`codex.pinnedThreadIDs` and `codex.pinnedThreadSnapshots` keys remain only long
enough to delete old installations' values. They must be removed during normal
load and during coalesced Mac-device migration. They must never be copied,
merged, displayed, or used to create/move native pins. No replacement legacy
migration queue is added.

When native authority is latched, host cache keys are deleted. When host state is
confirmed, only the host compatibility keys and host authority marker are
updated. No path writes back to the Desktop global-state file.

## Sidebar behavior and mutation gating

`SidebarThreadGrouping` remains the single grouping boundary. It continues to
receive the service's effective ordered IDs, so no selected-repository filter or
new project hierarchy is introduced.

The existing UI remains:

- Pinned is a flat leading section;
- project names and folder decoration do not appear in Pinned rows;
- only pinned roots show the existing 18-point `Image(systemName: "pin.fill")`;
- descendants remain expandable and unbadged; and
- VoiceOver continues to receive the row-level `Pinned` value, not a second
  spoken icon.

While the active source is `hostCompatibility`, the long-press Pin/Unpin entry
is visible but disabled with a title or status reason that includes
`Update Codex to synchronize pins.` The service performs the same guard for
direct callers, before section creation or move requests. Native authority keeps
the existing async serialized Pin/Unpin behavior and confirmed-response cache
updates.

## Failure and transition table

| Event | Effective display | Persistence | Mutation |
| --- | --- | --- | --- |
| Valid host IDs, native section empty or unavailable | Exact host order, with cached/read rows | Save host IDs/snapshots and `hostCompatibility` | Disabled; clear update error |
| Host file missing, malformed, racing, or offline | Last confirmed active source | Do not replace or clear it | Keep the active source's capability |
| Native complete non-empty query before latch | Exact native order | Save native cache, clear host cache, latch `native` | Enabled after confirmation |
| Native complete empty query plus valid empty/equal host state | Empty native order | Save native empty cache, latch `native` | Enabled after confirmation |
| Native complete empty query contradicts valid non-empty host state | Exact host order | Keep/save host compatibility state | Disabled |
| Native authority refresh fails | Last confirmed native order | Preserve native cache and authority | Remains native; host is not read |
| Valid native Unpin/Pin response | Apply only the confirmed native response, then refresh | Persist native response before refresh | Success is not undone by a later refresh failure |
| Legacy iOS keys found | No legacy rows | Delete the keys | No migration RPC |

## Non-goals

- Writing or repairing Codex Desktop global state.
- Creating a general-purpose bridge file-reader RPC.
- Using JSONL rollout data to discover or add pins.
- Importing or migrating old iOS-only pins.
- Adding local reorder state or a reorder UI.
- Pinning descendants independently.
- Changing project filtering, local pairing, relay authentication, or unrelated
  timeline behavior.
- Running a full Xcode suite or simulator UI automation for this correction.

## Verification scope

The correction uses TDD and only the approved focused verification surfaces:

- the existing targeted relay pin test in `phodex-bridge/test/bridge.test.js`,
  extended only with narrow host-read/authoritative-read cases; and
- the three approved Xcode test suites:
  `CodexServiceThreadListTests`, `CodexThreadRenamePersistenceTests`, and
  `SidebarThreadGroupingTests`.

No full Node bridge suite, full Xcode suite, or simulator UI run is part of this
design.
