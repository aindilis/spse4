/*  examples/server_demo.pl

    Launches spse4_server on port 4040 with the autopackager task
    queue from v0.1.12's autopackager_demo.pl seeded into the
    microtheory `autopackager`.  Adds two demo users:

        alice: write access to `autopackager` and `public`
        bob:   read-only on `public`

    Usage (from the spse4/ root):

        swipl pack-spse4-server/examples/server_demo.pl

    Then open http://localhost:4040/ in a browser, or hit the
    projection endpoint directly:

        curl -u alice:hunter2 \
             'http://localhost:4040/projection?mt=autopackager&critical_path=1&goal=flp_release'

    Stop with Ctrl-C.
*/

% Register pack search paths.  This script lives at
% pack-spse4-server/examples/server_demo.pl, so the repo root is
% two directories up.  Make every pack's prolog/ directory findable
% via library(Name).

:- prolog_load_context(directory, Here),
   atomic_list_concat([Here, '/../..'], RootRaw),
   absolute_file_name(RootRaw, Root,
                      [file_type(directory), access(exist)]),
   forall(member(P, ['pack-allen', 'pack-mt-store', 'pack-spse4-core',
                     'pack-pddl', 'pack-spse4-scheduler',
                     'pack-spse4-server']),
          ( atomic_list_concat([Root, '/', P, '/prolog'], Dir),
            (   exists_directory(Dir)
            ->  asserta(user:file_search_path(library, Dir))
            ;   true
            )
          )).

:- use_module(library(spse4_server)).
:- use_module(library(mt_store)).
:- use_module(library(spse4_core)).
:- use_module(library(spse4_scheduler)).

% Capture the script's directory at load time.  prolog_load_context/2
% is only valid during load, not at runtime, so we snapshot it here.
:- dynamic script_dir_/1.
:- prolog_load_context(directory, SD),
   assertz(script_dir_(SD)).

:- initialization(main, main).

main :-
    catch(main_body_, Error,
          ( format(user_output,
                   "~nSERVER_DEMO FATAL: ~q~n", [Error]),
            flush_output(user_output),
            halt(1) )).

main_body_ :-
    format(user_output, "server_demo: starting~n", []),
    flush_output(user_output),
    setup_demo_users_,
    format(user_output, "server_demo: users configured~n", []),
    flush_output(user_output),
    seed_autopackager_queue_,
    format(user_output, "server_demo: queue seeded~n", []),
    flush_output(user_output),
    locate_web_dir_(WebDir),
    format(user_output, "server_demo: web dir resolved to ~w~n", [WebDir]),
    flush_output(user_output),
    spse4_server_start([ port(4040),
                         acl_mode(permissive),  % local dev only
                         client_dir(WebDir) ]),
    format("~n=====================================================~n"),
    format("SPSE4 demo running.~n"),
    format("  Web UI:     http://localhost:4040/~n"),
    format("  With auth:  http://localhost:4040/?u=alice&p=hunter2&mt=autopackager~n"),
    format("  Projection: http://localhost:4040/projection?mt=autopackager&critical_path=1&goal=flp_release~n"),
    format("  Press Ctrl-C to stop.~n"),
    format("=====================================================~n~n"),
    flush_output,
    thread_get_message(_).       % park forever

%   locate_web_dir_(-Dir) is det.
%
%   Find the spse4-web directory.  Simple, non-throwing: build a
%   list of candidate absolute paths by string concatenation,
%   print them all, pick the first one where index.html exists.
%   On total failure, fall through to a sentinel path that
%   install_client_dir_ will handle gracefully.

locate_web_dir_(WebDir) :-
    script_dir_(ScriptDir),
    working_directory(CWD, CWD),
    Candidates = [
        '/../../spse4-web',
        '/../../../spse4-web',
        '/spse4-web',
        '/../spse4-web'
    ],
    format(user_output, "server_demo: hunting for spse4-web/~n", []),
    format(user_output, "  script dir: ~w~n", [ScriptDir]),
    format(user_output, "  cwd:        ~w~n", [CWD]),
    flush_output(user_output),
    (   find_web_dir_(ScriptDir, CWD, Candidates, Found)
    ->  WebDir = Found,
        format(user_output, "  using:      ~w~n", [WebDir])
    ;   format(user_output,
               "  none found, API-only mode~n", []),
        WebDir = '/nonexistent/spse4-web'
    ),
    flush_output(user_output).

find_web_dir_(_ScriptDir, _CWD, [], _) :- !, fail.
find_web_dir_(ScriptDir, CWD, [Suffix|Rest], Found) :-
    atom_concat(ScriptDir, Suffix, A),
    atom_concat(CWD,       Suffix, B),
    format(user_output, "  trying: ~w~n", [A]),
    format(user_output, "  trying: ~w~n", [B]),
    flush_output(user_output),
    (   valid_web_dir_(A) -> Found = A
    ;   valid_web_dir_(B) -> Found = B
    ;   find_web_dir_(ScriptDir, CWD, Rest, Found)
    ).

valid_web_dir_(Path) :-
    exists_directory(Path),
    atom_concat(Path, '/index.html', Idx),
    exists_file(Idx).

setup_demo_users_ :-
    spse4_user_add(alice, "hunter2",
                   [ read([autopackager, public]),
                     write([autopackager, public]) ]),
    spse4_user_add(bob, "pass",
                   [ read([public]) ]).

seed_autopackager_queue_ :-
    Mt = autopackager,
    (   mt_store:mt_exists(Mt)
    ->  spse4_core:task_list(Mt, Existing),
        forall(member(Id, Existing),
               spse4_core:task_retract(Mt, Id))
    ;   mt_store:mt_create(Mt)
    ),

    % Tasks from v0.1.12's autopackager_demo.pl, in the same order.
    spse4_core:task_create(Mt, pkg_eprover,
        [ has_nl="Package eprover for Debian",
          status=completed ]),
    spse4_core:task_create(Mt, pkg_peleus,
        [ has_nl="Package peleus (Jason/AgentSpeak)",
          status=completed ]),
    spse4_core:task_create(Mt, pkg_vampire,
        [ has_nl="Package vampire ATP",
          status=in_progress,
          earliest_start='2026-04-22',
          duration=fixed(259200) ]),  % 3 days
    spse4_core:task_create(Mt, pkg_acl2,
        [ has_nl="Package ACL2 theorem prover",
          status=open,
          duration=fixed(432000) ]),  % 5 days
    spse4_core:task_create(Mt, pkg_freekbs2,
        [ has_nl="Package FreeKBS2",
          status=open,
          duration=fixed(172800) ]),  % 2 days
    spse4_core:task_create(Mt, submit_autopkg_to_mentors,
        [ has_nl="Submit autopackager batch to Debian mentors",
          status=open,
          duration=fixed(86400) ]),   % 1 day
    spse4_core:task_create(Mt, flp_release,
        [ has_nl="FLP public release candidate",
          status=open,
          latest_finish='2026-05-04',
          duration=fixed(172800) ]),  % 2 days

    % Dependencies (arg order is From, Kind, To).
    spse4_core:edge_assert(Mt, submit_autopkg_to_mentors, depends, pkg_eprover,  []),
    spse4_core:edge_assert(Mt, submit_autopkg_to_mentors, depends, pkg_peleus,   []),
    spse4_core:edge_assert(Mt, submit_autopkg_to_mentors, depends, pkg_vampire,  []),
    spse4_core:edge_assert(Mt, submit_autopkg_to_mentors, depends, pkg_acl2,     []),
    spse4_core:edge_assert(Mt, submit_autopkg_to_mentors, depends, pkg_freekbs2, []),
    spse4_core:edge_assert(Mt, flp_release, depends, submit_autopkg_to_mentors, []),

    format("Seeded ~w with autopackager queue~n", [Mt]).
