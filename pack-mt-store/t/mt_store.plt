/*  Tests for pack-mt-store (memory backend).

    These tests exercise the in-memory backend, which is the default
    when no backend is registered.  They use =reset_memory_backend/0=
    to clear state between tests rather than reaching into the
    backend's dynamic predicates directly.

    For MySQL backend tests, see =mt_store_mysql.plt= in this same
    directory; it is skipped automatically when no MySQL is reachable.
*/

:- use_module(library(plunit)).
:- use_module('../prolog/mt_store').

:- begin_tests(mt_store).

% Clean slate before each test group.
setup_clean :-
    % Make sure we're using the default (memory) backend, in case a
    % previous test in the same Prolog session swapped it out.
    mt_store:retractall(current_backend_(_)),
    reset_memory_backend.

test(create_and_list, [setup(setup_clean)]) :-
    mt_create(medical),
    mt_create(financial),
    mt_list(L),
    msort(L, [financial, medical]).

test(assert_and_ist, [setup(setup_clean)]) :-
    mt_create(medical),
    mt_assert(medical, takes(andrew, vitaminD)),
    mt_assert(medical, takes(andrew, magnesium)),
    findall(M, ist(medical, takes(andrew, M)), Ms),
    msort(Ms, [magnesium, vitaminD]).

test(specialization_inherits, [setup(setup_clean)]) :-
    mt_create(general),
    mt_create(medical),
    mt_specialize(medical, general),
    mt_assert(general, organism(andrew, human)),
    mt_assert(medical, takes(andrew, vitaminD)),
    % medical inherits from general:
    once(ist_inherited(medical, organism(andrew, human))),
    % general does NOT inherit from medical:
    \+ ist_inherited(general, takes(andrew, vitaminD)).

test(specialization_cycle_refused,
     [setup(setup_clean), error(domain_error(acyclic_specialization, _))]) :-
    mt_create(a), mt_create(b),
    mt_specialize(a, b),
    mt_specialize(b, a).

test(genlMt_alias, [setup(setup_clean)]) :-
    mt_create(a), mt_create(b),
    mt_specialize(a, b),
    genlMt(a, b).

test(audit_records_assert, [setup(setup_clean)]) :-
    mt_create(medical, [owner=andrew]),
    mt_assert(medical, takes(andrew, vitaminD), andrew),
    mt_audit(medical, audit(_, andrew, assert, takes(andrew, vitaminD))).

test(acl_denies_non_owner,
     [setup(setup_clean), error(permission_error(write, microtheory, medical))]) :-
    mt_create(medical, [owner=andrew]),
    mt_assert(medical, foo, meredith).   % meredith has no grant

test(acl_grant_allows, [setup(setup_clean)]) :-
    mt_create(medical, [owner=andrew]),
    mt_grant(meredith, write, medical),
    mt_assert(medical, foo, meredith).

test(public_mt_readable_by_all, [setup(setup_clean)]) :-
    mt_create(public_kb, [owner=andrew, visibility=public]),
    mt_can_read(anyone, public_kb).

test(retract_is_idempotent, [setup(setup_clean)]) :-
    mt_create(medical, [owner=system]),
    mt_assert(medical, foo),
    mt_retract(medical, foo),
    mt_retract(medical, foo),       % no-op second time
    \+ ist(medical, foo).

:- end_tests(mt_store).
