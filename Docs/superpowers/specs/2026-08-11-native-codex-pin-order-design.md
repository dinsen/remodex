# Native Codex Pin Order Design

## Goal

Show pinned root threads in the same top-to-bottom order as Codex, including manual reordering performed in Codex.

## Root cause

Remodex requests the Pinned section with `sortKey: "section_position"` but omits `sortDirection`. The runtime default can therefore return the section in the opposite direction from Codex's visible top-to-bottom order. The service, cache, grouping code, and sidebar already preserve the order they receive.

## Design

Add `sortDirection: "asc"` to every section-filtered pinned `thread/list` request. Continue to concatenate pages in response order, deduplicate IDs without sorting, and pass the confirmed order unchanged through persistence and sidebar grouping.

No local reorder state or reorder UI will be added. A later refresh, reconnect, or foreground synchronization will pick up manual ordering changes made in Codex. If synchronization fails, Remodex will keep the last confirmed order.

## Compatibility

The legacy source-kind retry must retain `sectionId`, `sortKey: "section_position"`, and `sortDirection: "asc"`. Unsupported runtimes keep the existing confirmed cache and error behavior.

## Verification

Extend the focused native pin service test to require ascending section-position requests across initial, compatibility-retry, and paginated calls. Keep the existing sidebar grouping assertion that pinned roots appear in the supplied native order. Run only the targeted pin-related Xcode tests approved by the original plan.
