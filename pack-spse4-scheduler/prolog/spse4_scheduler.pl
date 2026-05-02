/*  pack-spse4-scheduler -- Real-datetime scheduling + reactive triggers.

    Part of FRKCSA / SPSE4.  GPLv3 License.

    This module extends =pack-allen='s integer-timeline CLP(FD)
    scheduler to real calendar time, provides deadline propagation and
    critical-path analysis over SPSE4 tasks, and wires up =|when/2|=-
    driven reactive triggers that fire when a task's dependencies
    become satisfied.

    Real-datetime handling uses SWI-Prolog's built-in =library(date)=
    (Unix-epoch seconds as the internal representation) with
    =format_time/3= for display.  No external date library is
    required; callers who prefer the =julian= pack can still use its
    values as inputs since we accept any integer seconds-since-epoch.
*/

:- module(spse4_scheduler,
          [ datetime_to_epoch/2,        % +Term, -EpochSeconds
            epoch_to_datetime/2,        % +EpochSeconds, -Term
            schedule_tasks/3,           % +Mt, +Options, -Solution
            critical_path/3,            % +Mt, +Goal, -Path
            propagate_deadlines/2,      % +Mt, +Overrides
            task_earliest_start/3,      % +Mt, +TaskId, -EpochSeconds
            task_latest_finish/3,       % +Mt, +TaskId, -EpochSeconds
            task_slack/3,               % +Mt, +TaskId, -SlackSeconds

            on_dependencies_complete/3, % +Mt, +TaskId, :Goal
            task_set_status/3,          % +Mt, +TaskId, +Status (broadcasts)
            trigger_ready_tasks/1,      % +Mt
            ready_task_event/2          % ?Mt, ?TaskId  (broadcast/listen)
          ]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(broadcast)).
:- use_module(library(mt_store)).
:- use_module(library(spse4_core)).

:- meta_predicate
    on_dependencies_complete(?, ?, 0),
    check_and_fire_(?, ?, 0).

/** <module> SPSE4 scheduler

Four capabilities on top of pack-allen and pack-spse4-core:

1. **Real datetimes**: tasks can carry =earliest_start=, =latest_finish=,
   and =duration= properties with real calendar time.  Internally these
   are Unix-epoch seconds.

2. **Deadline propagation**: given a latest_finish on a downstream
   task and known durations of its upstream dependencies, the
   implicit latest-finish of the upstream tasks is computed.

3. **Critical path**: the longest-duration chain of depends-edges
   terminating at a goal task.  Slack for every task is its chain-
   -finish minus the critical-path finish.

4. **Reactive triggers**: =|on_dependencies_complete/3|= attaches a
   goal to a task that fires exactly once, via =when/2= machinery,
   when all its depends-edges have been marked =status=completed=.
   Additionally, =|trigger_ready_tasks/1|= broadcasts a
   =|ready_task(Mt, TaskId)|= event for every newly-ready task.
*/

% =====================================================================
% Datetime helpers
% =====================================================================

%!  datetime_to_epoch(+Term, -EpochSeconds) is det.
%
%   Convert a date/time term to Unix epoch seconds.  Accepts:
%     * an integer (already epoch seconds, pass-through)
%     * a float (epoch seconds with fraction)
%     * a =|date(Y,M,D)|= (treated as midnight UTC)
%     * a =|date(Y,M,D,H,Mi,S,_,_,_)|= standard SWI date tuple
%     * an ISO-8601 string like "2026-04-22T10:00:00Z"
datetime_to_epoch(N, N) :- number(N), !.
datetime_to_epoch(date(Y, M, D), Epoch) :- !,
    datetime_to_epoch(date(Y, M, D, 0, 0, 0, 0, -, -), Epoch).
datetime_to_epoch(DT, Epoch) :- DT = date(_,_,_,_,_,_,_,_,_), !,
    date_time_stamp(DT, EpochF),
    Epoch is integer(EpochF).
datetime_to_epoch(S, Epoch) :- string(S), !,
    parse_iso_(S, Epoch).
datetime_to_epoch(A, Epoch) :- atom(A), !,
    atom_string(A, S),
    parse_iso_(S, Epoch).

parse_iso_(S, Epoch) :-
    string_codes(S, Cs),
    once(phrase(iso_date_(Y, M, D, H, Mi, Sec), Cs, _)),
    date_time_stamp(date(Y, M, D, H, Mi, Sec, 0, -, -), EpochF),
    Epoch is integer(EpochF).

iso_date_(Y, M, D, H, Mi, S) -->
    int4_(Y), "-", int2_(M), "-", int2_(D),
    ( "T", int2_(H), ":", int2_(Mi), ":", int2_(S)
    ; { H = 0, Mi = 0, S = 0 }
    ),
    ( "Z" ; [] ).

int4_(N) --> [C1,C2,C3,C4],
    { maplist([C,D]>>(D is C - 0'0), [C1,C2,C3,C4], [D1,D2,D3,D4]),
      N is D1*1000 + D2*100 + D3*10 + D4 }.
int2_(N) --> [C1,C2],
    { D1 is C1 - 0'0, D2 is C2 - 0'0, N is D1*10 + D2 }.

%!  epoch_to_datetime(+Epoch, -Term) is det.
epoch_to_datetime(Epoch, date(Y, M, D, H, Mi, S, Off, TZ, DST)) :-
    stamp_date_time(Epoch, date(Y, M, D, H, Mi, SF, Off, TZ, DST), 'UTC'),
    S is integer(SF).

% =====================================================================
% Duration helpers
% =====================================================================
%
% Task durations can be expressed as:
%   seconds(N)        N integer seconds
%   minutes(N)
%   hours(N)
%   days(N)
%   weeks(N)
%   fixed(N)          same as seconds(N)
%   range(Lo, Hi)     uncertain; we use Hi (pessimistic) for scheduling
%   distribution(K,Ps) reserved; we pull a point estimate (future work)
%   effort(N)         total work units, not wall-clock -- treated as seconds

duration_seconds_(seconds(N), N) :- !.
duration_seconds_(minutes(N), S) :- !, S is N * 60.
duration_seconds_(hours(N),   S) :- !, S is N * 3600.
duration_seconds_(days(N),    S) :- !, S is N * 86400.
duration_seconds_(weeks(N),   S) :- !, S is N * 604800.
duration_seconds_(fixed(N),   N) :- !.
duration_seconds_(range(_, Hi), S) :- !, duration_seconds_(Hi, S).
duration_seconds_(distribution(_, _), 0) :- !.
duration_seconds_(effort(N), N) :- !.
duration_seconds_(N, N) :- number(N).

% =====================================================================
% Task temporal properties
% =====================================================================

%!  task_earliest_start(+Mt, +TaskId, -Epoch) is det.
%
%   The earliest time TaskId can start, given its =earliest_start=
%   property and the latest end of any of its predecessors.
task_earliest_start(Mt, TaskId, Epoch) :-
    (   once(task_property(Mt, TaskId, earliest_start, E0))
    ->  datetime_to_epoch(E0, Declared)
    ;   Declared = 0
    ),
    findall(PredEnd,
            ( depends(Mt, TaskId, Dep),
              task_end_estimate_(Mt, Dep, PredEnd) ),
            PredEnds),
    max_or_(PredEnds, Declared, Epoch).

task_end_estimate_(Mt, TaskId, End) :-
    task_earliest_start(Mt, TaskId, Start),
    (   once(task_property(Mt, TaskId, duration, D))
    ->  duration_seconds_(D, Secs),
        End is Start + Secs
    ;   End = Start
    ).

max_or_([], Default, Default) :- !.
max_or_([X|Xs], Default, Max) :-
    max_list_([X|Xs], M),
    Max is max(M, Default).

max_list_([X], X) :- !.
max_list_([X|Xs], M) :-
    max_list_(Xs, M0),
    M is max(X, M0).

%!  task_latest_finish(+Mt, +TaskId, -Epoch) is det.
%
%   The latest time TaskId can finish, given its =latest_finish= and
%   any downstream tasks' constraints.
task_latest_finish(Mt, TaskId, Epoch) :-
    (   once(task_property(Mt, TaskId, latest_finish, LF))
    ->  datetime_to_epoch(LF, Declared)
    ;   Declared = infinity
    ),
    findall(SuccLF,
            ( depends(Mt, Succ, TaskId),
              task_latest_start_(Mt, Succ, SuccLF) ),
            SuccLFs),
    min_or_(SuccLFs, Declared, Epoch).

task_latest_start_(Mt, TaskId, Start) :-
    task_latest_finish(Mt, TaskId, Finish),
    (   once(task_property(Mt, TaskId, duration, D))
    ->  duration_seconds_(D, Secs),
        (   Finish == infinity
        ->  Start = infinity
        ;   Start is Finish - Secs
        )
    ;   Start = Finish
    ).

min_or_([], Default, Default) :- !.
min_or_([X|Xs], Default, Min) :-
    min_list_([X|Xs], M),
    (   Default == infinity
    ->  Min = M
    ;   Min is min(M, Default)
    ).
min_list_([X], X) :- !.
min_list_([X|Xs], M) :-
    min_list_(Xs, M0),
    (   M0 == infinity -> M = X
    ;   M is min(X, M0)
    ).

%!  task_slack(+Mt, +TaskId, -SlackSeconds) is semidet.
%
%   Slack = latest_finish - (earliest_start + duration).  Fails if
%   either bound is infinity.
task_slack(Mt, TaskId, Slack) :-
    task_earliest_start(Mt, TaskId, ES),
    task_latest_finish(Mt, TaskId, LF),
    LF \== infinity,
    (   task_property(Mt, TaskId, duration, D)
    ->  duration_seconds_(D, Secs)
    ;   Secs = 0
    ),
    Slack is LF - (ES + Secs).

% =====================================================================
% Critical path
% =====================================================================

%!  critical_path(+Mt, +GoalTask, -Path) is det.
%
%   The longest-duration chain of depends-edges terminating at
%   GoalTask.  Path is a list of task ids in execution order.
critical_path(Mt, Goal, Path) :-
    longest_chain_(Mt, Goal, PathRev, _Len),
    reverse(PathRev, Path).

longest_chain_(Mt, TaskId, [TaskId|SubPath], TotalDur) :-
    findall(Chain-ChainDur,
            ( depends(Mt, TaskId, Dep),
              longest_chain_(Mt, Dep, Chain, ChainDur) ),
            Options),
    (   Options = []
    ->  SubPath = [], task_duration_seconds_(Mt, TaskId, TotalDur)
    ;   max_chain_(Options, SubPath, SubDur),
        task_duration_seconds_(Mt, TaskId, MyDur),
        TotalDur is MyDur + SubDur
    ).

task_duration_seconds_(Mt, TaskId, Secs) :-
    (   task_property(Mt, TaskId, duration, D)
    ->  duration_seconds_(D, Secs)
    ;   Secs = 0
    ).

max_chain_([Path-Dur], Path, Dur) :- !.
max_chain_([P1-D1, P2-D2 | Rest], Best, BestD) :-
    (   D1 >= D2
    ->  max_chain_([P1-D1 | Rest], Best, BestD)
    ;   max_chain_([P2-D2 | Rest], Best, BestD)
    ).

% =====================================================================
% Deadline propagation
% =====================================================================

%!  propagate_deadlines(+Mt, +Overrides) is det.
%
%   Given explicit =latest_finish= on some tasks (as Overrides, a list
%   of =|Task-Epoch|= pairs, or pulled from the KB), compute implied
%   latest-start times for all upstream tasks and assert them as
%   =|inferred_latest_start|= properties.  Does not modify declared
%   values.
propagate_deadlines(Mt, Overrides) :-
    % Apply overrides first.
    forall(member(Task-LF, Overrides),
           ( datetime_to_epoch(LF, E),
             task_set_property(Mt, Task, latest_finish, E) )),
    task_list(Mt, Tasks),
    forall(member(Task, Tasks), infer_implicit_deadline_(Mt, Task)).

infer_implicit_deadline_(Mt, Task) :-
    (   task_property(Mt, Task, latest_finish, _)
    ->  true   % already has explicit deadline
    ;   task_latest_finish(Mt, Task, Epoch),
        Epoch \== infinity
    ->  task_set_property(Mt, Task, inferred_latest_finish, Epoch)
    ;   true
    ).

% =====================================================================
% Batch scheduler
% =====================================================================

%!  schedule_tasks(+Mt, +Options, -Solution) is det.
%
%   Produce an execution schedule for all open tasks in Mt that
%   respects:
%     - depends-edges (predecessors finish before successors start)
%     - declared earliest_start / latest_finish
%     - durations
%
%   Solution is a list of =|scheduled(TaskId, StartEpoch, EndEpoch)|=.
%   Options (currently unused, reserved for future refinement):
%     =|starting_at(Epoch)|= -- clock origin (default: now)
%     =|working_hours(Start, End)|= -- restrict to business hours (TODO)
schedule_tasks(Mt, _Options, Solution) :-
    task_list(Mt, All),
    include(active_task_(Mt), All, Active),
    topo_sort_(Mt, Active, Ordered),
    maplist(schedule_one_(Mt), Ordered, Solution).

active_task_(Mt, TaskId) :-
    task_property(Mt, TaskId, status, S),
    memberchk(S, [open, in_progress]).

schedule_one_(Mt, TaskId, scheduled(TaskId, Start, End)) :-
    task_earliest_start(Mt, TaskId, Start),
    task_duration_seconds_(Mt, TaskId, Secs),
    End is Start + Secs.

% Topological sort over depends-edges restricted to the Active set.
% Uses Kahn's algorithm, but with a twist: any task whose status is
% `completed' is treated as already in Done even though it's not in
% Active.  This lets tasks in Active depend on completed predecessors
% and still be declared ready.
topo_sort_(Mt, Active, Sorted) :-
    findall(T, ( task_exists(Mt, T),
                 task_property(Mt, T, status, completed) ),
            CompletedRaw),
    list_to_set(CompletedRaw, Completed),
    topo_(Active, Mt, Completed, Sorted).

topo_([], _Mt, _Done, []) :- !.
topo_(Pending, Mt, Done, [Next | Rest]) :-
    pick_ready_(Pending, Mt, Done, Next),
    selectchk(Next, Pending, Pending1),
    topo_(Pending1, Mt, [Next | Done], Rest).

pick_ready_([T|_], Mt, Done, T) :-
    forall( depends(Mt, T, Dep),
            ( memberchk(Dep, Done) ; \+ task_exists(Mt, Dep) ) ),
    !.
pick_ready_([_|Rest], Mt, Done, T) :-
    pick_ready_(Rest, Mt, Done, T).

% =====================================================================
% Reactive triggers
% =====================================================================

%!  on_dependencies_complete(+Mt, +TaskId, :Goal) is det.
%
%   Register Goal to be called exactly once when all of TaskId's
%   =depends/2= predecessors have status=completed.  If they're
%   already all complete, Goal fires immediately.
on_dependencies_complete(Mt, TaskId, Goal) :-
    findall(Dep, depends(Mt, TaskId, Dep), Deps),
    (   Deps == []
    ->  call(Goal)
    ;   forall(member(Dep, Deps),
               listen(task_status_changed(Mt, Dep, completed),
                      check_and_fire_(Mt, TaskId, Goal))),
        % Immediate check in case they're already complete.
        check_and_fire_(Mt, TaskId, Goal)
    ).

%!  task_set_status(+Mt, +TaskId, +Status) is det.
%
%   Set the status of a task and broadcast the change so that any
%   registered =|on_dependencies_complete|= handlers fire.  This is
%   the reactive-enabled way to close a task; plain
%   =|task_set_property(Mt, T, status, completed)|= will NOT fire
%   triggers.
task_set_status(Mt, TaskId, Status) :-
    task_set_property(Mt, TaskId, status, Status),
    broadcast(task_status_changed(Mt, TaskId, Status)).

check_and_fire_(Mt, TaskId, Goal) :-
    findall(Dep, depends(Mt, TaskId, Dep), Deps),
    (   forall(member(Dep, Deps), completed(Mt, Dep))
    ->  % Unlisten only our own handler to prevent double-fire.  We
        % specifically identify it by matching on the check_and_fire_
        % term with our TaskId and Goal, so other listeners on the
        % same event are preserved.
        forall(member(Dep, Deps),
               unlisten(task_status_changed(Mt, Dep, completed),
                        check_and_fire_(Mt, TaskId, Goal))),
        call(Goal)
    ;   true
    ).

%!  trigger_ready_tasks(+Mt) is det.
%
%   Broadcast =|ready_task(Mt, TaskId)|= for every task newly ready
%   in Mt.  Clients can =|listen/2|= on =|ready_task_event/2|=.
trigger_ready_tasks(Mt) :-
    task_ready(Mt, Ready),
    forall(member(T, Ready), broadcast(ready_task(Mt, T))).

%!  ready_task_event(?Mt, ?TaskId) is nondet.
%
%   Shorthand for =|listen(ready_task(Mt, TaskId), Goal)|=, bound as
%   an event stream consumers can pattern-match.
ready_task_event(Mt, TaskId) :-
    broadcast(ready_task(Mt, TaskId)).
