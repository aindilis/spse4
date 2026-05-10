# SPSE4 — Changelog

## v0.2.3 — 2026-05-10

Local-development security hardening.  Two changes that make the demo
safer to leave running while you debug, with no setup required for
the out-of-the-box experience.

### Changed

- **`pack-spse4-server`**: `spse4_server_start/1` now honors its
  `bind/1` option (previously documented but ignored).  Default is
  `localhost`, matching the existing docstring.  Pass
  `bind('0.0.0.0')` to listen on every interface.  Plain HTTP basic
  auth is not safe to expose past localhost without TLS in front,
  hence the localhost default.

- **`pack-spse4-server/examples/server_demo.pl`**: looks up user
  accounts in three places, taking the first that exists:
  1. The file named by `$SPSE4_USERS`, if set.
  2. `~/.config/spse4/users.pl`, if it exists.
  3. Built-in throwaway fallback (seeds `demo`/`demo` and
     `bob`/`pass` in memory).

  Lookup files are consulted with `consult/1`, so directives like
  `:- spse4_user_add(name, "plaintext", ACL).` work directly — the
  password is hashed at load time and the plaintext never enters
  the in-memory user record.  The location is outside the working
  tree, so `git status` will never offer to stage your private
  credentials.  A malformed file is reported on stderr and the loader
  falls through to the next source rather than refusing to start.

- **`server_demo.pl`** also now reads `$SPSE4_BIND`, defaulting to
  `localhost`.  Set `SPSE4_BIND=0.0.0.0` (or any specific address)
  to expose the server on the LAN or Tailnet.  The startup banner
  reports the bind interface when it isn't localhost.

- Demo credentials renamed from `alice`/`hunter2` to `demo`/`demo`
  in all source, docs, comments, and tests.  More self-documenting
  as obviously-throwaway demo values.

### Notes

- The `users_file` mechanism in `spse4_server_start/1` is unchanged
  (still the production path: `user(Name, HashedPassword, ACL).`
  facts).  The new lookup is purely a `server_demo.pl` convenience.
- Test count unchanged: the existing `user_add_and_acl` test
  continues to verify the same predicate behavior under the renamed
  fixture user.

## v0.2.2 — 2026-05-10

Edge editing closes the structural-CRUD story.  Tasks gained add/delete
in v0.2.0 and inline status edit in v0.2.1; v0.2.2 brings the same
treatment to edges.  You can now create new edges through a toolbar
modal, edit any edge's property dict in place, or delete an edge from
the side-panel row — all with the same auth, ACL, and broadcast
semantics as task mutations.

### Added

- **`pack-spse4-server`**: REST mutation endpoints for edges
  - `POST /edges`  body `{mt, from, kind, to[, props]}`            — 201 / 400 / 401 / 403 / 404 / 409
  - `DELETE /edges/<mt>/<from>/<kind>/<to>`                        — 200 / 401 / 403 / 404
  - `PATCH /edges/<mt>/<from>/<kind>/<to>` body `{props: {...}}`   — 200 / 400 / 401 / 403 / 404

  All three require authentication (401 if anon) and enforce the
  per-microtheory write ACL (403 if denied).  POST returns 409 if the
  edge already exists, 404 if either endpoint task is missing, and 400
  if the edge kind is not in `valid_edge_kind/1`.  PATCH replaces the
  edge's property dict wholesale (it is not a merge — pass the full
  desired props).  Mutations broadcast `edge_added` /
  `edge_removed` / `edge_property_changed` per the v0.2.0 event
  vocabulary, and propagate to other clients through the existing
  `/events` poll relay.

- **`spse4-web`**:
  - "+ Edge" button in the toolbar opens a modal for adding a new edge
    (from, to, kind, props).  Keyboard shortcut: `e`.  When the modal
    opens with a task selected, From is pre-filled with the current
    selection and focus jumps to To.
  - Each row in the side panel's "depends on" / "depended on by"
    sections now has a per-row `✎ edit-props` and `✕ delete` action.
    Edit opens the same modal in edit-mode (from/kind/to disabled,
    props editable).  Delete confirms then calls `DELETE /edges/...`.
    The clickable body of the row (kind badge + endpoint id + status)
    remains the navigation target; action-button clicks
    `stopPropagation()` so they don't navigate.
  - `API.createEdge`, `API.deleteEdge`, and `API.updateEdgeProps`
    clients matching the new REST endpoints, with auth-aware fetch
    and structured error handling.
  - Edge-kind badges in the side panel are color-coded to match the
    cytoscape edge colors (provides=blue, attacks=red, supports=green,
    eases=neutral-dotted; depends and the rare kinds use the default
    neutral chip).

- **Tests**: 12 new PlUnit tests in `pack-spse4-server` covering
  POST/DELETE/PATCH happy paths and error conditions (anon-denied,
  ACL-denied wrong mt, 404 on missing endpoint task, 404 on missing
  edge, 409 on duplicate, 400 on unknown kind), plus broadcast-fires
  verification for both `edge_added` (POST) and `edge_property_changed`
  (PATCH).

### Changed

- `pack-spse4-server` version bumped to 0.2.2; `/health` now reports
  `version: "0.2.2"`.  The startup banner lists the three new `/edges`
  routes.

### Notes

- v0.2.2 closes the basic CRUD story: tasks and edges both have
  add / inline-edit / delete UI, all backed by REST endpoints with
  consistent auth, ACL, and broadcast semantics.  WebSocket push
  (replacing the 3-second poll), `spse4-mode.el`, and the
  multi-instance broadcast demo recording remain on the v0.2.x
  roadmap.

## v0.2.1 — 2026-05-10

Status-edit completes the basic CRUD story.  Click the status pill in
the side panel; pick a new value from the dropdown; the change
propagates to other open tabs through the existing broadcast → poll
relay.

### Added

- **`pack-spse4-server`**: `PATCH /tasks/<mt>/<id>` endpoint accepting
  `{status: "<new_status>"}` JSON body.  Returns 200/400/401/403/404,
  with the same auth and ACL semantics as POST/DELETE.  Invalid
  statuses (anything outside `validate_property_/2`'s `oneof` list)
  return 400.

- **`spse4-web`**: the side-panel status pill is now clickable.
  Click swaps the pill for an inline `<select>` populated with all 11
  legal statuses.  Change/Enter commits via `PATCH`; Escape cancels.
  Optimistic UI: the new status renders immediately, with a rollback
  on server error.  The 3-second poll is suppressed while a status
  edit is in progress, so background refreshes don't clobber the
  open dropdown.

- **Tests**: 7 new PlUnit tests in `pack-spse4-server` covering
  anon-denied, happy path with auth, ACL-denied wrong mt, 404 on
  missing task, 400 on invalid status, 400 on missing field, and
  broadcast-fires verification.

### Changed

- `pack-spse4-server` version bumped to 0.2.1; `/health` now reports
  `version: "0.2.1"`.

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
