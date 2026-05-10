/*  pack-mt-store -- MySQL-backed microtheory store backend.

    Part of FRKCSA / SPSE4.  GPLv3 License.

    Implements the BACKEND CALLBACK INTERFACE documented in
    =mt_store.pl=.  Storage is split between two layers:

      * User facts (=task/1=, =task_property/3=, =edge/3=,
        =edge_property/5=, plus anything else asserted via
        =mt_assert/2=) go through =prolog-mysql-store=, which gives
        us argument indexing, content hashing, and an in-RAM cache
        seeded from MySQL on first reference.

      * Microtheory-level metadata (registry, properties,
        specialization edges, ACL grants, audit log) live in five
        small tables defined by =sql/spse4_addon.sql=.  These are
        accessed via direct ODBC because their query patterns
        (enumerate all mts, list all ACL entries for a user, audit
        log time range scans) don't match =prolog-mysql-store='s
        per-functor cache model.

    Concurrency model:

      Single ODBC handle (because that is what =prolog-mysql-store=
      gives us), guarded by =with_mutex(spse4_mt_mysql, _)= around
      every callback.  Concurrent requests through SWI's HTTP server
      thus serialize on this lock.  This matches SPSE4's actual
      workload (light writes, mostly reads) and keeps the failure
      story simple.  A future SQL-direct backend with its own pool
      can register itself as a third backend without touching this
      module.

    Failure model:

      ODBC errors propagate out unchanged.  Callers (the SPSE4 server)
      surface them as 503 to clients.  No automatic retry, no
      automatic reconnect, no silent fallback to memory.  An
      explicit =mt_store_mysql_reconnect/0= predicate is provided
      for ops use.

    Initialization:

      Call =mt_store_mysql_init(+Options)= once at server startup,
      then =backend_register(mt_store_mysql)= to make it the active
      backend.  Options:

        * connection_id(+Atom)   ODBC alias to use (also used as
                                 =prolog-mysql-store= ConnectionId)
        * dsn(+Atom)             ODBC DSN name (informational; the
                                 actual DSN lookup is done by ODBC
                                 from the =connection_id=)
        * user(+Atom)            DB user (passed through; modern
                                 ODBC configs may store this in
                                 ~/.odbc.ini and ignore it)
        * password(+String)      DB password (same caveat)
        * database(+Atom)        DB schema name (informational only;
                                 actual schema is per the DSN)

      Schema setup is *not* automatic.  Run
      =sql/spse4_schema.sql=  (= prolog-mysql-store's schema.sql,
      copied here for v0.3.0) and then =sql/spse4_addon.sql= against
      a fresh database before first use.  See the README for the
      one-liner.
*/

:- module(mt_store_mysql,
          [ mt_store_mysql_init/1,                % +Options
            mt_store_mysql_shutdown/0,
            mt_store_mysql_reconnect/0,
            mt_store_mysql_connection/1,          % -ConnectionId

            % Backend callback interface (see mt_store.pl).
            backend_init/1,
            backend_shutdown/0,

            backend_mt_create/1,
            backend_mt_exists/1,
            backend_mt_list/1,
            backend_mt_set_property/3,
            backend_mt_property/3,

            backend_mt_specialize/2,
            backend_specialization/2,

            backend_assert/2,
            backend_retract/2,
            backend_ist/2,

            backend_acl_grant/3,
            backend_acl_revoke/3,
            backend_acl/3,

            backend_audit_add/5,
            backend_audit/5
          ]).

:- use_module(library(odbc)).
:- use_module(library(mysql_store)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(error)).

/** <module> MySQL backend for mt_store

See the file-header comment for the architectural overview.  This
module's predicates are all callbacks; users normally never call
them directly, only through =mt_store='s public API after
=backend_register(mt_store_mysql)= has been called.
*/

% ---------------------------------------------------------------------
% Connection state
% ---------------------------------------------------------------------

:- dynamic conn_/1.    % conn_(ConnectionId) -- the live connection.

%!  mt_store_mysql_connection(-ConnectionId) is semidet.
%
%   True when a MySQL connection has been established.

mt_store_mysql_connection(C) :-
    conn_(C).

% ---------------------------------------------------------------------
% Initialization & shutdown
% ---------------------------------------------------------------------

%!  mt_store_mysql_init(+Options) is det.
%
%   Open the ODBC connection, set up =prolog-mysql-store=, verify
%   that the SPSE4 metadata schema is present, and prime the
%   microtheory registry from existing rows in =mt_registry=.
%
%   Options are documented in the file header.  =connection_id= is
%   required; the rest are passed to =store_connect/5= but most
%   modern ODBC configurations will ignore them in favor of
%   =~/.odbc.ini=.
%
%   Throws =error(spse4_mysql_unavailable(Reason), _)= if the
%   connection cannot be established or the SPSE4 schema is missing.

mt_store_mysql_init(Options) :-
    must_be(list, Options),
    option(connection_id(Conn), Options),
    must_be(atom, Conn),
    option(dsn(_DSN),       Options, Conn),     % informational
    option(user(User),      Options, ''),
    option(password(Pass),  Options, ''),
    option(database(DB),    Options, ''),
    catch(
        store_connect(Conn, '', DB, User, Pass),
        Err,
        throw(error(spse4_mysql_unavailable(Err), _))
    ),
    catch(
        verify_spse4_schema_(Conn),
        Err2,
        ( catch(store_disconnect(Conn), _, true),
          throw(error(spse4_mysql_unavailable(Err2), _))
        )
    ),
    retractall(conn_(_)),
    assertz(conn_(Conn)),
    prime_context_cache_(Conn).

%  Prime prolog-mysql-store's context cache with every existing
%  microtheory.  Without this, calls into store_assert/store_call
%  for a microtheory created in an earlier session would create a
%  brand-new context row each time we encountered it (or, more
%  likely, fail when the context already exists but isn't yet in
%  RAM).  store_ensure_context/2 is idempotent: it picks up the
%  existing context_id if the row exists, or creates one.

prime_context_cache_(Conn) :-
    forall(known_mt_(Conn, Mt),
           store_ensure_context(Conn, Mt)).

%!  mt_store_mysql_shutdown is det.
%
%   Close the connection.  Idempotent.

mt_store_mysql_shutdown :-
    (   conn_(Conn)
    ->  catch(store_disconnect(Conn), _, true),
        retractall(conn_(_))
    ;   true
    ).

%!  mt_store_mysql_reconnect is det.
%
%   Close and reopen the connection using the same connection_id.
%   Useful after MySQL was bounced.  Throws if reconnect fails.

mt_store_mysql_reconnect :-
    (   conn_(Conn)
    ->  catch(store_disconnect(Conn), _, true),
        retractall(conn_(_)),
        catch(
            store_connect(Conn, '', '', '', ''),
            Err,
            throw(error(spse4_mysql_unavailable(Err), _))
        ),
        verify_spse4_schema_(Conn),
        assertz(conn_(Conn)),
        prime_context_cache_(Conn)
    ;   throw(error(spse4_mysql_not_initialized, _))
    ).

% Verify that our addon tables exist.  prolog-mysql-store's own
% ensure_schema/1 already checks for `contexts`; we additionally need
% mt_registry, mt_property, mt_specialization, mt_acl, and mt_audit.

verify_spse4_schema_(Conn) :-
    forall(member(T, [mt_registry, mt_property, mt_specialization,
                      mt_acl, mt_audit]),
           ( format(atom(Q), 'DESCRIBE ~w', [T]),
             catch(odbc_query(Conn, Q, _),
                   _,
                   throw(error(spse4_schema_missing(T),
                               context('Run sql/spse4_addon.sql against the database first')))) )).

% Enumerate microtheories already known to the database, so we can
% prime the in-RAM context cache.  Reads directly from the addon
% table (not from prolog-mysql-store's `contexts`, which only knows
% about contexts that have ever had something asserted into them).

known_mt_(Conn, Mt) :-
    Q = 'SELECT mt_name FROM mt_registry',
    odbc_query(Conn, Q, row(MtStr)),
    atom_string(Mt, MtStr).

% ---------------------------------------------------------------------
% Backend callbacks (BACKEND CALLBACK INTERFACE -- see mt_store.pl)
% ---------------------------------------------------------------------
%
% Every callback is wrapped in with_mutex/2 so that the single ODBC
% handle is never used by two threads at once.  The mutex name is
% module-private; it is created on first use.

backend_init(Options) :-
    mt_store_mysql_init(Options).

backend_shutdown :-
    mt_store_mysql_shutdown.

% --- microtheory registry ---

backend_mt_create(Mt) :-
    with_mutex(spse4_mt_mysql, mt_create_locked_(Mt)).

mt_create_locked_(Mt) :-
    conn_(Conn),
    sql_atom_(Mt, MtSql),
    %  Idempotent: ON DUPLICATE KEY UPDATE on the unique mt_name.
    format(atom(Q),
           "INSERT INTO mt_registry (mt_name) VALUES ('~w') \c
            ON DUPLICATE KEY UPDATE mt_name = mt_name",
           [MtSql]),
    odbc_query(Conn, Q, _),
    %  Also ensure the prolog-mysql-store context exists, so later
    %  store_assert calls don't try to create a context row of their
    %  own (which would race with concurrent backend_assert calls).
    store_ensure_context(Conn, Mt).

backend_mt_exists(Mt) :-
    (   nonvar(Mt)
    ->  with_mutex(spse4_mt_mysql, mt_exists_ground_locked_(Mt))
    ;   with_mutex(spse4_mt_mysql,
                   findall(M, list_all_mts_(M), Ms)),
        member(Mt, Ms)
    ).

% Mode-dispatched on Mt: ground vs unbound.  Most call sites
% (mt_create/2, mt_assert/3, etc.) all check existence with the mt
% name in hand; mt_list/1 and rare uses of mt_exists/1 enumerate.
% Splitting the modes lets us keep the snapshot-and-yield pattern
% clean for the enumeration case.

mt_exists_ground_locked_(Mt) :-
    conn_(Conn),
    sql_atom_(Mt, MtSql),
    format(atom(Q),
           "SELECT 1 FROM mt_registry WHERE mt_name = '~w'", [MtSql]),
    once(odbc_query(Conn, Q, row(_))).

list_all_mts_(Mt) :-
    conn_(Conn),
    odbc_query(Conn, 'SELECT mt_name FROM mt_registry ORDER BY mt_name',
               row(MtStr)),
    atom_string(Mt, MtStr).

backend_mt_list(Mts) :-
    with_mutex(spse4_mt_mysql, findall(M, list_all_mts_(M), Mts)).

% --- properties ---

backend_mt_set_property(Mt, Key, Value) :-
    with_mutex(spse4_mt_mysql, set_property_locked_(Mt, Key, Value)).

set_property_locked_(Mt, Key, Value) :-
    conn_(Conn),
    sql_atom_(Mt, MtSql),
    sql_atom_(Key, KeySql),
    term_to_value_string_(Value, ValueSql),
    %  Replace any prior value: DELETE then INSERT.  We can't use
    %  REPLACE INTO because the PK on mt_property is composite
    %  (mt_name, key) and we want to preserve the recorded_at if
    %  Mt+Key happens to repeat, but for set_property we always want
    %  the latest stamp, so a delete+insert is correct.
    format(atom(DelQ),
           "DELETE FROM mt_property WHERE mt_name = '~w' AND prop_key = '~w'",
           [MtSql, KeySql]),
    odbc_query(Conn, DelQ, _),
    format(atom(InsQ),
           "INSERT INTO mt_property (mt_name, prop_key, prop_value) \c
            VALUES ('~w', '~w', '~w')",
           [MtSql, KeySql, ValueSql]),
    odbc_query(Conn, InsQ, _).

%  We support both modes: Mt ground (the common case from
%  mt_can_read/_write) and Mt unbound (rare, but mt_property/3's
%  spec allows it).  We always select all three columns so the
%  result list is uniform.

backend_mt_property(Mt, Key, Value) :-
    with_mutex(spse4_mt_mysql,
               findall(M-K-V, prop_row_(Mt, M, K, V), Triples)),
    member(Mt-Key-Value, Triples).

prop_row_(MtIn, Mt, Key, Value) :-
    conn_(Conn),
    (   nonvar(MtIn)
    ->  sql_atom_(MtIn, MtSql),
        format(atom(Q),
               "SELECT mt_name, prop_key, prop_value FROM mt_property \c
                WHERE mt_name = '~w'", [MtSql])
    ;   Q = 'SELECT mt_name, prop_key, prop_value FROM mt_property'
    ),
    odbc_query(Conn, Q, row(MtStr, KeyStr, ValueStr)),
    atom_string(Mt, MtStr),
    atom_string(Key, KeyStr),
    value_string_to_term_(ValueStr, Value).

% --- specialization ---

backend_mt_specialize(Sub, Super) :-
    with_mutex(spse4_mt_mysql, specialize_locked_(Sub, Super)).

specialize_locked_(Sub, Super) :-
    conn_(Conn),
    sql_atom_(Sub, SubSql),
    sql_atom_(Super, SuperSql),
    format(atom(Q),
           "INSERT INTO mt_specialization (sub_name, super_name) \c
            VALUES ('~w', '~w') \c
            ON DUPLICATE KEY UPDATE sub_name = sub_name",
           [SubSql, SuperSql]),
    odbc_query(Conn, Q, _).

backend_specialization(Sub, Super) :-
    with_mutex(spse4_mt_mysql,
               findall(S-Sp, spec_row_(S, Sp), Pairs)),
    member(Sub-Super, Pairs).

spec_row_(Sub, Super) :-
    conn_(Conn),
    odbc_query(Conn,
        'SELECT sub_name, super_name FROM mt_specialization',
        row(SubStr, SuperStr)),
    atom_string(Sub, SubStr),
    atom_string(Super, SuperStr).

% --- user facts (task/task_property/edge/edge_property/etc.) ---
%
% These ride through prolog-mysql-store, which gives us the
% formulae table + argument indexing + cache.  We pass the
% microtheory atom as the prolog-mysql-store "context".

backend_assert(Mt, Fact) :-
    with_mutex(spse4_mt_mysql, assert_locked_(Mt, Fact)).

assert_locked_(Mt, Fact) :-
    conn_(Conn),
    %  store_assert/2 expects Context:Term.  prolog-mysql-store
    %  treats `Context:Term` specially in its term-decomposition step
    %  (see mysql_store.pl line 172).  This is the documented entry
    %  point for putting a fact into a non-`user` context.
    store_assert(Conn, Mt:Fact).

backend_retract(Mt, Fact) :-
    with_mutex(spse4_mt_mysql, retract_locked_(Mt, Fact)).

retract_locked_(Mt, Fact) :-
    conn_(Conn),
    %  store_retract/2 is nondet (matches first subsuming term).
    %  We want deterministic no-op-if-absent semantics.  once/1
    %  cuts after the first match; the catch handles "no match"
    %  cleanly because store_retract simply fails in that case
    %  rather than throwing.
    (   catch(once(store_retract(Conn, Mt:Fact)), _, fail)
    ->  true
    ;   true
    ).

backend_ist(Mt, Pattern) :-
    %  store_call/2 reads from prolog-mysql-store's per-context
    %  predicate cache, falling back to a SQL load on first reference
    %  for each (functor, arity).  We hold the mutex during the
    %  enumeration to avoid interleaving with concurrent assertions
    %  that would mutate the cache mid-traversal.
    %
    %  We snapshot solutions into a list under the lock, then yield
    %  outside it, so backtracking through results doesn't hold the
    %  mutex across user code (which could call back into the store
    %  and deadlock).  copy_term gives store_call a fresh skeleton to
    %  bind, so the user's Pattern keeps its variables until member/2
    %  unifies each solution with it on the way out.
    with_mutex(spse4_mt_mysql,
               findall(Solution, ist_one_(Mt, Pattern, Solution), Solutions)),
    member(Pattern, Solutions).

ist_one_(Mt, Pattern, Solution) :-
    conn_(Conn),
    copy_term(Pattern, Solution),
    store_call(Conn, Mt:Solution).

% --- ACL ---

backend_acl_grant(User, Access, Mt) :-
    with_mutex(spse4_mt_mysql, acl_grant_locked_(User, Access, Mt)).

acl_grant_locked_(User, Access, Mt) :-
    conn_(Conn),
    sql_atom_(User, UserSql),
    sql_atom_(Access, AccessSql),
    sql_atom_(Mt, MtSql),
    format(atom(Q),
           "INSERT INTO mt_acl (mt_name, user_name, access) \c
            VALUES ('~w', '~w', '~w') \c
            ON DUPLICATE KEY UPDATE access = access",
           [MtSql, UserSql, AccessSql]),
    odbc_query(Conn, Q, _).

backend_acl_revoke(User, Access, Mt) :-
    with_mutex(spse4_mt_mysql, acl_revoke_locked_(User, Access, Mt)).

acl_revoke_locked_(User, Access, Mt) :-
    conn_(Conn),
    sql_atom_(User, UserSql),
    sql_atom_(Access, AccessSql),
    sql_atom_(Mt, MtSql),
    format(atom(Q),
           "DELETE FROM mt_acl WHERE mt_name = '~w' \c
            AND user_name = '~w' AND access = '~w'",
           [MtSql, UserSql, AccessSql]),
    odbc_query(Conn, Q, _).

backend_acl(User, Access, Mt) :-
    with_mutex(spse4_mt_mysql,
               findall(U-A-M, acl_row_(U, A, M), Triples)),
    member(User-Access-Mt, Triples).

acl_row_(User, Access, Mt) :-
    conn_(Conn),
    odbc_query(Conn,
        'SELECT user_name, access, mt_name FROM mt_acl',
        row(UStr, AStr, MStr)),
    atom_string(User, UStr),
    atom_string(Access, AStr),
    atom_string(Mt, MStr).

% --- audit log ---

backend_audit_add(Mt, When, User, Op, Fact) :-
    with_mutex(spse4_mt_mysql, audit_add_locked_(Mt, When, User, Op, Fact)).

audit_add_locked_(Mt, When, User, Op, Fact) :-
    conn_(Conn),
    sql_atom_(Mt, MtSql),
    sql_atom_(User, UserSql),
    sql_atom_(Op, OpSql),
    term_to_value_string_(Fact, FactSql),
    %  When comes from get_time/1: Unix epoch seconds as float.
    %  Store it raw so we don't lose sub-second precision.
    format(atom(Q),
           "INSERT INTO mt_audit \c
              (mt_name, recorded_at_epoch, user_name, op, fact) \c
            VALUES ('~w', ~6f, '~w', '~w', '~w')",
           [MtSql, When, UserSql, OpSql, FactSql]),
    odbc_query(Conn, Q, _).

backend_audit(Mt, When, User, Op, Fact) :-
    with_mutex(spse4_mt_mysql,
               findall(audit(M,W,U,O,F), audit_row_(M,W,U,O,F), Rows)),
    member(audit(Mt, When, User, Op, Fact), Rows).

audit_row_(Mt, When, User, Op, Fact) :-
    conn_(Conn),
    odbc_query(Conn,
        'SELECT mt_name, recorded_at_epoch, user_name, op, fact \c
         FROM mt_audit ORDER BY recorded_at_epoch',
        row(MStr, WhenF, UStr, OStr, FStr)),
    atom_string(Mt, MStr),
    When = WhenF,
    atom_string(User, UStr),
    atom_string(Op, OStr),
    value_string_to_term_(FStr, Fact).

% ---------------------------------------------------------------------
% SQL string utilities
% ---------------------------------------------------------------------
%
% We use ODBC inline-string interpolation for short structured
% identifiers (mt names, user names, atoms) and for serialized term
% strings.  Everything is single-quoted in SQL with embedded quotes
% doubled.  Identifiers must be atoms or strings; we accept both.
%
% This is NOT general-purpose SQL escaping; it is enough for the
% controlled inputs we see (atoms from authenticated SPSE4 calls,
% never raw user input from the web).  If/when this module gains a
% direct SQL-input path, switch to odbc_prepare/odbc_execute with
% bound parameters.

%!  sql_atom_(+Term, -SqlAtom) is det.
%
%   Convert an atom/string/number into a single-quote-safe atom for
%   embedding in SQL.  Throws =type_error= for non-atomic inputs.

sql_atom_(A, Out) :-
    atom(A), !,
    sql_escape_(A, Out).
sql_atom_(S, Out) :-
    string(S), !,
    atom_string(A, S),
    sql_escape_(A, Out).
sql_atom_(N, Out) :-
    number(N), !,
    atom_number(Out, N).
sql_atom_(X, _) :-
    type_error(sql_atomic, X).

% Double single-quotes within the atom for SQL safety.

sql_escape_(In, Out) :-
    atom_codes(In, Codes),
    sql_escape_codes_(Codes, Escaped),
    atom_codes(Out, Escaped).

% 39 is the ASCII code for the single-quote character ('); 92 is the
% backslash (\).  We use the numeric codes here rather than 0''
% literals to keep the parser happy across SWI versions.

sql_escape_codes_([], []).
sql_escape_codes_([39 | T], [39, 39 | T2]) :- !,    % ' -> ''
    sql_escape_codes_(T, T2).
sql_escape_codes_([92 | T], [92, 92 | T2]) :- !,    % \ -> \\
    sql_escape_codes_(T, T2).
sql_escape_codes_([H | T], [H | T2]) :-
    sql_escape_codes_(T, T2).

%!  term_to_value_string_(+Term, -Atom) is det.
%
%   Serialize an arbitrary Prolog term into an SQL-safe atom using
%   write_canonical/1 followed by sql_escape_/2.  Inverse of
%   value_string_to_term_/2.

term_to_value_string_(Term, Out) :-
    with_output_to(atom(Canonical), write_canonical(Term)),
    sql_escape_(Canonical, Out).

%!  value_string_to_term_(+Input, -Term) is det.
%
%   Parse an atom or string containing a canonical Prolog term back
%   into a term.  Used to deserialize property values, fact terms,
%   and audit records loaded from MySQL.  ODBC may give us either an
%   atom or a string back depending on column type and driver
%   version, so we accept both.
%
%   For our schema all values are produced by =write_canonical/1=
%   on the way in, so they should always parse back.  If a row
%   somehow holds non-term text (older data, manual SQL edits), we
%   surface it as a Prolog string rather than throwing.

value_string_to_term_(Input, Term) :-
    (   atom(Input)   -> Atom = Input
    ;   string(Input) -> atom_string(Atom, Input)
    ;   type_error(text, Input)
    ),
    catch(term_to_atom(Term, Atom),
          _,
          atom_string(Atom, Term)).    % Atom -> Term:string
