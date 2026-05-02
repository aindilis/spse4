# pack-spse4-scheduler — Real-datetime scheduling for SPSE4

Extends `pack-allen`'s qualitative interval algebra to real calendar
time, adds deadline propagation and critical-path analysis over SPSE4
tasks, and wires up `when/2`-style reactive triggers.

Part of FRKCSA / SPSE4.

## Install

```prolog
?- pack_install('https://github.com/aindilis/pack-allen.git').
?- pack_install('https://github.com/aindilis/pack-mt-store.git').
?- pack_install('https://github.com/aindilis/pack-spse4-core.git').
?- pack_install('https://github.com/aindilis/pack-spse4-scheduler.git').
?- use_module(library(spse4_scheduler)).
```

## Capabilities

### 1. Real datetimes

Tasks carry `earliest_start`, `latest_finish`, and `duration`
properties.  Accepts integers (epoch seconds), `date/3` and `date/9`
terms, and ISO 8601 strings — whichever is convenient.  Durations use
`seconds(N)` / `minutes(N)` / `hours(N)` / `days(N)` / `weeks(N)` or
`range(Lo, Hi)` for uncertainty.

### 2. Deadline propagation

Given a `latest_finish` on a downstream task and durations of its
upstream dependencies, compute the implied `latest_finish` of each
upstream task and assert it as `inferred_latest_finish`.

### 3. Critical path

`critical_path(Mt, Goal, Path)` returns the longest-duration chain of
dependencies terminating at Goal.  `task_slack/3` gives the slack
time (zero for tasks on the critical path).

### 4. Reactive triggers

`on_dependencies_complete(Mt, TaskId, Goal)` registers Goal to fire
exactly once when every predecessor of TaskId has `status=completed`.
If they're already all complete, Goal fires immediately.  Uses
`library(broadcast)` under the hood.

`task_set_status(Mt, TaskId, Status)` is the reactive-aware way to
update a task's status — it broadcasts so triggers fire.  Plain
`task_set_property(Mt, T, status, completed)` will update the KB but
will not notify anyone.

## Example

```prolog
:- use_module(library(mt_store)).
:- use_module(library(spse4_core)).
:- use_module(library(spse4_scheduler)).

demo :-
    mt_create(proj, [owner=andrew]),
    task_create(proj, draft,
                [ has_nl = "Draft the paper",
                  earliest_start = "2026-04-22T09:00:00Z",
                  duration = days(3),
                  status = open ]),
    task_create(proj, review,
                [ has_nl = "Peer review",
                  duration = days(2),
                  status = open ]),
    task_create(proj, submit,
                [ has_nl = "Submit to conference",
                  latest_finish = "2026-05-01T23:59:00Z",
                  duration = hours(1),
                  status = open ]),
    edge_assert(proj, review, depends, draft, []),
    edge_assert(proj, submit, depends, review, []),

    schedule_tasks(proj, [], Schedule),
    format("Schedule:~n"),
    forall(member(scheduled(T, S, E), Schedule),
           format("  ~w: ~w -- ~w~n", [T, S, E])),

    critical_path(proj, submit, Path),
    format("Critical path: ~w~n", [Path]),

    % Reactive: when both preconditions clear, auto-notify.
    on_dependencies_complete(proj, submit,
        format("~n*** submit is now ready ***~n")),

    task_set_status(proj, draft, completed),
    task_set_status(proj, review, completed).
```

## Tests

```
swipl -g "[t/spse4_scheduler], run_tests" -t halt prolog/spse4_scheduler.pl
```

## Not yet here

- Working-hours / calendar constraints (business hours, weekends)
- Resource contention (two tasks both needing the same resource)
- CLP(FD) integration with `pack-allen` for qualitative + quantitative
  joint solving (v0.2)
- `library(julian)` adapter
- SHOP-style HTN interpreter running on the scheduled graph

## License

GPLv3.
