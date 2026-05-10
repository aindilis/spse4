/*  Tests for pack-spse4-core  */

:- use_module(library(plunit)).
:- use_module('../prolog/spse4_core').
:- use_module(library(mt_store)).

:- begin_tests(spse4_core).

setup_clean :-
    retractall(mt_store:mt_registry_(_)),
    retractall(mt_store:mt_prop_(_,_,_)),
    retractall(mt_store:mt_fact_(_,_)),
    retractall(mt_store:mt_spec_(_,_)),
    retractall(mt_store:mt_acl_(_,_,_)),
    retractall(mt_store:mt_audit_(_,_,_,_,_)).

mk_medical :-
    mt_create(medical, [owner=andrew]).

test(task_create_and_list, [setup((setup_clean, mk_medical))]) :-
    task_create(medical, t1, [has_nl="Call Hart Medical", task_kind=primitive, status=open]),
    task_create(medical, t2, [has_nl="Process O2Ring data", task_kind=primitive, status=open]),
    task_list(medical, Tasks),
    msort(Tasks, [t1, t2]).

test(task_property_typed, [setup((setup_clean, mk_medical))]) :-
    task_create(medical, t1, [has_nl="Foo"]),
    has_nl(medical, t1, "Foo").

test(task_set_property_replaces, [setup((setup_clean, mk_medical))]) :-
    task_create(medical, t1, [has_nl="Old", status=open]),
    task_set_property(medical, t1, status, completed),
    task_property(medical, t1, status, completed),
    \+ task_property(medical, t1, status, open).

test(bad_status_is_rejected,
     [setup((setup_clean, mk_medical)),
      error(type_error(oneof(_), not_a_real_status))]) :-
    task_create(medical, t1, [status=not_a_real_status]).

test(has_nl_must_be_string,
     [setup((setup_clean, mk_medical)),
      error(type_error(string, foo_atom))]) :-
    task_create(medical, t1, [has_nl=foo_atom]).

test(edge_assert_and_retrieve, [setup((setup_clean, mk_medical))]) :-
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    edge_assert(medical, t1, depends, t2, []),
    depends(medical, t1, t2).

test(unknown_edge_kind_refused,
     [setup((setup_clean, mk_medical)),
      error(domain_error(edge_kind, not_a_kind))]) :-
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    edge_assert(medical, t1, not_a_kind, t2, []).

test(blockers_detected, [setup((setup_clean, mk_medical))]) :-
    task_create(medical, t1, [status=open]),
    task_create(medical, t2, [status=open]),
    task_create(medical, t3, [status=completed]),
    edge_assert(medical, t1, depends, t2, []),
    edge_assert(medical, t1, depends, t3, []),
    task_blockers(medical, t1, Bs),
    msort(Bs, [t2]).

test(ready_excludes_completed_and_blocked, [setup((setup_clean, mk_medical))]) :-
    task_create(medical, t1, [status=open]),
    task_create(medical, t2, [status=open]),
    task_create(medical, t3, [status=completed]),
    edge_assert(medical, t2, depends, t1, []),  % t2 blocked on t1
    task_ready(medical, Ready),
    memberchk(t1, Ready),
    \+ memberchk(t2, Ready),
    \+ memberchk(t3, Ready).

test(projection_by_kind, [setup((setup_clean, mk_medical))]) :-
    task_create(medical, t1, [status=open]),
    task_create(medical, t2, [status=open]),
    task_create(medical, t3, [status=open]),
    edge_assert(medical, t1, depends, t2, []),
    edge_assert(medical, t2, attacks, t3, []),
    project_graph(medical, kind(depends), proj(_Nodes, Edges)),
    length(Edges, 1),
    Edges = [edge(t1, depends, t2, _)].

test(projection_by_status, [setup((setup_clean, mk_medical))]) :-
    task_create(medical, t1, [status=open]),
    task_create(medical, t2, [status=completed]),
    project_graph(medical, status(completed), proj(Nodes, _)),
    length(Nodes, 1),
    Nodes = [node(t2, _)].

test(import_spse2_holds, [setup((setup_clean))]) :-
    Holds = [ holds(pse, goal('entry-fn'(pse, 38))),
              holds(pse, 'has-NL'('entry-fn'(pse, 38), "ICAPS 2011 Paper")),
              holds(pse, goal('entry-fn'(pse, 17))),
              holds(pse, 'has-NL'('entry-fn'(pse, 17), "Finish draft")),
              holds(pse, depends('entry-fn'(pse, 38), 'entry-fn'(pse, 17))),
              holds(pse, complete('entry-fn'(pse, 17)))
            ],
    import_spse2_holds(Holds, legacy_pse),
    task_list(legacy_pse, Tasks),
    length(Tasks, 2),
    % The dependency should be present:
    once(depends(legacy_pse, TA, TB)),
    once(has_nl(legacy_pse, TA, "ICAPS 2011 Paper")),
    once(has_nl(legacy_pse, TB, "Finish draft")),
    % The 17 task should be completed:
    forall( has_nl(legacy_pse, T, "Finish draft"),
            completed(legacy_pse, T) ).

% ---------------------------------------------------------------------
% Broadcast event tests (added in v0.2.0).  Each mutating predicate
% must fire a spse4(Event) broadcast that subscribers can listen to.
% ---------------------------------------------------------------------

:- use_module(library(broadcast)).

% Capture broadcast events in a thread-local list for assertion.
:- dynamic captured_event_/1.

capture_setup :-
    retractall(captured_event_(_)),
    listen(spse4_core_test, spse4(E), assertz(captured_event_(E))).

capture_teardown :-
    unlisten(spse4_core_test),
    retractall(captured_event_(_)).

captured(Events) :-
    findall(E, captured_event_(E), Events).

test(broadcast_task_added,
     [setup((setup_clean, mk_medical, capture_setup)),
      cleanup(capture_teardown)]) :-
    task_create(medical, t1, [has_nl="A", status=open]),
    captured(Events),
    memberchk(task_added(medical, t1, [has_nl="A", status=open]), Events).

test(broadcast_task_removed,
     [setup((setup_clean, mk_medical, capture_setup)),
      cleanup(capture_teardown)]) :-
    task_create(medical, t1, [status=open]),
    retractall(captured_event_(_)),  % clear creation event
    task_retract(medical, t1),
    captured(Events),
    memberchk(task_removed(medical, t1), Events).

test(broadcast_task_property_changed,
     [setup((setup_clean, mk_medical, capture_setup)),
      cleanup(capture_teardown)]) :-
    task_create(medical, t1, [status=open]),
    retractall(captured_event_(_)),
    task_set_property(medical, t1, status, completed),
    captured(Events),
    memberchk(task_property_changed(medical, t1, status, completed), Events).

test(broadcast_edge_added,
     [setup((setup_clean, mk_medical, capture_setup)),
      cleanup(capture_teardown)]) :-
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    retractall(captured_event_(_)),
    edge_assert(medical, t1, depends, t2, []),
    captured(Events),
    memberchk(edge_added(medical, t1, depends, t2, []), Events).

test(broadcast_edge_added_idempotent,
     [setup((setup_clean, mk_medical, capture_setup)),
      cleanup(capture_teardown)]) :-
    % Re-asserting an existing edge must NOT re-broadcast edge_added.
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    edge_assert(medical, t1, depends, t2, []),
    retractall(captured_event_(_)),
    edge_assert(medical, t1, depends, t2, []),
    captured(Events),
    \+ memberchk(edge_added(medical, _, _, _, _), Events).

test(broadcast_edge_removed,
     [setup((setup_clean, mk_medical, capture_setup)),
      cleanup(capture_teardown)]) :-
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    edge_assert(medical, t1, depends, t2, []),
    retractall(captured_event_(_)),
    edge_retract(medical, t1, depends, t2),
    captured(Events),
    memberchk(edge_removed(medical, t1, depends, t2), Events).

test(broadcast_edge_removed_absent_silent,
     [setup((setup_clean, mk_medical, capture_setup)),
      cleanup(capture_teardown)]) :-
    % Retracting a nonexistent edge must succeed but NOT broadcast.
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    retractall(captured_event_(_)),
    edge_retract(medical, t1, depends, t2),
    captured(Events),
    \+ memberchk(edge_removed(_, _, _, _), Events).

test(broadcast_task_retract_cascades_edge_removed,
     [setup((setup_clean, mk_medical, capture_setup)),
      cleanup(capture_teardown)]) :-
    % Retracting a task with edges must broadcast edge_removed for
    % each incident edge, in addition to task_removed.
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    task_create(medical, t3, []),
    edge_assert(medical, t1, depends, t2, []),
    edge_assert(medical, t3, depends, t1, []),
    retractall(captured_event_(_)),
    task_retract(medical, t1),
    captured(Events),
    memberchk(task_removed(medical, t1), Events),
    memberchk(edge_removed(medical, t1, depends, t2), Events),
    memberchk(edge_removed(medical, t3, depends, t1), Events).

% ---------------------------------------------------------------------
% edge_set_properties tests (added in v0.2.2).  Replaces the property
% bag on an existing edge in a single transaction; broadcasts a new
% =|edge_property_changed|= event whose payload is the canonical
% Key=Value list.
% ---------------------------------------------------------------------

test(edge_set_properties_replaces_bag, [setup((setup_clean, mk_medical))]) :-
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    edge_assert(medical, t1, depends, t2, [weight=1, note="initial"]),
    edge_set_properties(medical, t1, depends, t2, [weight=5, urgency=high]),
    edge_property(medical, t1, depends, t2, Pairs),
    msort(Pairs, Sorted),
    msort([urgency=high, weight=5], Sorted).

test(edge_set_properties_clears_when_empty,
     [setup((setup_clean, mk_medical))]) :-
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    edge_assert(medical, t1, depends, t2, [weight=3, note="x"]),
    edge_set_properties(medical, t1, depends, t2, []),
    edge_property(medical, t1, depends, t2, []).

test(edge_set_properties_missing_edge_throws,
     [setup((setup_clean, mk_medical)),
      error(existence_error(edge, edge(t1, depends, t2)))]) :-
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    edge_set_properties(medical, t1, depends, t2, [weight=1]).

test(broadcast_edge_property_changed,
     [setup((setup_clean, mk_medical, capture_setup)),
      cleanup(capture_teardown)]) :-
    task_create(medical, t1, []),
    task_create(medical, t2, []),
    edge_assert(medical, t1, depends, t2, []),
    retractall(captured_event_(_)),
    edge_set_properties(medical, t1, depends, t2, [weight=5]),
    captured(Events),
    memberchk(edge_property_changed(medical, t1, depends, t2, [weight=5]),
              Events).

:- end_tests(spse4_core).
