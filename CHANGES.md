# SPSE4 — Changelog

## v0.2.0 — 2026-05-09

The collaboration layer is functional end-to-end: a task created in one
browser tab now shows up in another within one poll cycle.

### Added

- **`pack-spse4-core`**: every mutation predicate now fires a
  `broadcast(spse4(Event))` event. New event vocabulary:
  - `task_added(Mt, Id, Props)`
  - `task_removed(Mt, Id)`
  - `task_property_changed(Mt, Id, Key, Value)`
  - `edge_added(Mt, From, Kind, To, Props)`
  - `edge_removed(Mt, From, Kind, To)`

  Re-asserting an idempotent edge does **not** re-broadcast `edge_added`.
  Retracting an absent edge succeeds silently and does not broadcast.
  Retracting a task with incident edges broadcasts an `edge_removed`
  event for each edge plus a single final `task_removed`.

- **`pack-spse4-server`**: REST mutation endpoints
  - `POST /tasks`  body `{mt, id, label, status[, props]}` — 201 / 400 / 401 / 403
  - `DELETE /tasks/<mt>/<id>`                              — 200 / 401 / 403 / 404

  Both endpoints require authentication for writes (returns 401 if anon)
  and enforce the per-microtheory write ACL (returns 403 if denied).
  Successful mutations propagate via the existing broadcast → `/events`
  poll relay; clients see them on the next poll cycle.

- **`spse4-web`**:
  - "+ Task" button in the toolbar opens a modal for adding a new task
    (ID, label, microtheory, status). Keyboard shortcut: `n`.
  - "Delete" action button in the side panel removes the selected task
    (with `confirm()`). Cascade-removes incident edges via
    `task_retract` semantics.
  - `API.createTask` and `API.deleteTask` clients matching the new REST
    endpoints, with auth-aware fetch and structured error handling.

- **Tests**: 9 new PlUnit tests in `pack-spse4-core` covering the
  broadcast event vocabulary; 6 new tests in `pack-spse4-server`
  covering POST/DELETE happy paths, ACL denial, anon denial, 404 on
  missing task, and full POST→DELETE round-trip with broadcast
  verification.

### Fixed

- **`pack-spse4-core` `task_retract/2`**: the v0.1 implementation had
  a latent bug where `forall(ist(Mt, edge_property(...)), true)` was a
  no-op (the body `true` doesn't retract anything). Edge-property
  facts were therefore being orphaned when their edges' parent task
  was retracted. The new implementation delegates incident-edge
  cleanup to `edge_retract/4`, which retracts both the edge and its
  edge_property facts.

- **`pack-spse4-server` `event_mt_/2`**: the v0.1.29 pattern table
  expected event shapes (`task_added/5`, `task_status/4`) that did
  not match the events any code in the project actually broadcast.
  Updated to match the v0.2.0 event vocabulary above.

### Notes

- Live updates currently use polling (`/events`, 3-second interval).
  WebSocket push is deferred to v0.2.1 as a transport-only upgrade —
  the broadcast → relay infrastructure is already in place.
- The `spse4-mode.el` Emacs mode and the multi-instance broadcast
  demo remain on the v0.2.x roadmap.

## v0.1.29 — 2026-04-23

- Server trio first leg: `pack-spse4-server` (Pengines + WebSocket
  transport + basic auth + per-microtheory ACL) and `spse4-web`
  (Cytoscape.js client) both functional.
- License updated from MIT to GPLv3 across all packs.
- `locate_web_dir_/1` runtime/load-time bug fixed: snapshot
  `prolog_load_context(directory, _)` into a dynamic `script_dir_/1`
  fact at load time inside a `:-` directive.

## v0.1 — 2026-04-22

- Initial release: five Prolog packs, ~3,900 lines, 79 PlUnit tests.
- `pack-allen`, `pack-mt-store`, `pack-pddl`, `pack-spse4-core`,
  `pack-spse4-scheduler`.
- Single-session pair-programming development; twelve tarballs,
  v0.1.0 → v0.1.12.
