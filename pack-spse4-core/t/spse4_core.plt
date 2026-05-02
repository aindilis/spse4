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

:- end_tests(spse4_core).
