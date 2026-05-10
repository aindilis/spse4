/*  t/spse4_server.plt  --  PlUnit tests for pack-spse4-server.

    Tests are self-contained: each test block starts a server on a
    random high port, exercises it with library(http/http_open), and
    stops it.  The tests do NOT require the Pengines JS client --
    they validate the server's HTTP surface and ACL logic directly.

    GPLv3 License.  Part of FRKCSA / SPSE4.
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
          assertion(Dict.version == "0.2.3")
        ),
        teardown_server_(Port)).

% ---------------------------------------------------------------
%   User DB
% ---------------------------------------------------------------

test(user_add_and_acl) :-
    with_strict_mode_(
        ( spse4_user_remove(demo),
          spse4_user_add(demo, "demo",
                         [read([public, priv_a]), write([priv_a])]),
          spse4_user_acl(demo, ACL),
          assertion(memberchk(read([public, priv_a]), ACL)),
          assertion(spse4_acl_allows(demo, read, public)),
          assertion(spse4_acl_allows(demo, read, priv_a)),
          assertion(spse4_acl_allows(demo, write, priv_a)),
          \+ spse4_acl_allows(demo, write, public),
          \+ spse4_acl_allows(demo, read, secret)
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
    spse4_broadcast(task_added(mt_b, xyz, [has_nl="X", status=open])),
    sleep(0.05),
    findall(E, heard_(E), All),
    assertion(memberchk(task_added(mt_b, xyz, [has_nl="X", status=open]), All)),
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

% ---------------------------------------------------------------
%   /tasks REST mutation endpoints (added v0.2.0)
% ---------------------------------------------------------------

%   post_json_(+URL, +Dict, -ReplyDict, -Code, +AuthOpts) is det.
%
%   Helper that posts a JSON body without relying on http_post/4's
%   json(_) shorthand (which depends on library(http/http_json) writer
%   hooks being visible inside the plunit submodule).  Works in any
%   module by encoding the JSON to a string and sending via http_open/3.

post_json_(URL, Dict, ReplyDict, Code, AuthOpts) :-
    with_output_to(string(BodyStr), json_write_dict(current_output, Dict)),
    catch( http_open(URL, S,
                     [ method(post),
                       post(string('application/json', BodyStr)),
                       status_code(Code)
                     | AuthOpts ]),
           Err,
           ( ReplyDict = error(Err), Code = 0, S = (-) ) ),
    ( S == (-)
    -> true
    ;   ( catch( ( json_read_dict(S, ReplyDict) ),
                 _, ReplyDict = _{} ),
          close(S) )
    ).

%   delete_(+URL, -ReplyDict, -Code, +AuthOpts) is det.
delete_(URL, ReplyDict, Code, AuthOpts) :-
    catch( http_open(URL, S,
                     [ method(delete),
                       status_code(Code)
                     | AuthOpts ]),
           Err,
           ( ReplyDict = error(Err), Code = 0, S = (-) ) ),
    ( S == (-)
    -> true
    ;   ( catch( ( json_read_dict(S, ReplyDict) ),
                 _, ReplyDict = _{} ),
          close(S) )
    ).

%   patch_json_(+URL, +Dict, -ReplyDict, -Code, +AuthOpts) is det.
patch_json_(URL, Dict, ReplyDict, Code, AuthOpts) :-
    with_output_to(string(BodyStr), json_write_dict(current_output, Dict)),
    catch( http_open(URL, S,
                     [ method(patch),
                       post(string('application/json', BodyStr)),
                       status_code(Code)
                     | AuthOpts ]),
           Err,
           ( ReplyDict = error(Err), Code = 0, S = (-) ) ),
    ( S == (-)
    -> true
    ;   ( catch( ( json_read_dict(S, ReplyDict) ),
                 _, ReplyDict = _{} ),
          close(S) )
    ).

test(post_tasks_creates_in_permissive_anon_denied) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(rest_mt_anon),
          format(string(URL), "http://localhost:~w/tasks", [Port]),
          post_json_(URL,
                     _{mt: rest_mt_anon, id: t_anon,
                       label: "Anon", status: open},
                     _Reply, Code, []),
          assertion(Code == 401)
        ),
        teardown_server_(Port)).

test(post_tasks_creates_with_auth_then_visible) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(rest_mt_post),
          spse4_user_remove(carol),
          spse4_user_add(carol, "passw", [write([rest_mt_post])]),
          format(string(URL), "http://localhost:~w/tasks", [Port]),
          post_json_(URL,
                     _{mt: rest_mt_post, id: new_task_1,
                       label: "New One", status: open},
                     Reply, Code,
                     [ authorization(basic(carol, "passw")) ]),
          assertion(Code == 201),
          assertion(Reply.ok == true),
          % Confirm it's actually in the store and visible via projection:
          assertion(spse4_core:task_exists(rest_mt_post, new_task_1)),
          format(string(PURL),
                 "http://localhost:~w/projection?mt=rest_mt_post",
                 [Port]),
          http_open(PURL, S, []),
          json_read_dict(S, PD),
          close(S),
          findall(NId,
                  ( member(N, PD.elements.nodes),
                    atom_string(NIdAtom, N.data.id),
                    NId = NIdAtom ),
                  NodeIds),
          assertion(memberchk(new_task_1, NodeIds)),
          spse4_user_remove(carol)
        ),
        teardown_server_(Port)).

test(post_tasks_acl_denies_wrong_mt) :-
    setup_call_cleanup(
        setup_server_(Port),
        with_strict_mode_(
          ( seed_graph_(rest_mt_acl),
            spse4_user_remove(dan),
            spse4_user_add(dan, "ppp", [write([other_mt])]),
            format(string(URL), "http://localhost:~w/tasks", [Port]),
            post_json_(URL,
                       _{mt: rest_mt_acl, id: bad_task,
                         label: "Nope", status: open},
                       _Reply, Code,
                       [ authorization(basic(dan, "ppp")) ]),
            assertion(Code == 403),
            \+ spse4_core:task_exists(rest_mt_acl, bad_task),
            spse4_user_remove(dan)
          )),
        teardown_server_(Port)).

test(delete_tasks_removes_with_auth) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(rest_mt_del),
          spse4_user_remove(eric),
          spse4_user_add(eric, "ppp", [write([rest_mt_del])]),
          format(string(URL),
                 "http://localhost:~w/tasks/rest_mt_del/t1", [Port]),
          delete_(URL, _Reply, Code,
                  [ authorization(basic(eric, "ppp")) ]),
          assertion(Code == 200),
          \+ spse4_core:task_exists(rest_mt_del, t1),
          spse4_user_remove(eric)
        ),
        teardown_server_(Port)).

test(delete_tasks_404_on_missing) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(rest_mt_404),
          spse4_user_remove(fran),
          spse4_user_add(fran, "ppp", [write([rest_mt_404])]),
          format(string(URL),
                 "http://localhost:~w/tasks/rest_mt_404/no_such", [Port]),
          delete_(URL, _Reply, Code,
                  [ authorization(basic(fran, "ppp")) ]),
          assertion(Code == 404),
          spse4_user_remove(fran)
        ),
        teardown_server_(Port)).

test(post_then_delete_round_trip_fires_broadcast) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(rest_mt_rt),
          spse4_user_remove(gail),
          spse4_user_add(gail, "ppp", [write([rest_mt_rt])]),
          retractall(heard_(_)),
          listen(rt_token, spse4(E), assertz(heard_(E))),
          % POST
          format(string(URL), "http://localhost:~w/tasks", [Port]),
          post_json_(URL,
                     _{mt: rest_mt_rt, id: rt1,
                       label: "round trip", status: open},
                     _R, _Code1,
                     [ authorization(basic(gail, "ppp")) ]),
          sleep(0.05),
          findall(E, heard_(E), Heard1),
          assertion(memberchk(task_added(rest_mt_rt, rt1, _), Heard1)),
          % DELETE
          format(string(DURL),
                 "http://localhost:~w/tasks/rest_mt_rt/rt1", [Port]),
          delete_(DURL, _R2, _Code2,
                  [ authorization(basic(gail, "ppp")) ]),
          sleep(0.05),
          findall(E, heard_(E), Heard2),
          assertion(memberchk(task_removed(rest_mt_rt, rt1), Heard2)),
          unlisten(rt_token),
          spse4_user_remove(gail)
        ),
        teardown_server_(Port)).

% ---------------------------------------------------------------
%   PATCH /tasks/<mt>/<id> — status edit (added v0.2.1)
% ---------------------------------------------------------------

test(patch_status_anon_denied) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(patch_mt_anon),
          format(string(URL),
                 "http://localhost:~w/tasks/patch_mt_anon/t1", [Port]),
          patch_json_(URL,
                      _{status: completed},
                      _Reply, Code, []),
          assertion(Code == 401)
        ),
        teardown_server_(Port)).

test(patch_status_changes_with_auth) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(patch_mt_a),
          spse4_user_remove(hank),
          spse4_user_add(hank, "ppp", [write([patch_mt_a])]),
          % t1 starts as 'open' from seed_graph_
          assertion(spse4_core:task_property(patch_mt_a, t1, status, open)),
          format(string(URL),
                 "http://localhost:~w/tasks/patch_mt_a/t1", [Port]),
          patch_json_(URL,
                      _{status: completed},
                      Reply, Code,
                      [ authorization(basic(hank, "ppp")) ]),
          assertion(Code == 200),
          assertion(Reply.ok == true),
          assertion(Reply.status == "completed"),
          assertion(spse4_core:task_property(patch_mt_a, t1, status, completed)),
          spse4_user_remove(hank)
        ),
        teardown_server_(Port)).

test(patch_status_acl_denies_wrong_mt) :-
    setup_call_cleanup(
        setup_server_(Port),
        with_strict_mode_(
          ( seed_graph_(patch_mt_acl),
            spse4_user_remove(ivy),
            spse4_user_add(ivy, "ppp", [write([other_mt])]),
            format(string(URL),
                   "http://localhost:~w/tasks/patch_mt_acl/t1", [Port]),
            patch_json_(URL,
                        _{status: completed},
                        _Reply, Code,
                        [ authorization(basic(ivy, "ppp")) ]),
            assertion(Code == 403),
            % Status must be unchanged
            assertion(spse4_core:task_property(patch_mt_acl, t1, status, open)),
            spse4_user_remove(ivy)
          )),
        teardown_server_(Port)).

test(patch_status_404_on_missing) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(patch_mt_404),
          spse4_user_remove(jay),
          spse4_user_add(jay, "ppp", [write([patch_mt_404])]),
          format(string(URL),
                 "http://localhost:~w/tasks/patch_mt_404/no_such", [Port]),
          patch_json_(URL,
                      _{status: completed},
                      _Reply, Code,
                      [ authorization(basic(jay, "ppp")) ]),
          assertion(Code == 404),
          spse4_user_remove(jay)
        ),
        teardown_server_(Port)).

test(patch_status_400_on_invalid_status) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(patch_mt_bad),
          spse4_user_remove(kate),
          spse4_user_add(kate, "ppp", [write([patch_mt_bad])]),
          format(string(URL),
                 "http://localhost:~w/tasks/patch_mt_bad/t1", [Port]),
          patch_json_(URL,
                      _{status: not_a_real_status},
                      _Reply, Code,
                      [ authorization(basic(kate, "ppp")) ]),
          assertion(Code == 400),
          % Status must be unchanged
          assertion(spse4_core:task_property(patch_mt_bad, t1, status, open)),
          spse4_user_remove(kate)
        ),
        teardown_server_(Port)).

test(patch_status_400_on_missing_status_field) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(patch_mt_nofield),
          spse4_user_remove(liz),
          spse4_user_add(liz, "ppp", [write([patch_mt_nofield])]),
          format(string(URL),
                 "http://localhost:~w/tasks/patch_mt_nofield/t1", [Port]),
          patch_json_(URL,
                      _{wrong_field: completed},
                      _Reply, Code,
                      [ authorization(basic(liz, "ppp")) ]),
          assertion(Code == 400),
          spse4_user_remove(liz)
        ),
        teardown_server_(Port)).

test(patch_status_fires_broadcast) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(patch_mt_bc),
          spse4_user_remove(mark),
          spse4_user_add(mark, "ppp", [write([patch_mt_bc])]),
          retractall(heard_(_)),
          listen(patch_token, spse4(E), assertz(heard_(E))),
          format(string(URL),
                 "http://localhost:~w/tasks/patch_mt_bc/t1", [Port]),
          patch_json_(URL,
                      _{status: in_progress},
                      _Reply, _Code,
                      [ authorization(basic(mark, "ppp")) ]),
          sleep(0.05),
          findall(E, heard_(E), Heard),
          assertion(memberchk(task_property_changed(patch_mt_bc, t1, status, in_progress), Heard)),
          unlisten(patch_token),
          spse4_user_remove(mark)
        ),
        teardown_server_(Port)).

% ---------------------------------------------------------------
%   /edges REST mutation endpoints (added v0.2.2)
% ---------------------------------------------------------------

test(post_edges_anon_denied) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_anon),
          format(string(URL), "http://localhost:~w/edges", [Port]),
          post_json_(URL,
                     _{mt: edge_mt_anon, from: t1, kind: provides, to: t2},
                     _Reply, Code, []),
          assertion(Code == 401),
          \+ spse4_core:edge(edge_mt_anon, t1, provides, t2)
        ),
        teardown_server_(Port)).

test(post_edges_creates_with_auth) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_post),
          spse4_user_remove(nora),
          spse4_user_add(nora, "ppp", [write([edge_mt_post])]),
          format(string(URL), "http://localhost:~w/edges", [Port]),
          post_json_(URL,
                     _{mt: edge_mt_post, from: t1, kind: provides, to: t3,
                       props: _{weight: 5}},
                     Reply, Code,
                     [ authorization(basic(nora, "ppp")) ]),
          assertion(Code == 201),
          assertion(Reply.ok == true),
          assertion(spse4_core:edge(edge_mt_post, t1, provides, t3)),
          spse4_core:edge_property(edge_mt_post, t1, provides, t3, Pairs),
          assertion(memberchk(weight=5, Pairs)),
          spse4_user_remove(nora)
        ),
        teardown_server_(Port)).

test(post_edges_409_on_duplicate) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_dup),
          spse4_user_remove(opal),
          spse4_user_add(opal, "ppp", [write([edge_mt_dup])]),
          % seed_graph_ already creates t2-depends-t1.
          format(string(URL), "http://localhost:~w/edges", [Port]),
          post_json_(URL,
                     _{mt: edge_mt_dup, from: t2, kind: depends, to: t1},
                     _Reply, Code,
                     [ authorization(basic(opal, "ppp")) ]),
          assertion(Code == 409),
          spse4_user_remove(opal)
        ),
        teardown_server_(Port)).

test(post_edges_404_on_missing_endpoint) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_nofrom),
          spse4_user_remove(pia),
          spse4_user_add(pia, "ppp", [write([edge_mt_nofrom])]),
          format(string(URL), "http://localhost:~w/edges", [Port]),
          post_json_(URL,
                     _{mt: edge_mt_nofrom, from: nope, kind: depends, to: t1},
                     _Reply, Code,
                     [ authorization(basic(pia, "ppp")) ]),
          assertion(Code == 404),
          spse4_user_remove(pia)
        ),
        teardown_server_(Port)).

test(post_edges_400_on_unknown_kind) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_badkind),
          spse4_user_remove(quin),
          spse4_user_add(quin, "ppp", [write([edge_mt_badkind])]),
          format(string(URL), "http://localhost:~w/edges", [Port]),
          post_json_(URL,
                     _{mt: edge_mt_badkind, from: t1, kind: not_a_kind, to: t2},
                     _Reply, Code,
                     [ authorization(basic(quin, "ppp")) ]),
          assertion(Code == 400),
          spse4_user_remove(quin)
        ),
        teardown_server_(Port)).

test(post_edges_acl_denies_wrong_mt) :-
    setup_call_cleanup(
        setup_server_(Port),
        with_strict_mode_(
          ( seed_graph_(edge_mt_acl),
            spse4_user_remove(rae),
            spse4_user_add(rae, "ppp", [write([other_mt])]),
            format(string(URL), "http://localhost:~w/edges", [Port]),
            post_json_(URL,
                       _{mt: edge_mt_acl, from: t1, kind: provides, to: t2},
                       _Reply, Code,
                       [ authorization(basic(rae, "ppp")) ]),
            assertion(Code == 403),
            \+ spse4_core:edge(edge_mt_acl, t1, provides, t2),
            spse4_user_remove(rae)
          )),
        teardown_server_(Port)).

test(delete_edges_removes_with_auth) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_del),
          spse4_user_remove(sami),
          spse4_user_add(sami, "ppp", [write([edge_mt_del])]),
          % seed_graph_ creates t2-depends-t1; delete it.
          format(string(URL),
                 "http://localhost:~w/edges/edge_mt_del/t2/depends/t1", [Port]),
          delete_(URL, _Reply, Code,
                  [ authorization(basic(sami, "ppp")) ]),
          assertion(Code == 200),
          \+ spse4_core:edge(edge_mt_del, t2, depends, t1),
          spse4_user_remove(sami)
        ),
        teardown_server_(Port)).

test(delete_edges_404_on_missing) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_del404),
          spse4_user_remove(tara),
          spse4_user_add(tara, "ppp", [write([edge_mt_del404])]),
          format(string(URL),
                 "http://localhost:~w/edges/edge_mt_del404/t1/provides/t2",
                 [Port]),
          delete_(URL, _Reply, Code,
                  [ authorization(basic(tara, "ppp")) ]),
          assertion(Code == 404),
          spse4_user_remove(tara)
        ),
        teardown_server_(Port)).

test(patch_edges_replaces_props) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_patch),
          spse4_user_remove(uma),
          spse4_user_add(uma, "ppp", [write([edge_mt_patch])]),
          % Add an extra prop to the seeded t2-depends-t1 edge to start.
          spse4_core:edge_set_properties(edge_mt_patch, t2, depends, t1,
                                         [weight=1, note="initial"]),
          format(string(URL),
                 "http://localhost:~w/edges/edge_mt_patch/t2/depends/t1",
                 [Port]),
          % JSON string values round-trip as Prolog strings, not atoms,
          % so the asserted prop is urgency="high" (not urgency=high).
          patch_json_(URL,
                      _{props: _{weight: 9, urgency: "high"}},
                      Reply, Code,
                      [ authorization(basic(uma, "ppp")) ]),
          assertion(Code == 200),
          assertion(Reply.ok == true),
          spse4_core:edge_property(edge_mt_patch, t2, depends, t1, Pairs),
          msort(Pairs, Sorted),
          msort([urgency="high", weight=9], Sorted),
          spse4_user_remove(uma)
        ),
        teardown_server_(Port)).

test(patch_edges_404_on_missing) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_patch404),
          spse4_user_remove(vic),
          spse4_user_add(vic, "ppp", [write([edge_mt_patch404])]),
          format(string(URL),
                 "http://localhost:~w/edges/edge_mt_patch404/t1/provides/t2",
                 [Port]),
          patch_json_(URL,
                      _{props: _{weight: 1}},
                      _Reply, Code,
                      [ authorization(basic(vic, "ppp")) ]),
          assertion(Code == 404),
          spse4_user_remove(vic)
        ),
        teardown_server_(Port)).

test(post_edges_fires_broadcast) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_bc),
          spse4_user_remove(wade),
          spse4_user_add(wade, "ppp", [write([edge_mt_bc])]),
          retractall(heard_(_)),
          listen(edge_bc_token, spse4(E), assertz(heard_(E))),
          format(string(URL), "http://localhost:~w/edges", [Port]),
          post_json_(URL,
                     _{mt: edge_mt_bc, from: t1, kind: provides, to: t3},
                     _R, _Code,
                     [ authorization(basic(wade, "ppp")) ]),
          sleep(0.05),
          findall(E, heard_(E), Heard),
          assertion(memberchk(edge_added(edge_mt_bc, t1, provides, t3, _), Heard)),
          unlisten(edge_bc_token),
          spse4_user_remove(wade)
        ),
        teardown_server_(Port)).

test(patch_edges_fires_property_changed_broadcast) :-
    setup_call_cleanup(
        setup_server_(Port),
        ( seed_graph_(edge_mt_pcbc),
          spse4_user_remove(xan),
          spse4_user_add(xan, "ppp", [write([edge_mt_pcbc])]),
          retractall(heard_(_)),
          listen(edge_pc_token, spse4(E), assertz(heard_(E))),
          format(string(URL),
                 "http://localhost:~w/edges/edge_mt_pcbc/t2/depends/t1",
                 [Port]),
          patch_json_(URL,
                      _{props: _{weight: 7}},
                      _R, _Code,
                      [ authorization(basic(xan, "ppp")) ]),
          sleep(0.05),
          findall(E, heard_(E), Heard),
          assertion(memberchk(edge_property_changed(edge_mt_pcbc, t2, depends, t1, [weight=7]),
                              Heard)),
          unlisten(edge_pc_token),
          spse4_user_remove(xan)
        ),
        teardown_server_(Port)).

:- end_tests(spse4_server).
