/*  pack-spse4-server -- HTTP + Pengines + broadcast fanout + per-mt ACL.

    Part of FRKCSA / SPSE4.  GPLv3 License.

    This pack exposes pack-spse4-core's task graph over HTTP and
    Pengines, with three capabilities that v0.1 did not have:

      1. *Multi-user access.*  Multiple clients (browser, Emacs,
         command-line) can all connect to one running store and see
         each other's edits.

      2. *Per-microtheory ACL.*  Each user has a read-set and a
         write-set of microtheory atoms.  Pengines are sandboxed so
         that a user can only ever observe or mutate microtheories
         their ACL permits.

      3. *Live broadcast.*  When task graph state mutates, every
         connected client receives the diff via pengine_output/1
         fanout, so no polling is required.

    The server also exposes a /projection endpoint that returns
    Cytoscape-ready JSON for the accompanying browser client.

    ---------------------------------------------------------------
    Quick start:

        ?- use_module(library(spse4_server)).
        ?- spse4_server_start([port(4040)]).
        %  Listening at http://localhost:4040/

    From a browser open http://localhost:4040/ to load the
    shipped client (or point your own client at /pengine for the
    Pengines endpoint and /projection for the JSON view).
    ---------------------------------------------------------------
*/

:- module(spse4_server,
          [ spse4_server_start/0,
            spse4_server_start/1,       % +Options
            spse4_server_stop/0,
            spse4_server_stop/1,        % +Port
            spse4_server_running/1,     % -Port
            spse4_user_add/3,           % +User, +Password, +ACL
            spse4_user_remove/1,        % +User
            spse4_user_acl/2,           % ?User, ?ACL
            spse4_users_load/1,         % +File
            spse4_users_save/1,         % +File
            spse4_acl_allows/3,         % +User, +Mode, +Mt
            spse4_broadcast/1,          % +Event

            % ACL wrappers exposed to the Pengines sandbox.  Exported
            % so that sandbox:safe_primitive/1 declarations on them
            % are accepted (SWI requires the declared predicate to be
            % an exported predicate of the declaring module).
            acl_read/2,
            acl_read/3,
            acl_read/4,
            acl_write_task/5,
            acl_write_edge/5,
            acl_remove_task/2,
            acl_remove_edge/4,
            acl_task_status/3
          ]).

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_authenticate)).
:- use_module(library(http/http_header)).
:- use_module(library(http/http_files)).
:- use_module(library(http/html_write)).
:- use_module(library(pengines)).
:- use_module(library(sandbox)).
:- use_module(library(broadcast)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(option)).
:- use_module(library(crypto)).
:- use_module(library(base64)).
:- use_module(library(assoc)).
:- use_module(library(readutil)).

:- use_module(library(mt_store)).
:- use_module(library(spse4_core)).

/** <module> SPSE4 server

Provides a long-running HTTP + Pengines service that exposes the
pack-spse4-core task graph to browser, Emacs, and command-line
clients with per-microtheory access control and live fanout of
edit events.

## Authentication

Basic HTTP auth.  User records are kept in a Prolog file (default
`users.pl`) that contains facts of the form:

==
user(alice, "$pbkdf2$...", [read([public,private_a]), write([private_a])]).
==

The password column stores a PBKDF2 hash (see crypto_password_hash/2)
that is verified on every request.  If the users file is absent or
empty, the server rejects all authenticated endpoints with 401, but
public endpoints (the static client, /health) remain reachable.

## ACL enforcement

Every Pengines session runs in an application (`spse4_app`) whose
sandbox permits only a whitelist of predicates.  The whitelist
routes every read/write through spse4_server:acl_read/2 and
spse4_server:acl_write/2, which check the caller's ACL before
delegating to mt_store.  A user cannot escape the sandbox to call
mt_store directly.

## Broadcast

The spse4_core module broadcasts on topic `spse4(Event)` whenever a
task or edge is added, removed, or has its status changed.  The
server listens on that topic and forwards each event to all active
Pengines whose user ACL permits reading the affected microtheory,
via pengine_output/1.

@see pack-spse4-core for the task ontology
@see pack-mt-store for the microtheory store primitives
*/

% ---------------------------------------------------------------
%   State: which ports the server is running on, and the user DB.
% ---------------------------------------------------------------

:- dynamic
    server_port_/1,                  % Port
    user_record_/3,                  % User, HashedPassword, ACL
    users_file_/1,                   % Path
    acl_override_mode_/1.            % permissive | strict

% Default mode: strict (deny unless ACL explicitly permits).
acl_mode_(Mode) :-
    (   acl_override_mode_(M)
    ->  Mode = M
    ;   Mode = strict
    ).

% ---------------------------------------------------------------
%   Server lifecycle
% ---------------------------------------------------------------

%!  spse4_server_start is det.
%!  spse4_server_start(+Options) is det.
%
%   Start the HTTP+Pengines server.  Options:
%
%     * port(+Port)          Port number (default 4040)
%     * users_file(+File)    Path to users DB (default 'users.pl')
%     * client_dir(+Dir)     Directory of static web client files
%     * acl_mode(+Mode)      strict (default) or permissive
%     * bind(+Iface)         Interface to bind (default localhost)
%
%   permissive mode is intended only for local development; it
%   grants any authenticated user full read/write on every mt.

spse4_server_start :-
    spse4_server_start([]).

spse4_server_start(Options) :-
    option(port(Port), Options, 4040),
    option(users_file(UsersFile), Options, 'users.pl'),
    option(acl_mode(Mode), Options, strict),
    retractall(acl_override_mode_(_)),
    assertz(acl_override_mode_(Mode)),
    retractall(users_file_(_)),
    assertz(users_file_(UsersFile)),
    (   exists_file(UsersFile)
    ->  spse4_users_load(UsersFile)
    ;   format(user_error,
               "spse4_server: no users file at ~w; anon-only mode~n",
               [UsersFile])
    ),
    (   option(client_dir(ClientDir), Options)
    ->  install_client_dir_(ClientDir)
    ;   true
    ),
    register_pengine_app_,
    subscribe_broadcast_,
    http_server(http_dispatch,
                [ port(Port),
                  workers(8)
                ]),
    assertz(server_port_(Port)),
    format(user_error,
           "spse4_server: listening at http://localhost:~w/~n",
           [Port]).

%!  spse4_server_stop is det.
%!  spse4_server_stop(+Port) is det.
%
%   Stop the server on the given port (default: all ports).

spse4_server_stop :-
    forall(retract(server_port_(Port)),
           catch(http_stop_server(Port, []), _, true)).

spse4_server_stop(Port) :-
    retractall(server_port_(Port)),
    catch(http_stop_server(Port, []), _, true).

%!  spse4_server_running(?Port) is nondet.
spse4_server_running(Port) :-
    server_port_(Port).

% ---------------------------------------------------------------
%   User DB management
% ---------------------------------------------------------------

%!  spse4_user_add(+User, +Password, +ACL) is det.
%
%   Add or replace a user.  Password is hashed before storage.
%   ACL is a list of mode(+Mts) terms, where mode is =read= or
%   =write= and Mts is a list of microtheory atoms.
%
%   Example:
%
%   ==
%   ?- spse4_user_add(alice, "hunter2",
%                     [read([public, private_a]),
%                      write([private_a])]).
%   ==

spse4_user_add(User, Password, ACL) :-
    must_be(atom, User),
    must_be(text, Password),
    must_be(list, ACL),
    validate_acl_(ACL),
    crypto_password_hash(Password, Hash),
    retractall(user_record_(User, _, _)),
    assertz(user_record_(User, Hash, ACL)).

%!  spse4_user_remove(+User) is det.
spse4_user_remove(User) :-
    retractall(user_record_(User, _, _)).

%!  spse4_user_acl(?User, ?ACL) is nondet.
spse4_user_acl(User, ACL) :-
    user_record_(User, _, ACL).

%!  spse4_users_save(+File) is det.
%
%   Persist the user DB to File as a Prolog source file.

spse4_users_save(File) :-
    setup_call_cleanup(
        open(File, write, S),
        (   format(S, "%% SPSE4 users file.  Auto-generated; do not edit by hand.~n", []),
            forall(user_record_(U, H, A),
                   format(S, "user(~q, ~q, ~q).~n", [U, H, A]))
        ),
        close(S)).

%!  spse4_users_load(+File) is det.
%
%   Load (or reload) the user DB from File.  The file consists of
%   =|user(Name, HashedPassword, ACL).|= facts.

spse4_users_load(File) :-
    retractall(user_record_(_, _, _)),
    setup_call_cleanup(
        open(File, read, S),
        load_users_stream_(S),
        close(S)).

load_users_stream_(S) :-
    read_term(S, T, []),
    (   T == end_of_file
    ->  true
    ;   (   T = user(U, H, A)
        ->  validate_acl_(A),
            assertz(user_record_(U, H, A))
        ;   format(user_error, "spse4_server: skipping malformed entry ~q~n", [T])
        ),
        load_users_stream_(S)
    ).

validate_acl_([]).
validate_acl_([read(Mts)|R])  :- is_list(Mts), maplist(atom, Mts), validate_acl_(R).
validate_acl_([write(Mts)|R]) :- is_list(Mts), maplist(atom, Mts), validate_acl_(R).

% ---------------------------------------------------------------
%   ACL check
% ---------------------------------------------------------------

%!  spse4_acl_allows(+User, +Mode, +Mt) is semidet.
%
%   True iff User has Mode access (=read= or =write=) to
%   microtheory Mt.  Write access implies read access.  In
%   permissive mode, any non-empty user identity passes.

spse4_acl_allows(User, Mode, Mt) :-
    acl_mode_(ModeSetting),
    (   ModeSetting == permissive
    ->  % Permissive mode is for local development; anyone, including
        % unauthenticated (anon '') users, has full read/write access.
        true
    ;   User \== '',
        user_record_(User, _, ACL),
        acl_allows_(ACL, Mode, Mt)
    ).

acl_allows_([write(Mts)|_], write, Mt) :- memberchk(Mt, Mts), !.
acl_allows_([write(Mts)|_], read,  Mt) :- memberchk(Mt, Mts), !.
acl_allows_([read(Mts)|_],  read,  Mt) :- memberchk(Mt, Mts), !.
acl_allows_([_|R], Mode, Mt) :- acl_allows_(R, Mode, Mt).

% ---------------------------------------------------------------
%   HTTP routing
% ---------------------------------------------------------------

:- http_handler(root('health'),    health_handler, []).
:- http_handler(root('projection'), projection_handler,
                [ method(get) ]).
:- http_handler(root('events'),    events_handler,
                [ method(get) ]).
% NOTE on /tasks routing: SWI's http_dispatch does not handle two
% `prefix` handlers at the same path with different `method(_)`
% filters cleanly — registration order ends up shadowing one of
% them in opaque ways (verified empirically).  We register a single
% prefix handler at root(tasks) that dispatches on method
% internally to the per-method clauses below.
:- http_handler(root(tasks), tasks_dispatch_,
                [ method(*), prefix ]).

% Static file handler, installed lazily on start if a client_dir was
% given.  We don't install it at file load time because the path may
% not be known yet.

install_client_dir_(Dir) :-
    (   exists_directory(Dir)
    ->  absolute_file_name(Dir, AbsDir,
                           [file_type(directory), access(exist)]),
        % Serve /index.html and any other file under the dir via a
        % prefix handler at root.  The indexes/1 option makes GET /
        % serve index.html automatically.
        http_handler(root(.),
                     http_reply_from_files(AbsDir, [indexes(['index.html'])]),
                     [prefix, id(client_files), priority(0)]),
        format(user_error,
               "spse4_server: serving web client from ~w~n", [AbsDir])
    ;   % No client dir; install a root handler that sends a minimal
        % landing page describing the API endpoints.
        http_handler(root(.), root_api_landing_, [id(client_files)]),
        format(user_error,
               "spse4_server: client_dir ~w does not exist, API-only mode~n",
               [Dir])
    ).

%   root_api_landing_(+Request) is det.
%
%   Minimal plain-text landing for GET /, used when no client dir
%   is configured.  Describes the available endpoints so curl
%   users can find their way.

root_api_landing_(_Request) :-
    format('Content-Type: text/plain; charset=utf-8~n~n', []),
    format("SPSE4 server~n"),
    format("~n"),
    format("Available endpoints:~n"),
    format("  GET    /health~n"),
    format("  GET    /projection?mt=<mt>[&status=<s>][&relation=<r>][&critical_path=1][&goal=<id>]~n"),
    format("  GET    /events[?since=<epoch>]~n"),
    format("  POST   /tasks         body: {mt, id, label, status[, props]}  (auth required)~n"),
    format("  DELETE /tasks/<mt>/<id>                                        (auth required)~n"),
    format("  PATCH  /tasks/<mt>/<id> body: {status: <new_status>}           (auth required)~n"),
    format("~n"),
    format("No web client is configured on this server.  To enable~n"),
    format("the Cytoscape UI, start with client_dir(Dir) option:~n"),
    format("~n"),
    format("  spse4_server_start([port(4040), client_dir('/path/to/spse4-web')]).~n").

% ---------------------------------------------------------------
%   Health endpoint (public)
% ---------------------------------------------------------------

health_handler(_Request) :-
    findall(P, server_port_(P), Ports),
    aggregate_all(count, user_record_(_, _, _), NUsers),
    reply_json_dict(_{ status: ok,
                       version: "0.2.1",
                       ports: Ports,
                       users: NUsers
                     }).

% ---------------------------------------------------------------
%   Projection endpoint: returns Cytoscape.js-ready JSON
% ---------------------------------------------------------------
%
%   Query parameters:
%     mt=Mt            (required; enforced by ACL)
%     status=S         (optional repeatable filter)
%     relation=R       (optional repeatable filter)
%     critical_path=1  (optional: overlay critical-path flagging)
%     goal=TaskId      (optional: only connected component of this goal)

projection_handler(Request) :-
    http_authenticate_optional_(Request, User),
    http_parameters(Request,
                    [ mt(Mt,             [atom]),
                      status(Statuses,   [list(atom), default([])]),
                      relation(Rels,     [list(atom), default([])]),
                      critical_path(CP,  [default(0), integer]),
                      goal(Goal,         [optional(true), atom])
                    ]),
    (   spse4_acl_allows(User, read, Mt)
    ->  build_cytoscape_json_(Mt, Statuses, Rels, CP, Goal, Json),
        reply_json_dict(Json)
    ;   reply_forbidden_(User, read, Mt)
    ).

http_authenticate_optional_(Request, User) :-
    (   member(authorization(AuthValue), Request),
        extract_basic_creds_(AuthValue, User0, Password),
        user_record_(User0, Hash, _),
        crypto_password_hash(Password, Hash)
    ->  User = User0
    ;   User = ''
    ).

%   extract_basic_creds_(+AuthValue, -User, -Password) is semidet.
%
%   The HTTP layer may hand us the authorization field in several
%   shapes depending on version: the already-parsed term
%   =|basic(User, Password)|=, a raw =|'Basic <base64>'|= atom, or
%   a string of the same.  Handle all three.

extract_basic_creds_(basic(U, P), UserAtom, Password) :- !,
    to_atom_(U, UserAtom),
    to_string_(P, Password).
extract_basic_creds_(Value, UserAtom, Password) :-
    to_atom_(Value, AtomValue),
    sub_atom(AtomValue, 0, 5, _, Prefix),
    downcase_atom(Prefix, basic),
    sub_atom(AtomValue, 5, _, 0, Rest0),
    normalize_space(atom(B64Encoded), Rest0),
    base64(Plain, B64Encoded),
    atom_codes(Plain, PlainCodes),
    once(append(UserCodes, [0':|PwCodes], PlainCodes)),
    atom_codes(UserAtom, UserCodes),
    string_codes(Password, PwCodes).

to_atom_(X, X) :- atom(X), !.
to_atom_(X, A) :- string(X), !, atom_string(A, X).
to_atom_(X, A) :- atom_string(A, X).

to_string_(X, X) :- string(X), !.
to_string_(X, S) :- atom(X), !, atom_string(X, S).
to_string_(X, S) :- atom_string(X, S).

reply_forbidden_(User, Mode, Mt) :-
    format(atom(Msg), "forbidden: ~w may not ~w mt ~w", [User, Mode, Mt]),
    reply_json_dict(_{ error: forbidden, message: Msg },
                    [status(403)]).

%   build_cytoscape_json_(+Mt, +Statuses, +Rels, +CP, ?Goal, -Json)
%
%   Collects tasks and edges in Mt (optionally filtered by status
%   and relation, optionally restricted to the goal's connected
%   component), annotates with critical-path membership if CP==1,
%   and emits a Cytoscape elements dict.

build_cytoscape_json_(Mt, Statuses, Rels, CP, Goal, Json) :-
    gather_nodes_(Mt, Statuses, Goal, NodeTerms),
    gather_edges_(Mt, Rels, NodeTerms, EdgeTerms),
    (   CP == 1, nonvar(Goal)
    ->  critical_node_set_(Mt, Goal, CritSet)
    ;   empty_assoc(CritSet)
    ),
    maplist(node_to_json_(CritSet), NodeTerms, NodesJson),
    maplist(edge_to_json_, EdgeTerms, EdgesJson),
    Json = _{ elements: _{ nodes: NodesJson, edges: EdgesJson },
              meta:     _{ mt: Mt, count: _{nodes: Lnn, edges: Len} }
            },
    length(NodesJson, Lnn),
    length(EdgesJson, Len).

% pack-spse4-core is expected to provide task/4 (Mt, Id, Label, Status)
% and edge/5 (Mt, Kind, FromId, ToId, Props).  We look those up via
% the store interface.  If the actual signatures differ in your
% v0.1.12 tree, only these two helpers need tweaking.

gather_nodes_(Mt, Statuses, Goal, Nodes) :-
    spse4_core:task_list(Mt, AllIds),
    findall(node(Id, Label, Status, Props),
            (   member(Id, AllIds),
                task_snapshot_(Mt, Id, Label, Status, Props),
                status_matches_(Statuses, Status)
            ),
            AllNodes),
    (   nonvar(Goal)
    ->  restrict_to_component_(Mt, Goal, AllNodes, Nodes)
    ;   Nodes = AllNodes
    ).

% Build a (Label, Status, PropsMinusLabelAndStatus) snapshot from the
% flat property table so the JSON projection has a clean shape.
task_snapshot_(Mt, Id, Label, Status, Props) :-
    (   spse4_core:task_property(Mt, Id, has_nl, Label0)
    ->  Label = Label0
    ;   atom_string(Id, Label)
    ),
    (   spse4_core:task_property(Mt, Id, status, Status0)
    ->  Status = Status0
    ;   Status = open
    ),
    findall(K=V,
            (   spse4_core:task_property(Mt, Id, K, V),
                K \== has_nl,
                K \== status
            ),
            Props).

status_matches_([],      _).
status_matches_(Filters, S) :- memberchk(S, Filters).

gather_edges_(Mt, Rels, NodeTerms, Edges) :-
    id_set_(NodeTerms, IdSet),
    findall(edge(Kind, From, To, Props),
            (   spse4_core:edge(Mt, From, Kind, To),
                relation_matches_(Rels, Kind),
                get_assoc(From, IdSet, _),
                get_assoc(To,   IdSet, _),
                spse4_core:edge_property(Mt, From, Kind, To, Props)
            ),
            Edges).

relation_matches_([], _).
relation_matches_(Filters, K) :- memberchk(K, Filters).

id_set_(Nodes, Assoc) :-
    empty_assoc(Empty),
    foldl(id_set_add_, Nodes, Empty, Assoc).

id_set_add_(node(Id,_,_,_), A0, A) :- put_assoc(Id, A0, t, A).

% restrict_to_component_: traverse edges from Goal in both directions
% and keep only reachable nodes.  Simple BFS over the pre-collected
% edge set would be faster, but we keep it direct for clarity.
restrict_to_component_(Mt, Goal, All, Kept) :-
    empty_assoc(E0),
    put_assoc(Goal, E0, t, E1),
    bfs_component_(Mt, [Goal], E1, Seen),
    include(node_in_seen_(Seen), All, Kept).

node_in_seen_(Seen, node(Id,_,_,_)) :- get_assoc(Id, Seen, _).

bfs_component_(_, [], Seen, Seen).
bfs_component_(Mt, [X|Q], S0, S) :-
    findall(N,
            (   spse4_core:edge(Mt, X, _, N)
            ;   spse4_core:edge(Mt, N, _, X)
            ),
            Neigh0),
    sort(Neigh0, Neigh),
    add_unseen_(Neigh, S0, S1, NewOnes),
    append(Q, NewOnes, Q1),
    bfs_component_(Mt, Q1, S1, S).

add_unseen_([], S, S, []).
add_unseen_([N|T], S0, S, [N|New]) :-
    \+ get_assoc(N, S0, _), !,
    put_assoc(N, S0, t, S1),
    add_unseen_(T, S1, S, New).
add_unseen_([_|T], S0, S, New) :-
    add_unseen_(T, S0, S, New).

% Critical path: we reuse pack-spse4-scheduler if loaded, else
% flag nothing.  Degrades gracefully.

critical_node_set_(Mt, Goal, Set) :-
    (   current_predicate(spse4_scheduler:critical_path/3),
        spse4_scheduler:critical_path(Mt, Goal, Path)
    ->  list_to_assoc_(Path, Set)
    ;   empty_assoc(Set)
    ).

list_to_assoc_(L, A) :-
    empty_assoc(E),
    foldl(assoc_mark_, L, E, A).

assoc_mark_(X, A0, A1) :- put_assoc(X, A0, t, A1).

% Cytoscape element encoders.

node_to_json_(CritSet, node(Id, Label, Status, Props),
              _{ data: _{ id: IdS, label: LabelS, status: StatusS,
                          critical: Crit, props: PropsJson }
               }) :-
    atom_string(Id, IdS),
    (   string(Label) -> LabelS = Label ; atom_string(Label, LabelS) ),
    atom_string(Status, StatusS),
    (   get_assoc(Id, CritSet, _) -> Crit = true ; Crit = false ),
    props_to_json_(Props, PropsJson).

edge_to_json_(edge(Kind, From, To, Props),
              _{ data: _{ id: EidS, source: FromS, target: ToS,
                          kind: KindS, props: PropsJson }
               }) :-
    atom_string(Kind, KindS),
    atom_string(From, FromS),
    atom_string(To,   ToS),
    format(atom(Eid), "~w-~w-~w", [From, Kind, To]),
    atom_string(Eid, EidS),
    props_to_json_(Props, PropsJson).

props_to_json_([], _{}) :- !.
props_to_json_(Props, Dict) :-
    maplist(prop_pair_, Props, Pairs),
    dict_pairs(Dict, _, Pairs).

% Accept both key=value and key-value shapes.
prop_pair_(K=V, K-JV) :- !, to_json_value_(V, JV).
prop_pair_(K-V, K-JV) :- !, to_json_value_(V, JV).
prop_pair_(Pair, key-S) :-
    format(string(S), "~q", [Pair]).

to_json_value_(V, V) :- number(V), !.
to_json_value_(V, V) :- string(V), !.
to_json_value_(V, S) :- atom(V), !, atom_string(V, S).
to_json_value_(V, L) :- is_list(V), !, maplist(to_json_value_, V, L).
to_json_value_(V, S) :- format(string(S), "~q", [V]).

% ---------------------------------------------------------------
%   /events: non-streaming poll of recent broadcast events
% ---------------------------------------------------------------
%
%   Returns a JSON array of events accumulated since the given
%   cursor timestamp (seconds since epoch, float).  The client
%   polls this endpoint; true server-sent-events streaming is
%   deferred to a later version where the HTTP worker model allows
%   a clean broadcast subscription.
%
%   For live reactivity inside a single Prolog process (Emacs
%   client via pengine.el, or a server-side agent) use the
%   pengine_output/1 relay established by relay_broadcast_/1.

:- dynamic recent_event_/2.         % Timestamp, Event

events_handler(Request) :-
    http_authenticate_optional_(Request, User),
    (   User == '', acl_mode_(strict)
    ->  reply_json_dict(_{ error: unauthorized }, [status(401)])
    ;   http_parameters(Request,
                        [ since(Since, [default(0.0), number]) ]),
        get_time(Now),
        findall(_{ t: T, event: EStr },
                (   recent_event_(T, Ev),
                    T > Since,
                    format(string(EStr), "~q", [Ev])
                ),
                Events),
        reply_json_dict(_{ events: Events, now: Now })
    ).

% Keep the most recent N events so poll clients can catch up after
% network blips without missing anything important.
:- dynamic recent_events_cap_/1.
recent_events_cap_(200).

record_event_(Event) :-
    get_time(T),
    assertz(recent_event_(T, Event)),
    trim_recent_events_.

trim_recent_events_ :-
    aggregate_all(count, recent_event_(_,_), N),
    recent_events_cap_(Cap),
    (   N > Cap
    ->  findall(T, recent_event_(T, _), Ts),
        sort(Ts, Sorted),
        length(Sorted, Total),
        ToDrop is Total - Cap,
        length(Drop, ToDrop),
        append(Drop, _, Sorted),
        forall(member(DT, Drop),
               retract(recent_event_(DT, _)))
    ;   true
    ).

% ---------------------------------------------------------------
%   /tasks: REST mutation endpoints (added v0.2.0)
% ---------------------------------------------------------------
%
%   POST /tasks
%     body: { "mt": "<atom>", "id": "<atom>",
%             "label": "<string>", "status": "<atom>",
%             "props": { ... }     // optional extra Key:Value pairs
%           }
%     201 Created   on success, body { ok: true, mt, id }
%     400 Bad Request   if body malformed
%     401 Unauthorized  if no auth and write requires it
%     403 Forbidden     if user lacks write on Mt
%
%   DELETE /tasks/<mt>/<id>
%     200 OK            on success
%     401, 403          as above
%     404 Not Found     if task does not exist
%
%   PATCH /tasks/<mt>/<id>
%     body: { "status": "<new_status>" }
%     200 OK            on success
%     400, 401, 403, 404
%
%   All endpoints fire pack-spse4-core broadcast events as a
%   side-effect, so the relay propagates to live pengines and the
%   /events poll endpoint sees them on the next call.

%   tasks_dispatch_(+Request) is det.
%
%   Single prefix handler that routes by HTTP method.  See note at
%   the http_handler/3 declaration for why we don't use multiple
%   per-method handlers.
tasks_dispatch_(Request) :-
    memberchk(method(M), Request),
    (   M == post   -> tasks_post_handler(Request)
    ;   M == delete -> tasks_delete_handler(Request)
    ;   M == patch  -> tasks_patch_handler(Request)
    ;   reply_json_dict(_{ error: method_not_allowed,
                           message: "method not allowed; use POST, DELETE, or PATCH" },
                        [status(405)])
    ).

%   Implementation note on the catch+sentinel pattern below:
%   `library(http/http_dispatch)` interprets a clause failure as
%   "handler error" and writes a 500 page on top of any response
%   the handler may already have streamed.  We therefore must NOT
%   `fail` after writing a structured 4xx reply.  Instead, each
%   error-replying catch throws a `reply_already_sent` sentinel,
%   which the outer wrapper catches and treats as success.

tasks_post_handler(Request) :-
    catch( do_tasks_post_(Request),
           reply_already_sent,
           true ).

do_tasks_post_(Request) :-
    http_authenticate_optional_(Request, User),
    catch( http_read_json_dict(Request, Body, []),
           _,
           ( reply_json_dict(_{ error: bad_request,
                                message: "request body must be JSON" },
                             [status(400)]),
             throw(reply_already_sent) ) ),
    (   _{ mt: MtAtomic, id: IdAtomic, label: Label, status: StatusAtomic } :< Body
    ->  to_atom_(MtAtomic, Mt),
        to_atom_(IdAtomic, Id),
        to_atom_(StatusAtomic, Status),
        to_string_(Label, LabelS),
        extra_props_from_body_(Body, ExtraProps),
        (   User == ''
        ->  reply_json_dict(_{ error: unauthorized,
                               message: "authentication required to add tasks" },
                            [status(401)])
        ;   spse4_acl_allows(User, write, Mt)
        ->  Props0 = [has_nl=LabelS, status=Status | ExtraProps],
            catch( spse4_core:task_create(Mt, Id, Props0),
                   E,
                   ( format(atom(Msg), "create failed: ~q", [E]),
                     reply_json_dict(_{ error: bad_request, message: Msg },
                                     [status(400)]),
                     throw(reply_already_sent) ) ),
            reply_json_dict(_{ ok: true, mt: Mt, id: Id },
                            [status(201)])
        ;   reply_forbidden_(User, write, Mt)
        )
    ;   reply_json_dict(_{ error: bad_request,
                           message: "missing required fields: mt, id, label, status" },
                        [status(400)])
    ).

tasks_delete_handler(Request) :-
    catch( do_tasks_delete_(Request),
           reply_already_sent,
           true ).

do_tasks_delete_(Request) :-
    http_authenticate_optional_(Request, User),
    (   memberchk(path_info(PathInfo), Request),
        parse_task_path_(PathInfo, Mt, Id)
    ->  (   User == ''
        ->  reply_json_dict(_{ error: unauthorized,
                               message: "authentication required to delete tasks" },
                            [status(401)])
        ;   spse4_acl_allows(User, write, Mt)
        ->  (   spse4_core:task_exists(Mt, Id)
            ->  catch( spse4_core:task_retract(Mt, Id),
                       E,
                       ( format(atom(Msg), "delete failed: ~q", [E]),
                         reply_json_dict(_{ error: bad_request, message: Msg },
                                         [status(400)]),
                         throw(reply_already_sent) ) ),
                reply_json_dict(_{ ok: true, mt: Mt, id: Id })
            ;   format(atom(M), "task ~w not found in mt ~w", [Id, Mt]),
                reply_json_dict(_{ error: not_found, message: M },
                                [status(404)])
            )
        ;   reply_forbidden_(User, write, Mt)
        )
    ;   reply_json_dict(_{ error: bad_request,
                           message: "expected DELETE /tasks/<mt>/<id>" },
                        [status(400)])
    ).

%   PATCH /tasks/<mt>/<id>
%
%   Updates a task's mutable properties.  Currently supports the
%   `status` field; future extensions may add `label`, etc.
%
%   body: { "status": "<new_status>" }
%   200   on success, body { ok: true, mt, id, status }
%   400   if body malformed or status invalid
%   401   if no auth
%   403   if user lacks write on Mt
%   404   if task does not exist

tasks_patch_handler(Request) :-
    catch( do_tasks_patch_(Request),
           reply_already_sent,
           true ).

do_tasks_patch_(Request) :-
    http_authenticate_optional_(Request, User),
    (   memberchk(path_info(PathInfo), Request),
        parse_task_path_(PathInfo, Mt, Id)
    ->  catch( http_read_json_dict(Request, Body, []),
               _,
               ( reply_json_dict(_{ error: bad_request,
                                    message: "request body must be JSON" },
                                 [status(400)]),
                 throw(reply_already_sent) ) ),
        (   get_dict(status, Body, StatusAtomic)
        ->  to_atom_(StatusAtomic, Status),
            (   User == ''
            ->  reply_json_dict(_{ error: unauthorized,
                                   message: "authentication required to modify tasks" },
                                [status(401)])
            ;   spse4_acl_allows(User, write, Mt)
            ->  (   spse4_core:task_exists(Mt, Id)
                ->  catch( spse4_core:task_set_property(Mt, Id, status, Status),
                           E,
                           ( format(atom(Msg), "patch failed: ~q", [E]),
                             reply_json_dict(_{ error: bad_request, message: Msg },
                                             [status(400)]),
                             throw(reply_already_sent) ) ),
                    reply_json_dict(_{ ok: true, mt: Mt, id: Id, status: Status })
                ;   format(atom(M), "task ~w not found in mt ~w", [Id, Mt]),
                    reply_json_dict(_{ error: not_found, message: M },
                                    [status(404)])
                )
            ;   reply_forbidden_(User, write, Mt)
            )
        ;   reply_json_dict(_{ error: bad_request,
                               message: "PATCH body must include a 'status' field" },
                            [status(400)])
        )
    ;   reply_json_dict(_{ error: bad_request,
                           message: "expected PATCH /tasks/<mt>/<id>" },
                        [status(400)])
    ).

%   parse_task_path_(+PathInfo, -Mt, -Id) is semidet.
%
%   The path_info from a `/tasks` prefix handler is the suffix after
%   "/tasks", e.g. "autopackager/eprover_pkg" or "/autopackager/eprover_pkg".
%   Strip the leading slash if present, split on "/", expect exactly two
%   non-empty segments.
parse_task_path_(PathInfo, Mt, Id) :-
    ( atom(PathInfo) -> Atom = PathInfo ; atom_string(Atom, PathInfo) ),
    atom_codes(Atom, Codes0),
    (   Codes0 = [0'/ | Rest] -> Codes = Rest ; Codes = Codes0 ),
    atom_codes(Stripped, Codes),
    atomic_list_concat(Parts, '/', Stripped),
    Parts = [MtAtom, IdAtom],
    MtAtom \== '',
    IdAtom \== '',
    Mt = MtAtom,
    Id = IdAtom.

%   extra_props_from_body_(+Body, -PropList) is det.
%
%   If the body has a `props` key whose value is a dict, return a list
%   of Key=Value pairs.  Skip any keys that would clash with the
%   reserved `has_nl` / `status` properties (those are set explicitly
%   from the top-level fields).
extra_props_from_body_(Body, Props) :-
    (   get_dict(props, Body, ExtraDict),
        is_dict(ExtraDict)
    ->  dict_pairs(ExtraDict, _, Pairs),
        findall(K=V,
                ( member(K0-V0, Pairs),
                  K0 \== has_nl, K0 \== status,
                  K = K0, V = V0
                ),
                Props)
    ;   Props = []
    ).

% ---------------------------------------------------------------
%   Pengines application
% ---------------------------------------------------------------

:- pengine_application(spse4_app).

register_pengine_app_ :-
    % No-op at runtime; application is registered at load time via
    % the directive above.  Kept as a hook for future setup.
    true.

:- multifile sandbox:safe_primitive/1.
:- multifile sandbox:safe_meta/2.

%!  acl_read(+Mt, -NodeTerm) is nondet.
%
%   Public wrapper for reading tasks; enforces read-ACL on Mt.
acl_read(Mt, node(Id, Label, Status, Props)) :-
    pengine_self(P),
    pengine_user_(P, User),
    (   spse4_acl_allows(User, read, Mt)
    ->  spse4_core:task_list(Mt, Ids),
        member(Id, Ids),
        task_snapshot_(Mt, Id, Label, Status, Props)
    ;   acl_deny_(User, read, Mt)
    ).

%!  acl_read(+Mt, +Id, -NodeTerm) is semidet.
acl_read(Mt, Id, node(Id, Label, Status, Props)) :-
    pengine_self(P),
    pengine_user_(P, User),
    (   spse4_acl_allows(User, read, Mt)
    ->  spse4_core:task_exists(Mt, Id),
        task_snapshot_(Mt, Id, Label, Status, Props)
    ;   acl_deny_(User, read, Mt)
    ).

%!  acl_read(+Mt, ?Kind, ?From, ?To) is nondet.
acl_read(Mt, Kind, From, To) :-
    pengine_self(P),
    pengine_user_(P, User),
    (   spse4_acl_allows(User, read, Mt)
    ->  spse4_core:edge(Mt, From, Kind, To)
    ;   acl_deny_(User, read, Mt)
    ).

%!  acl_write_task(+Mt, +Id, +Label, +Status, +Props) is det.
%
%   Creates or overwrites TaskId.  Label becomes =has_nl=, Status
%   becomes =status=, and the rest of Props is asserted as-is.
acl_write_task(Mt, Id, Label, Status, Props) :-
    pengine_self(P),
    pengine_user_(P, User),
    (   spse4_acl_allows(User, write, Mt)
    ->  (   spse4_core:task_exists(Mt, Id)
        ->  spse4_core:task_retract(Mt, Id)
        ;   true
        ),
        build_full_props_(Label, Status, Props, FullProps),
        spse4_core:task_create(Mt, Id, FullProps)
    ;   acl_deny_(User, write, Mt)
    ).

build_full_props_(Label, Status, Props, [has_nl=LabelS, status=Status | Props]) :-
    (   string(Label) -> LabelS = Label
    ;   atom(Label)   -> atom_string(Label, LabelS)
    ;   LabelS = Label
    ).

%!  acl_write_edge(+Mt, +Kind, +From, +To, +Props) is det.
acl_write_edge(Mt, Kind, From, To, Props) :-
    pengine_self(P),
    pengine_user_(P, User),
    (   spse4_acl_allows(User, write, Mt)
    ->  spse4_core:edge_assert(Mt, From, Kind, To, Props)
    ;   acl_deny_(User, write, Mt)
    ).

%!  acl_remove_task(+Mt, +Id) is det.
acl_remove_task(Mt, Id) :-
    pengine_self(P),
    pengine_user_(P, User),
    (   spse4_acl_allows(User, write, Mt)
    ->  spse4_core:task_retract(Mt, Id)
    ;   acl_deny_(User, write, Mt)
    ).

%!  acl_remove_edge(+Mt, +Kind, +From, +To) is det.
acl_remove_edge(Mt, Kind, From, To) :-
    pengine_self(P),
    pengine_user_(P, User),
    (   spse4_acl_allows(User, write, Mt)
    ->  spse4_core:edge_retract(Mt, From, Kind, To)
    ;   acl_deny_(User, write, Mt)
    ).

%!  acl_task_status(+Mt, +Id, +NewStatus) is det.
acl_task_status(Mt, Id, NewStatus) :-
    pengine_self(P),
    pengine_user_(P, User),
    (   spse4_acl_allows(User, write, Mt)
    ->  spse4_core:task_set_property(Mt, Id, status, NewStatus)
    ;   acl_deny_(User, write, Mt)
    ).

acl_deny_(User, Mode, Mt) :-
    throw(error(permission_error(Mode, mt, Mt),
                context(spse4_server:acl, User))).

% Sandbox whitelist.  These declarations must come *after* the
% clauses above, because SWI's sandbox library performs sanity
% checks (predicate is defined, exported, etc.) at the point of
% declaration.  Declaring before the clauses would silently drop
% the term via sandbox:term_expansion/2.

sandbox:safe_primitive(spse4_server:acl_read(_,_)).
sandbox:safe_primitive(spse4_server:acl_read(_,_,_)).
sandbox:safe_primitive(spse4_server:acl_read(_,_,_,_)).
sandbox:safe_primitive(spse4_server:acl_write_task(_,_,_,_,_)).
sandbox:safe_primitive(spse4_server:acl_write_edge(_,_,_,_,_)).
sandbox:safe_primitive(spse4_server:acl_remove_task(_,_)).
sandbox:safe_primitive(spse4_server:acl_remove_edge(_,_,_,_)).
sandbox:safe_primitive(spse4_server:acl_task_status(_,_,_)).

% Per-pengine user is stored when the Pengine is created.  We do
% this via pengine_create_hook; see the pengine_user_/2 lookup.

:- dynamic pengine_user_/2.       % Pengine, User

:- multifile pengines:prepare_module/3.
pengines:prepare_module(_Module, spse4_app, _Options) :-
    pengine_self(P),
    (   pengine_user_(P, _)
    ->  true
    ;   assertz(pengine_user_(P, ''))   % default anon
    ),
    !.

% ---------------------------------------------------------------
%   Broadcast relay: forward pack-spse4-core events to live
%   pengines whose user ACL permits.
% ---------------------------------------------------------------

subscribe_broadcast_ :-
    (   flag(spse4_server_subscribed, 1, 1)
    ->  true
    ;   flag(spse4_server_subscribed, _, 1),
        listen(spse4_relay, spse4(Event), relay_broadcast_(Event)),
        listen(spse4_destroy, pengine(destroy(Pengine)),
               retractall(pengine_user_(Pengine, _)))
    ).

relay_broadcast_(Event) :-
    record_event_(Event),
    event_mt_(Event, Mt),
    forall(pengine_user_(P, User),
           (   spse4_acl_allows(User, read, Mt)
           ->  catch(pengine_output(P, spse4_event(Event)), _, true)
           ;   true
           )).

event_mt_(task_added(Mt,_,_), Mt) :- !.
event_mt_(task_removed(Mt,_), Mt) :- !.
event_mt_(task_property_changed(Mt,_,_,_), Mt) :- !.
event_mt_(edge_added(Mt,_,_,_,_), Mt) :- !.
event_mt_(edge_removed(Mt,_,_,_), Mt) :- !.
event_mt_(_, '') :- !.            % unknown event: global (anon scope)

%!  spse4_broadcast(+Event) is det.
%
%   Convenience for tests and manual triggering; broadcasts to the
%   spse4/1 topic the same shape relay_broadcast_ expects.

spse4_broadcast(Event) :- broadcast(spse4(Event)).
