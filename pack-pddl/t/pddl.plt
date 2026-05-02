/*  Tests for pack-pddl */

:- use_module(library(plunit)).
:- use_module('../prolog/pddl').

:- begin_tests(pddl).

% ---------------------------------------------------------------------
% Small input helpers
% ---------------------------------------------------------------------

minimal_domain_string(S) :-
    S = "(define (domain minimal)
           (:requirements :strips)
           (:predicates (p) (q))
           (:action act
             :parameters ()
             :precondition (p)
             :effect (q)))".

typed_domain_string(S) :-
    S = "(define (domain typed-dom)
           (:requirements :strips :typing)
           (:types loc item)
           (:predicates
             (at ?x - item ?l - loc)
             (connected ?a ?b - loc))
           (:action move
             :parameters (?x - item ?from ?to - loc)
             :precondition (and (at ?x ?from) (connected ?from ?to))
             :effect (and (not (at ?x ?from)) (at ?x ?to))))".

durative_domain_string(S) :-
    S = "(define (domain dur)
           (:requirements :strips :typing :durative-actions)
           (:types task)
           (:predicates (done ?t - task))
           (:durative-action complete
             :parameters (?t - task)
             :duration (= ?duration 10)
             :condition (over all (not (done ?t)))
             :effect (at end (done ?t))))".

minimal_problem_string(S) :-
    S = "(define (problem prob1)
           (:domain minimal)
           (:init (p))
           (:goal (q)))".

htn_domain_string(S) :-
    S = "(define (domain htn)
           (:requirements :strips :typing :hddl)
           (:types thing)
           (:predicates (clean ?x - thing) (wet ?x - thing))
           (:action wash :parameters (?x - thing) :precondition () :effect (wet ?x))
           (:action dry  :parameters (?x - thing) :precondition (wet ?x) :effect (clean ?x))
           (:method m-clean
             :parameters (?x - thing)
             :task (get-clean ?x)
             :ordered-subtasks (and (wash ?x) (dry ?x))))".

% ---------------------------------------------------------------------
% Basic parsing
% ---------------------------------------------------------------------

test(parse_minimal_domain) :-
    minimal_domain_string(S),
    pddl_parse_string(S, AST),
    AST = domain(minimal, Sections),
    memberchk(requirements([strips]), Sections),
    memberchk(predicates([predicate(p, []), predicate(q, [])]), Sections).

test(parse_minimal_action) :-
    minimal_domain_string(S),
    pddl_parse_string(S, domain(_, Sections)),
    memberchk(action(act, [], p, q), Sections).

test(parse_typed_domain) :-
    typed_domain_string(S),
    pddl_parse_string(S, AST),
    AST = domain('typed-dom', Sections),
    memberchk(types([typed(loc, object), typed(item, object)]), Sections),
    memberchk(predicates(Preds), Sections),
    memberchk(predicate(at, [typed(x, item), typed(l, loc)]), Preds),
    memberchk(predicate(connected, [typed(a, loc), typed(b, loc)]), Preds).

test(parse_typed_action_params) :-
    typed_domain_string(S),
    pddl_parse_string(S, domain(_, Sections)),
    memberchk(action(move, Params, _Pre, _Eff), Sections),
    Params = [typed(x, item), typed(from, loc), typed(to, loc)].

test(parse_durative_action) :-
    durative_domain_string(S),
    pddl_parse_string(S, domain(dur, Sections)),
    memberchk(durative_action(complete, [typed(t, task)], _Dur, _Cond, _Eff), Sections).

test(parse_minimal_problem) :-
    minimal_problem_string(S),
    pddl_parse_string(S, AST),
    AST = problem(prob1, Sections),
    memberchk(domain_ref(minimal), Sections),
    memberchk(init([p]), Sections),
    memberchk(goal(q), Sections).

test(parse_htn_method) :-
    htn_domain_string(S),
    pddl_parse_string(S, AST),
    AST = domain(htn, Sections),
    memberchk(method('m-clean', [typed(x, thing)], _Task, _Subtasks), Sections).

% ---------------------------------------------------------------------
% Emit + round-trip
% ---------------------------------------------------------------------

test(emit_minimal) :-
    minimal_domain_string(S),
    pddl_parse_string(S, AST),
    pddl_emit(AST, Emitted),
    string(Emitted),
    string_length(Emitted, L),
    L > 50.

test(roundtrip_minimal) :-
    minimal_domain_string(S),
    pddl_parse_string(S, AST1),
    pddl_emit(AST1, Emitted),
    pddl_parse_string(Emitted, AST2),
    AST1 == AST2.

test(roundtrip_typed) :-
    typed_domain_string(S),
    pddl_parse_string(S, AST1),
    pddl_emit(AST1, Emitted),
    pddl_parse_string(Emitted, AST2),
    AST1 == AST2.

test(roundtrip_durative) :-
    durative_domain_string(S),
    pddl_parse_string(S, AST1),
    pddl_emit(AST1, Emitted),
    pddl_parse_string(Emitted, AST2),
    AST1 == AST2.

test(roundtrip_problem) :-
    minimal_problem_string(S),
    pddl_parse_string(S, AST1),
    pddl_emit(AST1, Emitted),
    pddl_parse_string(Emitted, AST2),
    AST1 == AST2.

% ---------------------------------------------------------------------
% Feature detection and planner matching
% ---------------------------------------------------------------------

test(features_minimal) :-
    minimal_domain_string(S),
    pddl_parse_string(S, AST),
    pddl_features_used(AST, Features),
    memberchk(strips, Features).

test(features_durative) :-
    durative_domain_string(S),
    pddl_parse_string(S, AST),
    pddl_features_used(AST, Features),
    memberchk(durative_actions, Features),
    memberchk(typing, Features).

test(features_htn) :-
    htn_domain_string(S),
    pddl_parse_string(S, AST),
    pddl_features_used(AST, Features),
    memberchk(hddl, Features),
    memberchk(htn, Features).

test(eligible_planners_minimal) :-
    minimal_domain_string(S),
    pddl_parse_string(S, AST),
    eligible_planners(AST, Planners),
    memberchk(lama, Planners),
    memberchk(fast_downward, Planners).

test(eligible_planners_durative) :-
    durative_domain_string(S),
    pddl_parse_string(S, AST),
    eligible_planners(AST, Planners),
    memberchk(optic, Planners).

test(eligible_planners_htn) :-
    htn_domain_string(S),
    pddl_parse_string(S, AST),
    eligible_planners(AST, Planners),
    memberchk(lilotane, Planners),
    \+ memberchk(lama, Planners).

test(recommend_planner_durative) :-
    durative_domain_string(S),
    pddl_parse_string(S, AST),
    recommend_planner(AST, P),
    memberchk(P, [optic, popf, lpg_td, sgplan]).

test(recommend_planner_htn) :-
    htn_domain_string(S),
    pddl_parse_string(S, AST),
    recommend_planner(AST, P),
    memberchk(P, [lilotane, panda, tree_rex]).

:- end_tests(pddl).
