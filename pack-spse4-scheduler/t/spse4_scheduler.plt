/*  Tests for pack-spse4-scheduler  */

:- use_module(library(plunit)).
:- use_module('../prolog/spse4_scheduler').
:- use_module(library(mt_store)).
:- use_module(library(spse4_core)).

:- begin_tests(spse4_scheduler).

setup_clean :-
    retractall(mt_store:mt_registry_(_)),
    retractall(mt_store:mt_prop_(_,_,_)),
    retractall(mt_store:mt_fact_(_,_)),
    retractall(mt_store:mt_spec_(_,_)),
    retractall(mt_store:mt_acl_(_,_,_)),
    retractall(mt_store:mt_audit_(_,_,_,_,_)),
    mt_create(proj, [owner=andrew]).

% ---------------------------------------------------------------------
% Datetime conversion
% ---------------------------------------------------------------------

test(datetime_epoch_integer) :-
    datetime_to_epoch(1700000000, E),
    E =:= 1700000000.

test(datetime_epoch_iso_roundtrip) :-
    datetime_to_epoch("2026-04-22T10:00:00Z", E),
    integer(E),
    E > 1700000000,   % after Nov 2023
    E < 2000000000.   % before May 2033

test(datetime_epoch_date_only) :-
    datetime_to_epoch(date(2026, 4, 22), E),
    integer(E).

% ---------------------------------------------------------------------
% Basic temporal queries
% ---------------------------------------------------------------------

test(earliest_start_no_deps, [setup(setup_clean)]) :-
    task_create(proj, t1, [earliest_start=1700000000, duration=hours(2)]),
    task_earliest_start(proj, t1, E),
    E =:= 1700000000.

test(earliest_start_with_dep, [setup(setup_clean)]) :-
    % t1 at 10:00, duration 1h --> ends 11:00
    % t2 depends on t1 --> earliest_start is 11:00 (no earlier declared)
    task_create(proj, t1, [earliest_start=10000, duration=hours(1)]),
    task_create(proj, t2, [duration=hours(1)]),
    edge_assert(proj, t2, depends, t1, []),
    task_earliest_start(proj, t2, E),
    E =:= 10000 + 3600.

test(latest_finish_from_successor, [setup(setup_clean)]) :-
    % t2 has deadline 20000, duration 1h --> latest_start 16400
    % t1 precedes t2, duration 1h --> latest_finish 16400
    task_create(proj, t1, [duration=hours(1)]),
    task_create(proj, t2, [latest_finish=20000, duration=hours(1)]),
    edge_assert(proj, t2, depends, t1, []),
    task_latest_finish(proj, t1, LF),
    LF =:= 20000 - 3600.

test(slack_zero_on_critical, [setup(setup_clean)]) :-
    % Earliest_start=0, latest_finish=3600, duration=3600 --> slack 0
    task_create(proj, t1, [earliest_start=0, latest_finish=3600, duration=hours(1)]),
    task_slack(proj, t1, Slack),
    Slack =:= 0.

test(slack_positive_when_loose, [setup(setup_clean)]) :-
    task_create(proj, t1, [earliest_start=0, latest_finish=7200, duration=hours(1)]),
    task_slack(proj, t1, Slack),
    Slack =:= 3600.

% ---------------------------------------------------------------------
% Critical path
% ---------------------------------------------------------------------

test(critical_path_single, [setup(setup_clean)]) :-
    task_create(proj, t1, [duration=hours(1)]),
    critical_path(proj, t1, Path),
    Path = [t1].

test(critical_path_chain, [setup(setup_clean)]) :-
    % t3 depends t2 depends t1 --> path is [t1, t2, t3]
    task_create(proj, t1, [duration=hours(1)]),
    task_create(proj, t2, [duration=hours(1)]),
    task_create(proj, t3, [duration=hours(1)]),
    edge_assert(proj, t2, depends, t1, []),
    edge_assert(proj, t3, depends, t2, []),
    critical_path(proj, t3, Path),
    Path = [t1, t2, t3].

test(critical_path_picks_longer, [setup(setup_clean)]) :-
    % t3 depends t1 (short) and t2 (long); critical = [t2, t3]
    task_create(proj, t1, [duration=hours(1)]),
    task_create(proj, t2, [duration=hours(10)]),
    task_create(proj, t3, [duration=hours(1)]),
    edge_assert(proj, t3, depends, t1, []),
    edge_assert(proj, t3, depends, t2, []),
    critical_path(proj, t3, Path),
    Path = [t2, t3].

% ---------------------------------------------------------------------
% Batch schedule
% ---------------------------------------------------------------------

test(schedule_respects_topo_order, [setup(setup_clean)]) :-
    task_create(proj, t1, [earliest_start=0, duration=hours(1), status=open]),
    task_create(proj, t2, [duration=hours(1), status=open]),
    task_create(proj, t3, [duration=hours(1), status=open]),
    edge_assert(proj, t2, depends, t1, []),
    edge_assert(proj, t3, depends, t2, []),
    schedule_tasks(proj, [], Solution),
    % t1 before t2 before t3 in the schedule
    once(nth0(I1, Solution, scheduled(t1, _, _))),
    once(nth0(I2, Solution, scheduled(t2, _, _))),
    once(nth0(I3, Solution, scheduled(t3, _, _))),
    I1 < I2, I2 < I3.

test(schedule_excludes_completed, [setup(setup_clean)]) :-
    task_create(proj, t1, [status=completed, duration=hours(1)]),
    task_create(proj, t2, [status=open, duration=hours(1)]),
    schedule_tasks(proj, [], Solution),
    \+ memberchk(scheduled(t1, _, _), Solution),
    memberchk(scheduled(t2, _, _), Solution).

% ---------------------------------------------------------------------
% Reactive triggers
% ---------------------------------------------------------------------

:- dynamic fire_log/1.

record_fire(Tag) :- assertz(fire_log(Tag)).

test(trigger_fires_on_all_complete,
     [setup((setup_clean, retractall(fire_log(_)))),
      cleanup(retractall(fire_log(_)))]) :-
    task_create(proj, t1, [status=open]),
    task_create(proj, t2, [status=open]),
    task_create(proj, goal, [status=open]),
    edge_assert(proj, goal, depends, t1, []),
    edge_assert(proj, goal, depends, t2, []),
    on_dependencies_complete(proj, goal, record_fire(goal_ready)),
    % Not fired yet
    \+ fire_log(goal_ready),
    % Complete t1 --> still not fired
    task_set_status(proj, t1, completed),
    \+ fire_log(goal_ready),
    % Complete t2 --> fires
    task_set_status(proj, t2, completed),
    fire_log(goal_ready).

test(trigger_fires_immediately_if_already_complete,
     [setup((setup_clean, retractall(fire_log(_)))),
      cleanup(retractall(fire_log(_)))]) :-
    task_create(proj, t1, [status=completed]),
    task_create(proj, goal, [status=open]),
    edge_assert(proj, goal, depends, t1, []),
    on_dependencies_complete(proj, goal, record_fire(immediate)),
    fire_log(immediate).

test(trigger_no_deps_fires_immediately,
     [setup((setup_clean, retractall(fire_log(_)))),
      cleanup(retractall(fire_log(_)))]) :-
    task_create(proj, t1, [status=open]),
    on_dependencies_complete(proj, t1, record_fire(no_deps)),
    fire_log(no_deps).

:- end_tests(spse4_scheduler).
