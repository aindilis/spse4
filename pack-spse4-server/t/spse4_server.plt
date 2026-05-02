/*  t/spse4_server.plt  --  PlUnit tests for pack-spse4-server.

    Tests are self-contained: each test block starts a server on a
    random high port, exercises it with library(http/http_open), and
    stops it.  The tests do NOT require the Pengines JS client --
    they validate the server's HTTP surface and ACL logic directly.

    MIT License.  Part of FRKCSA / SPSE4.
*/

:- begin_tests(spse4_server).

:- use_module(library(spse4_server)).
:- use_module(library(mt_store)).
:- use_module(library(spse4_core)).
:- use_module(library(http/http_open)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_client)).
:- use_module(library(http/json)).
:- use_module(library(broadcast)).
:- use_module(library(lists)).

% ---------------------------------------------------------------
%   Helpers
% ---------------------------------------------------------------

pick_port_(Port) :-
    % Walk a small range to avoid collisions with any service
    % already using a well-known port.  14040..14060.
    between(14040, 14060, Port),
    \+ spse4_server:server_port_(Port),
    !.

setup_server_(Port) :-
    pick_port_(Port),
    spse4_server_start([ port(Port),
                         users_file('/nonexistent/users.pl'),
                         acl_mode(permissive) ]).

teardown_server_(Port) :-
    spse4_server_stop(Port).

%   Seed a microtheory with three tasks and two dependency edges.
%   Idempotent: retracts any pre-existing tasks before asserting.

seed_graph_(Mt) :-
    (   mt_store:mt_exists(Mt)
    ->  true
    ;   mt_store:mt_create(Mt)
    ),
    spse4_core:task_list(Mt, Existing),
    forall(member(Id, Existing),
           spse4_core:task_retract(Mt, Id)),
    spse4_core:task_create(Mt, t1, [has_nl="Task 1", status=open]),
    spse4_core:task_create(Mt, t2, [has_nl="Task 2", status=in_progress]),
    spse4_core:task_create(Mt, t3, [has_nl="Task 3", status=completed]),
    spse4_core:edge_assert(Mt, t2, depends, t1, []),
    spse4_core:edge_assert(Mt, t3, depends, t2, []).

%   Force strict mode without starting a server (for pure ACL
%   checks that should not be affected by whatever mode the last
%   running-server test left in place).

with_strict_mode_(Goal) :-
    (   spse4_server:acl_override_mode_(Prev)
    ->  true
    ;   Prev = strict
    ),
    setup_call_cleanup(
        ( retractall(spse4_server:acl_override_mode_(_)),
          assertz(spse4_server:acl_override_mode_(strict)) ),
        Goal,
        ( retractall(spse4_server:acl_override_mode_(_)),
          assertz(spse4_server:acl_override_mode_(Prev)) )).

% ---------------------------------------------------------------
%   Lifecycle
% ---------------------------------------------------------------

test(start_and_stop) :-
    setup_server_(Port),
    spse4_server_running(Port),
    spse4_server_stop(Port),
    \+ spse4_server_running(Port).

test(health_endpoint) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( format(string(URL), "http://localhost:~w/health", [Port]),
          http_open(URL, Stream, []),
          json_read_dict(Stream, Dict),
          close(Stream),
          assertion(Dict.status == "ok"),
          assertion(Dict.version == "0.1.0")
        ),
        teardown_server_(Port)).

% ---------------------------------------------------------------
%   User DB
% ---------------------------------------------------------------

test(user_add_and_acl) :-
    with_strict_mode_(
        ( spse4_user_remove(alice),
          spse4_user_add(alice, "hunter2",
                         [read([public, priv_a]), write([priv_a])]),
          spse4_user_acl(alice, ACL),
          assertion(memberchk(read([public, priv_a]), ACL)),
          assertion(spse4_acl_allows(alice, read, public)),
          assertion(spse4_acl_allows(alice, read, priv_a)),
          assertion(spse4_acl_allows(alice, write, priv_a)),
          \+ spse4_acl_allows(alice, write, public),
          \+ spse4_acl_allows(alice, read, secret)
        )).

test(user_save_and_reload) :-
    tmp_file_stream(text, Path, S), close(S),
    spse4_user_remove(bob),
    spse4_user_add(bob, "p4ss", [read([x]), write([x])]),
    spse4_users_save(Path),
    spse4_user_remove(bob),
    \+ spse4_user_acl(bob, _),
    spse4_users_load(Path),
    spse4_user_acl(bob, ACL),
    assertion(memberchk(write([x]), ACL)),
    catch(delete_file(Path), _, true).

% ---------------------------------------------------------------
%   Projection endpoint
% ---------------------------------------------------------------

test(projection_returns_cytoscape_json) :-
    seed_graph_(test_mt_1),
    setup_call_cleanup(
        setup_server_(Port),
        ( format(string(URL),
                 "http://localhost:~w/projection?mt=test_mt_1",
                 [Port]),
          http_open(URL, S, []),
          json_read_dict(S, D),
          close(S),
          Nodes = D.elements.nodes,
          Edges = D.elements.edges,
          assertion(is_list(Nodes)),
          assertion(is_list(Edges)),
          length(Nodes, NN), assertion(NN == 3),
          length(Edges, NE), assertion(NE == 2)
        ),
        teardown_server_(Port)).

test(projection_status_filter) :-
    seed_graph_(test_mt_2),
    setup_call_cleanup(
        setup_server_(Port),
        ( format(string(URL),
                 "http://localhost:~w/projection?mt=test_mt_2&status=open",
                 [Port]),
          http_open(URL, S, []),
          json_read_dict(S, D),
          close(S),
          length(D.elements.nodes, N),
          assertion(N == 1)
        ),
        teardown_server_(Port)).

test(projection_meta_counts) :-
    seed_graph_(test_mt_3),
    setup_call_cleanup(
        setup_server_(Port),
        ( format(string(URL),
                 "http://localhost:~w/projection?mt=test_mt_3",
                 [Port]),
          http_open(URL, S, []),
          json_read_dict(S, D),
          close(S),
          assertion(D.meta.mt == "test_mt_3"),
          assertion(D.meta.count.nodes == 3),
          assertion(D.meta.count.edges == 2)
        ),
        teardown_server_(Port)).

% ---------------------------------------------------------------
%   ACL enforcement in strict mode
% ---------------------------------------------------------------

test(strict_mode_denies_unknown_user) :-
    seed_graph_(test_mt_4),
    pick_port_(Port),
    spse4_server_start([ port(Port),
                         users_file('/nonexistent/users.pl'),
                         acl_mode(strict) ]),
    setup_call_cleanup(
        true,
        ( format(string(URL),
                 "http://localhost:~w/projection?mt=test_mt_4",
                 [Port]),
          catch(
              ( http_open(URL, S, [status_code(Code)]),
                close(S)
              ),
              _,
              Code = 403),
          assertion(Code == 403)
        ),
        spse4_server_stop(Port)).

test(strict_mode_allows_authed_user) :-
    seed_graph_(test_mt_5),
    spse4_user_add(carol, "pw", [read([test_mt_5])]),
    pick_port_(Port),
    spse4_server_start([ port(Port),
                         users_file('/nonexistent/users.pl'),
                         acl_mode(strict) ]),
    setup_call_cleanup(
        true,
        ( format(string(URL),
                 "http://localhost:~w/projection?mt=test_mt_5",
                 [Port]),
          http_open(URL, S,
                    [ authorization(basic(carol, "pw")) ]),
          json_read_dict(S, D),
          close(S),
          length(D.elements.nodes, N),
          assertion(N == 3)
        ),
        ( spse4_server_stop(Port),
          spse4_user_remove(carol) )).

% ---------------------------------------------------------------
%   Broadcast relay
% ---------------------------------------------------------------

test(broadcast_topic_reaches_listener) :-
    retractall(heard_(_)),
    listen(heard_token, spse4(E), assertz(heard_(E))),
    spse4_broadcast(task_added(mt_b, xyz, "X", todo, [])),
    sleep(0.05),
    findall(E, heard_(E), All),
    assertion(memberchk(task_added(mt_b, xyz, "X", todo, []), All)),
    unlisten(heard_token).

:- dynamic heard_/1.

% ---------------------------------------------------------------
%   ACL helper edge-cases
% ---------------------------------------------------------------

test(write_implies_read) :-
    with_strict_mode_(
        ( spse4_user_remove(dave),
          spse4_user_add(dave, "x", [write([only])]),
          assertion(spse4_acl_allows(dave, read, only)),
          assertion(spse4_acl_allows(dave, write, only)),
          spse4_user_remove(dave)
        )).

test(empty_acl_denies_all) :-
    with_strict_mode_(
        ( spse4_user_remove(eve),
          spse4_user_add(eve, "x", []),
          \+ spse4_acl_allows(eve, read, anything),
          \+ spse4_acl_allows(eve, write, anything),
          spse4_user_remove(eve)
        )).

:- end_tests(spse4_server).
