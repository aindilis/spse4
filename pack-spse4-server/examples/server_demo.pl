/*  examples/server_demo.pl

    Launches spse4_server on port 4040 with the autopackager task
    queue from v0.1.12's autopackager_demo.pl seeded into the
    microtheory `autopackager`.

    User accounts are looked up in this order; the first one that
    exists is used and the rest are skipped:

        1. The file named by the SPSE4_USERS environment variable,
           if set.
        2. ~/.config/spse4/users.pl, if it exists.
        3. Built-in fallback: seeds two demo users in memory:
              demo:  read+write on `autopackager` and `public`
              bob:   read-only on `public`

    The lookup files are normal Prolog source consulted with consult/1,
    so directives like `:- spse4_user_add(name, "plaintext", ACL).`
    work directly; the password gets hashed at load time.  See
    pack-spse4-server/README.md for examples and recommended file
    permissions (0600).

    The server binds to localhost only by default.  Set
    SPSE4_BIND=0.0.0.0 in the environment to listen on every
    interface (e.g. so other machines on your LAN or your Tailnet
    can reach it).  Note that HTTP basic auth over plaintext HTTP
    is not safe to expose past localhost without TLS in front.

    Usage (from the spse4/ root):

        swipl pack-spse4-server/examples/server_demo.pl

    Then open http://localhost:4040/ in a browser, or hit the
    projection endpoint directly:

        curl -u demo:demo \
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
    setup_demo_users_(UserSource),
    format(user_output, "server_demo: users configured (~w)~n", [UserSource]),
    flush_output(user_output),
    backend_spec_from_env_(BackendSpec),
    format(user_output, "server_demo: backend = ~w~n", [BackendSpec]),
    flush_output(user_output),
    locate_web_dir_(WebDir),
    format(user_output, "server_demo: web dir resolved to ~w~n", [WebDir]),
    flush_output(user_output),
    %  Bind to localhost by default; SPSE4_BIND=0.0.0.0 (or any
    %  specific IP) overrides for LAN / Tailnet exposure.  Plain
    %  basic-auth over HTTP is only safe on localhost.
    (   getenv('SPSE4_BIND', BindStr), BindStr \= ''
    ->  atom_string(BindAtom, BindStr)
    ;   BindAtom = localhost
    ),
    spse4_server_start([ port(4040),
                         acl_mode(permissive),  % local dev only
                         bind(BindAtom),
                         client_dir(WebDir),
                         mt_store_backend(BackendSpec) ]),
    %  Seed AFTER spse4_server_start, so the assertions go into the
    %  selected backend rather than into the memory default.  The
    %  seeder is idempotent: if the autopackager mt already has the
    %  expected tasks (e.g. carried over from a prior MySQL session),
    %  the seeder is a no-op.
    seed_autopackager_queue_,
    format(user_output, "server_demo: queue seeded~n", []),
    flush_output(user_output),
    format("~n=====================================================~n"),
    format("SPSE4 demo running.~n"),
    format("  Web UI:     http://localhost:4040/~n"),
    (   UserSource = builtin_demo
    ->  format("  With auth:  http://localhost:4040/?u=demo&p=demo&mt=autopackager~n")
    ;   format("  Auth:       use the credentials from ~w~n", [UserSource])
    ),
    format("  Projection: http://localhost:4040/projection?mt=autopackager&critical_path=1&goal=flp_release~n"),
    (   BindAtom == localhost
    ->  true
    ;   format("  Bind:       ~w  (reachable beyond localhost)~n", [BindAtom])
    ),
    format("  Press Ctrl-C to stop.~n"),
    format("=====================================================~n~n"),
    flush_output,
    thread_get_message(_).       % park forever

%   backend_spec_from_env_(-Spec) is det.
%
%   Build the mt_store_backend/1 option value from environment
%   variables.  Set SPSE4_MYSQL_DSN to enable the persistent MySQL
%   backend; otherwise the demo runs in memory-only mode (the
%   v0.2.x default), which is fine for kicking the tires but loses
%   state at process exit.
%
%   Recognized env vars:
%     SPSE4_MYSQL_DSN   ODBC alias from ~/.odbc.ini.  Required to
%                       enable MySQL.  When unset or empty, falls
%                       back to memory.
%     SPSE4_MYSQL_USER  DB user (optional; usually in the DSN)
%     SPSE4_MYSQL_PASS  DB password (optional; usually in the DSN)
%     SPSE4_MYSQL_DB    DB name (informational only)

backend_spec_from_env_(Spec) :-
    (   getenv('SPSE4_MYSQL_DSN', DsnStr), DsnStr \= ''
    ->  atom_string(Dsn, DsnStr),
        env_user_opt_(UserOpt),
        env_pass_opt_(PassOpt),
        env_db_opt_(DbOpt),
        append([ [connection_id(Dsn), dsn(Dsn)],
                 UserOpt, PassOpt, DbOpt ], MySqlOpts),
        Spec = mysql(MySqlOpts)
    ;   Spec = memory
    ).

env_user_opt_([user(A)]) :-
    getenv('SPSE4_MYSQL_USER', S), S \= '', !,
    atom_string(A, S).
env_user_opt_([]).

env_pass_opt_([password(P)]) :-
    getenv('SPSE4_MYSQL_PASS', P), P \= '', !.
env_pass_opt_([]).

env_db_opt_([database(A)]) :-
    getenv('SPSE4_MYSQL_DB', S), S \= '', !,
    atom_string(A, S).
env_db_opt_([]).

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

%   setup_demo_users_(-Source) is det.
%
%   Configure user accounts for the demo.  Tries three sources in
%   order; the first that succeeds wins, and Source is bound to a
%   tag describing which one ran.  None of these branches ever
%   throw on a missing file: a missing file just means "skip this
%   source, try the next."  A malformed file is reported on stderr
%   and the next source is tried.
%
%   Source values:
%     - the absolute path of a loaded file (env var or ~/.config),
%     - or the atom =|builtin_demo|= if the in-memory fallback ran.

setup_demo_users_(Source) :-
    (   getenv('SPSE4_USERS', PathStr), PathStr \= '',
        atom_string(EnvPath, PathStr),
        try_load_users_file_(EnvPath)
    ->  Source = EnvPath
    ;   home_users_path_(HomePath),
        try_load_users_file_(HomePath)
    ->  Source = HomePath
    ;   load_builtin_demo_users_,
        Source = builtin_demo
    ).

home_users_path_(Path) :-
    expand_file_name('~/.config/spse4/users.pl', [Path]).

%   try_load_users_file_(+Path) is semidet.
%
%   Succeeds iff the file exists, is readable, and consults without
%   throwing.  Consult is used (rather than spse4_users_load/1) so
%   that directives like `:- spse4_user_add(X, "plain", ACL).` work
%   directly: the user writes plaintext, the predicate hashes.

try_load_users_file_(Path) :-
    exists_file(Path),
    catch( consult(Path),
           Error,
           ( format(user_error,
                    "server_demo: ~w failed to load: ~q~n",
                    [Path, Error]),
             fail ) ).

load_builtin_demo_users_ :-
    spse4_user_add(demo, "demo",
                   [ read([autopackager, public]),
                     write([autopackager, public]) ]),
    spse4_user_add(bob, "pass",
                   [ read([public]) ]).

seed_autopackager_queue_ :-
    Mt = autopackager,
    %  Idempotent semantics: only seed if the autopackager mt is
    %  brand-new (or has been emptied).  This matters for the MySQL
    %  backend, where state survives across restarts: we don't want
    %  to wipe the user's hand-crafted tasks every time the demo
    %  server bounces.  For memory-only mode, the mt is always empty
    %  on startup and seeding always runs.
    (   mt_store:mt_exists(Mt)
    ->  spse4_core:task_list(Mt, Existing),
        (   Existing == []
        ->  do_seed_(Mt)
        ;   format(user_output,
                   "server_demo: autopackager mt has ~w tasks; \c
                    skipping seed~n",
                   [Existing]),
            flush_output(user_output)
        )
    ;   mt_store:mt_create(Mt),
        do_seed_(Mt)
    ).

do_seed_(Mt) :-
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
    spse4_core:task_create(Mt, submit_autopkg_to_frkcsa_repos,
        [ has_nl="Submit autopackager batch to FRKCSA package repositories",
          status=open,
          duration=fixed(86400) ]),   % 1 day
    spse4_core:task_create(Mt, flp_release,
        [ has_nl="FLP public release candidate",
          status=open,
          latest_finish='2026-05-04',
          duration=fixed(172800) ]),  % 2 days

    % Dependencies (arg order is From, Kind, To).
    spse4_core:edge_assert(Mt, submit_autopkg_to_frkcsa_repos, depends, pkg_eprover,  []),
    spse4_core:edge_assert(Mt, submit_autopkg_to_frkcsa_repos, depends, pkg_peleus,   []),
    spse4_core:edge_assert(Mt, submit_autopkg_to_frkcsa_repos, depends, pkg_vampire,  []),
    spse4_core:edge_assert(Mt, submit_autopkg_to_frkcsa_repos, depends, pkg_acl2,     []),
    spse4_core:edge_assert(Mt, submit_autopkg_to_frkcsa_repos, depends, pkg_freekbs2, []),
    spse4_core:edge_assert(Mt, flp_release, depends, submit_autopkg_to_frkcsa_repos, []),

    format("Seeded ~w with autopackager queue~n", [Mt]).
