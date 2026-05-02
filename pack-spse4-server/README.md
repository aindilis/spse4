# pack-spse4-server

HTTP and Pengines server for SPSE4 task graphs, with basic auth,
per-microtheory access control, and live broadcast fanout of edit
events.

Part of [FRKCSA / SPSE4](https://github.com/aindilis/spse4). MIT License.

## What it does

- Exposes the `pack-spse4-core` task graph over HTTP
- Serves a Cytoscape-ready JSON projection of any microtheory
- Accepts Pengines queries with a sandbox that enforces ACLs on
  every read and write
- Relays `pack-spse4-core` broadcast events to connected clients,
  filtered by their ACL
- Supports multiple users via an on-disk password file (PBKDF2-hashed)

## Why you might want this standalone

Even outside SPSE4, this pack is useful if you have any
microtheory-partitioned Prolog knowledge base and you want to
expose it to a browser, Emacs, or a command-line client with
real per-mt access control. The ACL wrapper pattern works
against any backend that looks like `mt_store`.

## Install

Requires SWI-Prolog ≥ 9.0.0 and packs `mt_store` and `spse4_core`.

```sh
swipl -g "pack_install('pack-spse4-server.tgz', [interactive(false)]), halt."
```

Or from a local clone:

```prolog
?- pack_install('/path/to/pack-spse4-server').
```

## Usage

```prolog
?- use_module(library(spse4_server)).
?- spse4_user_add(alice, "hunter2",
                  [read([public, project_a]),
                   write([project_a])]).
?- spse4_server_start([port(4040), acl_mode(strict)]).
% spse4_server: listening at http://localhost:4040/
```

### Endpoints

- `GET /health` — JSON status (public)
- `GET /projection?mt=MT[&status=S&relation=R&critical_path=1&goal=GID]`
  — Cytoscape-elements JSON for the named microtheory (auth required
  in strict mode; enforces read ACL)
- `GET /pengine/…` — Pengines protocol (auth required in strict mode)
- `GET /events` — SSE stream of broadcast events (auth required)

### Running the demo

```sh
cd pack-spse4-server/examples
swipl server_demo.pl
```

Then in another terminal:

```sh
curl -u alice:hunter2 \
     'http://localhost:4040/projection?mt=autopackager&critical_path=1&goal=flp_release' \
  | jq .
```

## ACL model

Each user has a list of `read(MtList)` and `write(MtList)` clauses.
`write` implies `read` on the same mts. Everything is default-deny
in `strict` mode. `permissive` mode (for local dev) grants any
authenticated user full access.

The ACL is enforced at two boundaries:

1. **HTTP handlers** check before any reply.
2. **Pengines sandbox** whitelists only ACL-wrapping predicates
   (`acl_read/2`, `acl_write_task/5`, etc.), not the underlying
   store, so a user cannot escape the wrapper from within a query.

## Testing

```sh
swipl -g "[library(plunit)],load_test_files([]),run_tests,halt"
```

Expected: 11 tests green against a locally-launched server on a
random high port in the 14040–14060 range.

## What's not here

- TLS/HTTPS termination: use a reverse proxy (nginx, Caddy) in
  production. Basic auth over plain HTTP is only safe on localhost.
- Rate limiting: add via reverse proxy or `library(http/http_throttle)`.
- Session cookies: basic auth is per-request; no session state.

## License

MIT. See the top-level SPSE4 LICENSE.
