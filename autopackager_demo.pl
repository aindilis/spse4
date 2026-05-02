/*  autopackager_demo.pl  --  Seed SPSE4 with Andrew's autopackager
    priority queue as a dogfood demonstration.

    Usage:
        swipl autopackager_demo.pl

    What this does:
      - Creates an `autopackager' microtheory owned by Andrew
      - Declares the packages already completed or in flight
      - Declares dependencies (e.g. peleus needs eprover for ATP-backed
        plan verification)
      - Sets deadlines (e.g. FRKCSA package repositories submission target)
      - Runs schedule_tasks/3 and critical_path/3
      - Shows task_ready/2 ordering
      - Demonstrates a reactive trigger

    This is the first end-to-end example of SPSE4 doing something
    useful with real FRDCSA data, not synthetic tests.

    GPL License.
*/

:- prolog_load_context(directory, Here),
   asserta(user:file_search_path(library, Here/'pack-allen'/prolog)),
   asserta(user:file_search_path(library, Here/'pack-mt-store'/prolog)),
   asserta(user:file_search_path(library, Here/'pack-spse4-core'/prolog)),
   asserta(user:file_search_path(library, Here/'pack-pddl'/prolog)),
   asserta(user:file_search_path(library, Here/'pack-spse4-scheduler'/prolog)).

:- use_module(library(mt_store)).
:- use_module(library(spse4_core)).
:- use_module(library(spse4_scheduler)).

:- initialization(main, main).

% =====================================================================
% Seed data -- Andrew's actual autopackager work
% =====================================================================
%
% This captures the packaging work state as of late Q1 2026.  Dates
% are illustrative but based on the real pattern (multiple packages
% completed, FRKCSA package repositories submission upcoming).

seed_autopackager :-
    mt_create(autopackager,
              [ owner = andrew,
                description = "Debian packaging pipeline for FRDCSA dependencies" ]),

    % ---- completed upstream packages ----
    task_create(autopackager, pkg_eprover,
                [ has_nl = "Package E 3.1 automated theorem prover",
                  task_kind = primitive,
                  status = completed,
                  duration = days(2),
                  notes = "First proof: p -> p verified working" ]),
    task_create(autopackager, pkg_peleus,
                [ has_nl = "Package Peleus (AgentSpeak BDI planner, 20yo Java)",
                  task_kind = primitive,
                  status = completed,
                  duration = days(3),
                  notes = "First FRDCSA planner restored after two decades" ]),
    task_create(autopackager, pkg_superlu,
                [ has_nl = "Package SuperLU sparse direct solver",
                  task_kind = primitive,
                  status = completed,
                  duration = days(1) ]),
    task_create(autopackager, pkg_scone,
                [ has_nl = "Package Scone knowledge-base system",
                  task_kind = primitive,
                  status = completed,
                  duration = days(2) ]),
    task_create(autopackager, pkg_tesuji,
                [ has_nl = "Package Tesuji Go positional concept engine",
                  task_kind = primitive,
                  status = completed,
                  duration = days(1) ]),
    task_create(autopackager, pkg_emacs_kb_atp,
                [ has_nl = "Package emacs-kb-atp (FOL ATP in Emacs Lisp + dungeon game)",
                  task_kind = primitive,
                  status = completed,
                  duration = days(2) ]),

    % ---- in-progress / upcoming ----
    task_create(autopackager, pkg_vampire,
                [ has_nl = "Package Vampire 4.9 for Debian",
                  task_kind = primitive,
                  status = in_progress,
                  duration = days(3),
                  earliest_start = "2026-04-22T09:00:00Z",
                  notes = "High-quality ATP; needed by RL-LLM-Cyc-Agent reward model" ]),
    task_create(autopackager, pkg_acl2,
                [ has_nl = "Package ACL2 theorem prover",
                  task_kind = primitive,
                  status = open,
                  duration = days(5),
                  notes = "Needed for epsilon_0 ordinal work, DGM-H paper" ]),
    task_create(autopackager, pkg_freekbs2,
                [ has_nl = "Package FreeKBS2 knowledge base management system",
                  task_kind = primitive,
                  status = open,
                  duration = days(4),
                  notes = "FRDCSA-internal; needed before public FLP release" ]),

    % ---- downstream goals ----
    task_create(autopackager, submit_autopkg_to_frkcsa_repos,
                [ has_nl = "Submit autopackager itself to FRKCSA package repositories",
                  task_kind = primitive,
                  status = open,
                  duration = days(2),
                  latest_finish = "2026-05-15T23:59:00Z" ]),
    task_create(autopackager, release_flp_public,
                [ has_nl = "Public release of FLP as Debian package suite",
                  task_kind = milestone,
                  status = open,
                  duration = days(7),
                  latest_finish = "2026-07-01T23:59:00Z" ]),

    % ---- dependency edges ----
    % vampire depends on nothing yet (standalone build)
    % submit_autopkg_to_frkcsa_repos needs at least some real packages working
    edge_assert(autopackager, submit_autopkg_to_frkcsa_repos, depends, pkg_eprover, []),
    edge_assert(autopackager, submit_autopkg_to_frkcsa_repos, depends, pkg_peleus, []),
    edge_assert(autopackager, submit_autopkg_to_frkcsa_repos, depends, pkg_vampire, []),

    % Public FLP needs all the ATPs, KBS, and autopackager itself cleared
    edge_assert(autopackager, release_flp_public, depends, submit_autopkg_to_frkcsa_repos, []),
    edge_assert(autopackager, release_flp_public, depends, pkg_acl2, []),
    edge_assert(autopackager, release_flp_public, depends, pkg_freekbs2, []),
    edge_assert(autopackager, release_flp_public, depends, pkg_vampire, []).

% =====================================================================
% Reports
% =====================================================================

report_ready :-
    task_ready(autopackager, Ready),
    format("~n=== Tasks ready to work on right now ===~n"),
    (   Ready == []
    ->  format("  (none)~n")
    ;   forall(member(T, Ready),
               ( task_property(autopackager, T, has_nl, NL),
                 format("  * ~w: ~w~n", [T, NL]) ))
    ).

report_critical_path :-
    format("~n=== Critical path to FLP public release ===~n"),
    critical_path(autopackager, release_flp_public, Path),
    forall(member(T, Path),
           ( task_property(autopackager, T, has_nl, NL),
             (   task_property(autopackager, T, status, Status)
             ->  true ; Status = open ),
             format("  [~w] ~w: ~w~n", [Status, T, NL]) )).

report_schedule :-
    format("~n=== Projected schedule ===~n"),
    schedule_tasks(autopackager, [], Solution),
    length(Solution, LS),
    format("  (~w tasks scheduled)~n", [LS]),
    get_time(NowF),
    Now is integer(NowF),
    forall(member(scheduled(T, S, E), Solution),
           ( task_property(autopackager, T, has_nl, NL),
             % If the task had no earliest_start we get S=0 meaning
             % "schedule from now"; shift the window so the display is
             % meaningful instead of showing 1970.
             (   S == 0
             ->  Duration is E - S,
                 DispS = Now,
                 DispE is Now + Duration
             ;   DispS = S, DispE = E
             ),
             safe_dt_(DispS, SS),
             safe_dt_(DispE, ES),
             format("  ~w - ~w  ~w: ~w~n", [SS, ES, T, NL]) )).

safe_dt_(0, "(not set)") :- !.
safe_dt_(E, S) :-
    catch( format_time(string(S), "%Y-%m-%d", E),
           Err,
           format(string(S), "ERR(~w: ~w)", [E, Err]) ).

report_frkcsa_repos_readiness :-
    format("~n=== Gate: Ready to submit to FRKCSA package repositories? ===~n"),
    findall(Dep - Status,
            ( depends(autopackager, submit_autopkg_to_frkcsa_repos, Dep),
              (   task_property(autopackager, Dep, status, Status)
              ->  true ; Status = open ) ),
            Report),
    forall(member(Dep-Status, Report),
           format("  ~w: ~w~n", [Dep, Status])),
    include(is_blocker_, Report, Blockers),
    (   Blockers == []
    ->  format("  ALL GREEN -- ready to submit.~n")
    ;   length(Blockers, NB),
        format("  NOT YET -- ~w blocker(s) outstanding:~n", [NB]),
        forall(member(D-S, Blockers),
               format("    ~w (~w)~n", [D, S]))
    ).

is_blocker_(_ - Status) :- Status \== completed.

demonstrate_reactive :-
    format("~n=== Reactive trigger demo ===~n"),
    format("Registering handler: when submit_autopkg_to_frkcsa_repos is ready, say so.~n"),
    on_dependencies_complete(autopackager, submit_autopkg_to_frkcsa_repos,
        format("  *** AUTOMATIC: all prereqs complete, time to submit! ***~n")),
    format("Current vampire status: in_progress (not fired yet).~n"),
    format("Simulating vampire completion:~n"),
    task_set_status(autopackager, pkg_vampire, completed),
    format("(trigger should have fired above if logic is right)~n").

% =====================================================================
% Main
% =====================================================================

main :-
    seed_autopackager,
    task_list(autopackager, All),
    length(All, N),
    format("Seeded autopackager microtheory with ~w tasks.~n", [N]),
    report_ready,
    report_critical_path,
    report_schedule,
    report_frkcsa_repos_readiness,
    demonstrate_reactive,
    format("~n==== End of demo ====~n"),
    halt(0).
