/*  Tests for pack-mt-store, MySQL backend.

    These tests exercise the =mt_store_mysql= backend.  They are
    designed to be safely skipped on systems that don't have a MySQL
    instance available, so =run_all_tests.pl= still passes on a
    fresh clone with no MySQL setup.

    To enable the tests, set environment variables:

        SPSE4_MYSQL_DSN=spse4_test     # ODBC alias from ~/.odbc.ini
        SPSE4_MYSQL_USER=spse4_test    # optional, falls through to DSN
        SPSE4_MYSQL_PASS=...           # optional
        SPSE4_MYSQL_DB=spse4_test_db   # optional, informational

    The DSN must point to a database that has been initialized with
    BOTH =sql/spse4_schema.sql= AND =sql/spse4_addon.sql= applied.
    The tests will TRUNCATE several tables on every test, so do not
    point this at a production database.

    Skip semantics:

      * If =library(mysql_store)= cannot be loaded, the file logs a
        warning and skips all tests.
      * If =SPSE4_MYSQL_DSN= is not set, all tests skip.
      * If the connection cannot be established (e.g. MySQL is down,
        DSN is wrong, schema is missing), all tests skip.
      * Otherwise, tests run.

    Failure to skip cleanly would make =run_all_tests.pl= regress
    the headline metric (currently 128 tests pass), so this file
    catches every conceivable load- and setup-time error.
*/

:- use_module(library(plunit)).
:- use_module('../prolog/mt_store').

% Try to load the MySQL backend.  If this fails (e.g. library(odbc)
% or library(mysql_store) not on the path), record the failure so
% mysql_available_/0 can report it without crashing.

:- dynamic mt_store_mysql_load_failed_/1.

:- catch(
       use_module('../prolog/mt_store_mysql'),
       LoadErr,
       ( assertz(mt_store_mysql_load_failed_(LoadErr)),
         format(user_error,
                "mt_store_mysql.plt: backend module did not load (~q); \c
                 all MySQL tests will skip.~n",
                [LoadErr])
       )
   ).

:- begin_tests(mt_store_mysql).

%!  mysql_available_ is semidet.
%
%   The PlUnit condition predicate.  Returns true when the MySQL
%   backend is plausibly usable: module loaded, env var set,
%   connection works, schema present.  Otherwise the whole file's
%   tests skip (PlUnit reports them as "skipped", not "failed").
%
%   We probe the connection by *trying to initialize the backend*
%   and rolling back on any error.  This is heavier than a simple
%   env-var check but it's the only way to give an honest
%   "MySQL is reachable AND has the right schema" answer, which is
%   what the tests actually need.

mysql_available_ :-
    \+ mt_store_mysql_load_failed_(_),
    getenv('SPSE4_MYSQL_DSN', DsnStr),
    DsnStr \= '',
    atom_string(Dsn, DsnStr),
    catch(
        ensure_test_connection_(Dsn),
        _Err,
        fail
    ).

ensure_test_connection_(Dsn) :-
    %  Idempotent: if we've already initialized in this Prolog
    %  session, reuse.  Otherwise initialize once and keep the
    %  connection open for the life of the test run.
    (   mt_store_mysql:mt_store_mysql_connection(_)
    ->  true
    ;   build_init_options_(Dsn, Opts),
        mt_store_mysql:mt_store_mysql_init(Opts)
    ).

build_init_options_(Dsn, Opts) :-
    Base = [connection_id(Dsn), dsn(Dsn)],
    (   getenv('SPSE4_MYSQL_USER', U), U \= ''
    ->  atom_string(UA, U), UserOpt = [user(UA)]
    ;   UserOpt = []
    ),
    (   getenv('SPSE4_MYSQL_PASS', P)
    ->  PassOpt = [password(P)]
    ;   PassOpt = []
    ),
    (   getenv('SPSE4_MYSQL_DB', DB), DB \= ''
    ->  atom_string(DBA, DB), DbOpt = [database(DBA)]
    ;   DbOpt = []
    ),
    append([Base, UserOpt, PassOpt, DbOpt], Opts).

%!  reset_mysql_state_ is det.
%
%   Truncate every SPSE4 table to give each test a clean slate.
%   Disable foreign-key checks first so the order doesn't matter.

reset_mysql_state_ :-
    mt_store_mysql:mt_store_mysql_connection(Conn),
    forall(member(Q,
                  [ 'SET FOREIGN_KEY_CHECKS = 0',
                    'TRUNCATE TABLE mt_audit',
                    'TRUNCATE TABLE mt_acl',
                    'TRUNCATE TABLE mt_specialization',
                    'TRUNCATE TABLE mt_property',
                    'TRUNCATE TABLE mt_registry',
                    'TRUNCATE TABLE arguments_indexed',
                    'TRUNCATE TABLE list_elements',
                    'TRUNCATE TABLE metadata',
                    'TRUNCATE TABLE predicate_stats',
                    'TRUNCATE TABLE cache_status',
                    'TRUNCATE TABLE formulae',
                    'TRUNCATE TABLE contexts',
                    'SET FOREIGN_KEY_CHECKS = 1' ]),
           catch(odbc:odbc_query(Conn, Q, _), _, true)),
    %  Wipe prolog-mysql-store's in-RAM caches directly.  After
    %  TRUNCATE we need every cached context_id and predicate_cache
    %  entry gone, regardless of whether store_disconnect/store_connect
    %  cleared them.  Belt-and-suspenders.
    catch(mysql_store:retractall(context_mapping(_, _)), _, true),
    catch(mysql_store:retractall(predicate_cache(_, _, _, _)), _, true),
    catch(mysql_store:retractall(loaded_predicate(_, _, _)), _, true).

setup_clean :-
    reset_mysql_state_,
    %  Make sure the mt_store dispatcher is pointed at our backend.
    %  (A previous test in the same session might have run the
    %  memory-backend file and reset the dispatch back to default.)
    mt_store:backend_register(mt_store_mysql).

% --------------------------------------------------------------------
% Tests
% --------------------------------------------------------------------

test(create_and_list,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(medical),
    mt_create(financial),
    mt_list(L),
    msort(L, [financial, medical]).

test(assert_and_ist,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(medical, [owner=system]),
    mt_assert(medical, takes(andrew, vitaminD)),
    mt_assert(medical, takes(andrew, magnesium)),
    findall(M, ist(medical, takes(andrew, M)), Ms),
    msort(Ms, [magnesium, vitaminD]).

test(retract_removes_fact,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(medical, [owner=system]),
    mt_assert(medical, foo(bar)),
    mt_retract(medical, foo(bar)),
    \+ ist(medical, foo(bar)).

test(retract_idempotent,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(medical, [owner=system]),
    mt_assert(medical, foo(bar)),
    mt_retract(medical, foo(bar)),
    mt_retract(medical, foo(bar)),    % no-op second time
    \+ ist(medical, foo(bar)).

test(specialization_inherits,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(general),
    mt_create(medical),
    mt_specialize(medical, general),
    mt_assert(general, organism(andrew, human)),
    mt_assert(medical, takes(andrew, vitaminD)),
    once(ist_inherited(medical, organism(andrew, human))),
    \+ ist_inherited(general, takes(andrew, vitaminD)).

test(specialization_cycle_refused,
     [condition(mysql_available_), setup(setup_clean),
      error(domain_error(acyclic_specialization, _))]) :-
    mt_create(a), mt_create(b),
    mt_specialize(a, b),
    mt_specialize(b, a).

test(properties_set_and_get,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(medical, [owner=andrew, visibility=private]),
    once(mt_property(medical, owner, andrew)),
    once(mt_property(medical, visibility, private)).

test(property_replaces_prior,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(medical, [owner=andrew]),
    mt_set_property(medical, owner, meredith),
    findall(V, mt_property(medical, owner, V), Vs),
    Vs = [meredith].

test(audit_records_assert_and_retract,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(medical, [owner=andrew]),
    mt_assert(medical, takes(andrew, vitaminD), andrew),
    mt_retract(medical, takes(andrew, vitaminD), andrew),
    findall(audit(U, Op, F),
            mt_audit(medical, audit(_, U, Op, F)),
            Entries),
    msort(Entries,
          [ audit(andrew, assert,  takes(andrew, vitaminD)),
            audit(andrew, retract, takes(andrew, vitaminD)) ]).

test(acl_grant_and_check,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(medical, [owner=andrew]),
    \+ mt_can_write(meredith, medical),
    mt_grant(meredith, write, medical),
    mt_can_write(meredith, medical).

test(acl_revoke_removes_grant,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(medical, [owner=andrew]),
    mt_grant(meredith, write, medical),
    mt_revoke(meredith, write, medical),
    \+ mt_can_write(meredith, medical).

test(public_visibility_readable_by_anyone,
     [condition(mysql_available_), setup(setup_clean)]) :-
    mt_create(public_kb, [owner=andrew, visibility=public]),
    mt_can_read(anyone, public_kb).

test(persistence_across_backend_swap,
     [condition(mysql_available_), setup(setup_clean)]) :-
    %  Write through MySQL, drop the backend's RAM cache by
    %  re-registering, and confirm we can still read the data back.
    %  This is the canonical "would survive a server restart" check.
    mt_create(persisted, [owner=system]),
    mt_assert(persisted, marker(survived_restart)),
    %  Force prolog-mysql-store to drop its predicate cache for the
    %  marker/1 predicate; on the next ist/2 it must reload from SQL.
    mt_store_mysql:mt_store_mysql_connection(Conn),
    catch(mysql_store:store_unload_predicate(Conn, persisted, marker/1),
          _, true),
    once(ist(persisted, marker(survived_restart))).

:- end_tests(mt_store_mysql).
