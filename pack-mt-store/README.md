# pack-mt-store — Microtheory store for SWI-Prolog

A Guha-style microtheory (context) system for SWI-Prolog, with
pluggable storage backend, per-user access control, and an audit
trail on every change.

Implements the core vocabulary used by Cyc (`ist`, `genlMt`) and by
SPSE2 (`holds(Context, Fact)`), made native to SWI-Prolog.

Part of FRKCSA / SPSE4; standalone use is supported.  The default
backend is pure in-memory assertions with zero external dependencies,
suitable for development and testing.  A `prolog-mysql-store`
backend is shipping in v0.2.

## Install

```prolog
?- pack_install('https://github.com/aindilis/pack-mt-store.git').
?- use_module(library(mt_store)).
```

The default in-memory backend is active immediately; nothing else to
configure for development use.

## Concepts

- **Microtheory**: a named container for Prolog facts and rules.
  Facts in one microtheory do _not_ leak into another.
- **Specialization (`genlMt`)**: a more-specific microtheory inherits
  facts from a more-general one.  The lattice must be acyclic.
- **Access control**: the microtheory's `owner` has full access.
  Others need explicit `mt_grant/3`.  A microtheory with property
  `visibility=public` is readable by everyone.
- **Audit**: every `mt_assert/3` and `mt_retract/3` records an entry
  with timestamp, user, operation, and fact.

## Example

```prolog
?- use_module(library(mt_store)).

?- mt_create(general_kb, [owner=andrew, visibility=public]).
?- mt_create(medical_kb, [owner=andrew]).
?- mt_specialize(medical_kb, general_kb).

?- mt_assert(general_kb, organism(andrew, human)).
?- mt_assert(medical_kb, takes(andrew, vitaminD)).

?- ist(medical_kb, Fact).
Fact = takes(andrew, vitaminD).

?- ist_inherited(medical_kb, Fact).
Fact = takes(andrew, vitaminD) ;
Fact = organism(andrew, human).

?- mt_audit(medical_kb, Entry).
Entry = audit(1713734400.0, andrew, assert, takes(andrew, vitaminD)).
```

## Backends

`mt_store` uses a sixteen-callback dispatch interface (documented at
the top of `prolog/mt_store.pl`) to plug in storage backends.
Switching backends requires no change to user code; calls into
`mt_assert/3`, `ist/2`, etc. route through whatever backend is
currently registered.

### Default: in-memory backend

Active by default.  Stores everything in dynamic predicates inside
the `mt_store` module.  No setup, no dependencies.  State is lost
when Prolog exits.

### MySQL backend (since v0.2)

Persists writes through `prolog-mysql-store` (for user facts) and
five small addon tables (for microtheory metadata: registry,
properties, specialization edges, ACL, audit log).

Setup is a stack of four layers — MariaDB, ODBC, `prolog-mysql-store`,
and the SPSE4 wiring.  Each step has a verification command; if a
step fails, fix it before moving on.

#### 1. MariaDB server

```sh
sudo apt install mariadb-server
sudo systemctl enable --now mariadb
sudo mysql_secure_installation        # set root password, etc.
```

Create a dedicated database and user (do not reuse root):

```sh
sudo mariadb <<'SQL'
CREATE DATABASE prolog_store
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'spse4'@'localhost' IDENTIFIED BY 'change-me';
GRANT ALL PRIVILEGES ON prolog_store.* TO 'spse4'@'localhost';
FLUSH PRIVILEGES;
SQL
```

#### 2. Apply the SPSE4 schema

```sh
cd /path/to/spse4/pack-mt-store
mysql -u spse4 -p prolog_store < sql/spse4_schema.sql
mysql -u spse4 -p prolog_store < sql/spse4_addon.sql
```

Verify (you should see twelve tables):

```sh
mysql -u spse4 -p prolog_store -e "SHOW TABLES"
```

#### 3. ODBC layer

```sh
sudo apt install unixodbc unixodbc-dev odbc-mariadb swi-prolog-odbc
```

Find the registered driver name:

```sh
odbcinst -q -d
```

On Debian 13 this is `[MariaDB Unicode]` (with a space).  Use that
name verbatim in the next step.  If `odbcinst -q -d` reports nothing,
the driver did not auto-register; add it manually to
`/etc/odbcinst.ini` pointing at the actual `.so` file
(`dpkg -L odbc-mariadb | grep '\.so$'` to find it).

Edit `~/.odbc.ini` (lowercase, in your home directory):

```ini
[spse4_main]
Description = SPSE4 microtheory store
Driver      = MariaDB Unicode
Server      = localhost
Database    = prolog_store
UID         = spse4
PWD         = change-me
Port        = 3306
Charset     = utf8mb4
```

The `Driver` value must match a name from `odbcinst -q -d` exactly.
Verify the DSN works before involving Prolog at all:

```sh
isql -v spse4_main
```

You should land in a SQL prompt.  `select count(*) from mt_registry;`
should return 0.  If `isql` fails with `IM002 Data source name not
found`, the `Driver` name in `~/.odbc.ini` does not match a name in
`/etc/odbcinst.ini`.

#### 4. Install `prolog-mysql-store`

The simplest option, and what `run_all_tests.pl` already does for the
SPSE4 packs themselves, is to put `prolog-mysql-store/prolog/` on
SWI's library search path.  Add to `~/.config/swi-prolog/init.pl`
(create the file and parent directory if needed):

```prolog
:- asserta(user:file_search_path(library,
            '/path/to/prolog-mysql-store/prolog')).
```

Verify it loads:

```sh
swipl -g "use_module(library(mysql_store)), halt"
```

You will see a few warnings about singleton variables and a hash
predicate override; these are harmless.  Silent exit-code-0 means
the module loaded.

(If you would rather use `pack_install`, the pack must have a
`pack.pl` and the loadable modules must live in a `prolog/`
subdirectory.  Recent SWI versions are picky about local-file
installs; installing from a GitHub clone URL is usually smoother
than from a local tarball.)

#### 5. Run the SPSE4 tests against MySQL

```sh
cd /path/to/spse4
export SPSE4_MYSQL_DSN=spse4_main
export SPSE4_MYSQL_USER=spse4
export SPSE4_MYSQL_PASS=change-me
swipl -s run_all_tests.pl
```

Without the env vars the MySQL tests skip cleanly; with them set,
all 129 tests should pass.  The tests TRUNCATE the database on every
test, so do not point `SPSE4_MYSQL_DSN` at anything you care about.

#### 6. Start the SPSE4 server with the MySQL backend

```prolog
?- spse4_server_start([
     port(4040),
     mt_store_backend(mysql([connection_id(spse4_main)]))
   ]).
```

Or use it standalone:

```prolog
?- use_module(library(mt_store)).
?- use_module(library(mt_store_mysql)).
?- mt_store_mysql_init([connection_id(spse4_main)]).
?- mt_store:backend_register(mt_store_mysql).
```

#### Concurrency, failure model, limitations

A single ODBC handle is shared across requests, guarded by a mutex.
This matches SPSE4's typical workload (light writes, mostly reads)
and keeps the failure model simple.  A higher-throughput SQL-direct
backend is planned as a third option (see Roadmap).

ODBC errors propagate as Prolog exceptions.  No automatic reconnect.
An explicit `mt_store_mysql_reconnect/0` is provided for ops use
after a database bounce.

Known limitations of the underlying `prolog-mysql-store`:

- **Bare-atom facts not supported.**  `mt_assert(mt, foo)` will throw;
  use `mt_assert(mt, foo(_))` or any compound term instead.  This is
  not a real limit for SPSE4 (every asserted fact is at least
  `task/1` or larger), but worth knowing if you are using `mt_store`
  standalone.
- **Reads are RAM-cached, not read-through.**  After other processes
  modify the database, this backend will not see the changes until
  reconnect.
- **No connection pool; single ODBC handle.**  Throughput is bounded
  by the speed of a single MariaDB connection.

The planned third backend addresses all three.

## Vocabulary mapping

| SPSE2                      | This pack                         |
|----------------------------|-----------------------------------|
| `holds(Context, Fact)`     | `ist(Context, Fact)`              |
| context inheritance (ad hoc) | `specialization/2`, `genlMt/2`  |

| Cyc                        | This pack                         |
|----------------------------|-----------------------------------|
| `(ist Mt Fact)`            | `ist(Mt, Fact)`                   |
| `(genlMt Sub Super)`       | `genlMt(Sub, Super)`              |

## Tests

The memory-backend tests run unconditionally:

```sh
swipl -g "[t/mt_store], run_tests" -t halt prolog/mt_store.pl
```

The MySQL-backend tests skip cleanly when no MySQL is available.  To
enable them, point them at a test database (separate from production —
the tests TRUNCATE tables on every test):

```sh
export SPSE4_MYSQL_DSN=spse4_test
swipl -g "[t/mt_store_mysql], run_tests" -t halt prolog/mt_store_mysql.pl
```

## Status

v0.2 — MySQL backend usable; memory backend unchanged.  Roadmap:

- Third backend: SQL-direct rewrite of `prolog-mysql-store`
  (proper connection pooling, true read-through caching with
  invalidation, prepared statements, transparent persistence)
- Lifting rules (Guha's cross-context inference)
- Default reasoning with exceptions
- Export to CycL text
- Export to RDF/Turtle

## License

GPLv3.
