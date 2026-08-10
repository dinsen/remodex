# Native Codex Pins Design

## Goal

Show Codex-pinned threads as one flat list above all project sections in the iOS sidebar. Codex owns pin state. Pin and Unpin actions in iOS update Codex so both apps remain synchronized.

## Current behavior

Remodex keeps a separate, Mac-scoped list of locally pinned thread IDs and snapshots. The sidebar already lifts those local roots and their descendants into a leading Pinned group, but native Codex section metadata is not decoded or used. Pin and Unpin currently mutate only local `UserDefaults` state.

Codex app-server 0.147.0 exposes persisted thread sections through its experimental protocol:

- `threadSection/list` lists sections, including the user-visible `Pinned` section.
- `thread/list` accepts `sectionId` and `sortKey: "section_position"`.
- thread rows can contain `section` and `sectionEnteredAt` metadata.
- `thread/section/move` moves a thread into a section or removes it by passing a null section ID.

## Source of truth

The Codex Pinned section is the sole writable source of truth. Remodex may cache the last confirmed native pin list and pinned thread snapshots for offline display, but it must not accept offline or local-only Pin and Unpin changes.

The service keeps:

- the resolved native Pinned section ID;
- the ordered IDs returned by the native pinned-thread query;
- pinned thread snapshots needed when those threads fall outside the normal thread-list page;
- legacy local pin data only until migration completes.

## Synchronization

During thread synchronization, Remodex will:

1. List native thread sections and locate the section named `Pinned`.
2. If it exists, request all pages of that section using `thread/list`, its section ID, and `section_position` ordering.
3. Merge those thread rows into the normal thread collection before sidebar grouping.
4. Replace the in-memory native pin order only after the complete query succeeds.
5. Preserve the last confirmed native pin cache when the request fails or the app is offline.

This native pin refresh runs with the existing thread refresh lifecycle, including reconnect, foreground recovery, pull-to-refresh, and sidebar refresh. A pinned thread omitted by the normal recent-thread page must still appear from the dedicated pinned query.

## Legacy migration

Existing iOS-only pins migrate into Codex once section support is available:

1. Resolve the native Pinned section, creating it only when migration or a new Pin action requires one.
2. Move every legacy locally pinned root into that section without removing native pins.
3. Refresh the native pinned list.
4. Clear the legacy pin IDs and snapshots only after all moves and the refresh succeed.

If any step fails, keep all legacy migration data and retry during a later sync. This makes the migration idempotent and prevents partial data loss. Once cleared, local pins cannot reappear as an independent source of truth.

## Pin and Unpin actions

The existing long-press menu remains the interaction surface.

- **Pin:** resolve or create the Pinned section, then call `thread/section/move` for the root thread. Insert it before the current first pinned root so the newest pin appears first.
- **Unpin:** call `thread/section/move` with a null section ID.
- Serialize pin mutations so rapid actions cannot reorder or overwrite one another.
- Do not change the visible grouping until Codex confirms the mutation and the native pin refresh succeeds.
- Keep the existing restriction that archived threads and subagent threads cannot be pinned directly.

After a confirmed Unpin, the thread returns to its normal project group. After a confirmed Pin, it leaves that project group and appears only in the flat Pinned list.

## Sidebar presentation

The Projects sidebar has this order:

1. A `Pinned` heading and flat list, when at least one native pin exists.
2. The `Projects` heading and project sections.

Pinned presentation rules:

- Each pinned root appears exactly once and is excluded from its project section.
- Native Codex section order is preserved.
- Each pinned root row shows an 18-point filled `pin.fill` before its title.
- Use the real filled SF Symbol for the row badge because the current custom `central-pin` asset is outlined and maps both `pin` and `pin.fill` to the same artwork.
- The row pin has the same visual weight as project folder icons.
- Do not show a project name, folder, or project hierarchy in the Pinned list.
- Preserve the existing thread status, run-state, selection, and trailing metadata.
- A pinned root's subagent descendants remain nested under that root and appear only when expanded. Descendants do not receive pin icons because they are not directly pinned.
- The filled pin is decorative for VoiceOver. The row's accessibility label or value communicates that the thread is pinned.
- Hide the Pinned area when empty.

## Compatibility and failures

Native sections are experimental and are not documented in the public OpenAI Codex documentation. Remodex must detect method-not-found or incompatible-parameter errors.

On an unsupported Codex runtime:

- do not create or mutate local-only pin state;
- leave the current confirmed UI unchanged;
- tell the user that Codex must be updated to synchronize pins.

On timeouts or other mutation failures, keep the confirmed grouping unchanged and surface the existing user-visible error path. Never claim success before Codex confirms the move.

## Verification

Focused tests will cover:

- decoding thread section metadata;
- preserving native section order;
- merging older pinned rows that are absent from normal pagination;
- excluding pinned roots and their visible descendants from project groups;
- showing each pinned root exactly once above Projects;
- legacy migration success, partial failure, retention, and retry;
- creating the Pinned section only when required;
- Pin and Unpin success, timeout, and unsupported-runtime behavior;
- serial mutation ordering;
- the filled row pin and its accessibility semantics.

The user explicitly approved running only the targeted pin-related Xcode tests. No broad Xcode test suite or simulator run is required.

## Acceptance criteria

- Pins created in Codex appear in iOS after synchronization.
- Pins created or removed in iOS update Codex and later match Codex Desktop.
- Existing iOS-only pins migrate into Codex without removing existing native pins.
- Pinned threads form one flat list above every project and do not also appear within their project.
- Every pinned root shows a filled pin icon; unpinned and descendant rows do not.
- Older pinned threads remain visible even when absent from the normal recent-thread page.
- Unsupported runtimes never create divergent local pin state.

## Non-goals

- Adding a separate pin button to every unpinned row.
- Pinning subagent threads independently.
- Recreating Codex sections as a general-purpose section editor.
- Scraping Codex Desktop local storage.
- Reintroducing selected-repository filtering.
