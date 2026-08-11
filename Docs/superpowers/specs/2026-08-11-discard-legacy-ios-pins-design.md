# Discard Legacy iOS Pins

## Context

Device testing showed that Remodex still displayed old iOS-only pins while native synchronization was incomplete. Those pins are stale and must not be imported into Codex.

This design supersedes the legacy-pin migration behavior in `2026-08-10-native-codex-pins-design.md`. Native Codex pin synchronization remains unchanged.

## Approved behavior

- Codex's native Pinned section is the only displayed and writable source of truth.
- Remodex never displays legacy iOS pin IDs or snapshots.
- Remodex never sends `thread/section/move` requests for legacy pins.
- When old pin storage is loaded, Remodex deletes its legacy ID and snapshot keys.
- The last confirmed native pin cache remains available offline and when section APIs fail.
- Native Pin and Unpin actions still wait for Codex confirmation.

## Implementation

Remove the legacy migration queue from `CodexService` state and native synchronization. Mac-scoped state loading must remove the old `codex.pinnedThreadIDs` and `codex.pinnedThreadSnapshots` keys instead of decoding them. Effective displayed state must be built only from the confirmed native IDs and snapshots.

Keep the old key constants temporarily so existing installations can delete their stored values. Do not add a replacement migration marker or compatibility view.

## Verification

Targeted tests must prove that:

- legacy storage is deleted on load;
- legacy IDs never appear beside confirmed native pins;
- synchronization never creates a Pinned section or moves threads because of legacy storage;
- confirmed native cache behavior remains unchanged offline and after refresh failures.

The reported device crash is investigated separately. No crash fix is justified until a device crash log identifies its cause.
