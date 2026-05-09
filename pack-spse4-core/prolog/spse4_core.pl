/*  pack-spse4-core -- SPSE4 task ontology and graph operations.

    Part of FRKCSA / SPSE4.  GPLv3 License.

    This module defines the core data model of the Shared Priority
    System Editor v4.  A "priority system" is a labelled directed
    multigraph stored in one or more microtheories: nodes are tasks
    (or other first-class entities), and edges are typed binary
    relations of several distinct kinds -- temporal (Allen), depends,
    provides, attacks, supports, contingent-on, subsumes, and others
    the caller can extend.

    All user-facing text (NL labels, descriptions, notes) is carried
    as strings.  Internal identifiers, predicate names, relation
    kinds, and enumerated values are atoms.  This follows Covington's
    Prolog coding standards and matches the conventions used by the
    wider SWI-Prolog ecosystem.

    Task data is stored in microtheories via =pack-mt-store=.  One
    microtheory per "domain" (medical, financial, household, ...) is
    the usual pattern, with specialization edges tying domains into
    a lattice.  Queries can be projected by microtheory membership,
    by relation kind, by status, or by any composition of those
    filters.
*/

:- module(spse4_core,
          [ % Task CRUD
            task_create/3,              % +Mt, +TaskId, +Properties
            task_retract/2,             % +Mt, +TaskId
            task_exists/2,              % +Mt, +TaskId
            task_list/2,                % +Mt, -TaskIds
            task_property/4,            % +Mt, +TaskId, ?Key, ?Value
            task_set_property/4,        % +Mt, +TaskId, +Key, +Value

            % Edges
            edge_assert/5,              % +Mt, +From, +Kind, +To, +Properties
            edge_retract/4,             % +Mt, +From, +Kind, +To
            edge/4,                     % ?Mt, ?From, ?Kind, ?To
            edge_property/5,            % +Mt, +From, +Kind, +To, ?Pairs
            edges_of_kind/3,            % +Mt, +Kind, -Edges

            % Legacy-SPSE2 vocabulary compatibility layer
            depends/3,                  % ?Mt, ?A, ?B
            provides/3,                 % ?Mt, ?A, ?B
            eases/3,                    % ?Mt, ?A, ?B
            has_nl/3,                   % ?Mt, ?Task, ?String
            completed/2,                % ?Mt, ?Task

            % Graph queries
            task_blockers/3,            % +Mt, +TaskId, -BlockerIds
            task_ready/2,               % +Mt, -ReadyIds
            project_graph/3,            % +Mt, +Filter, -proj(Nodes,Edges)

            % Legacy importer
            import_spse2_holds/2,       % +HoldsList, +TargetMt
            import_spse2_file/2,        % +Path, +TargetMt

            % Validation
            valid_task_kind/1,          % ?Kind
            valid_overlap_class/1,      % ?Class
            valid_edge_kind/1           % ?Kind
          ]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(library(mt_store)).
:- use_module(library(broadcast)).

/** <module> SPSE4 core task ontology

A task is an atom identifier with a bag of properties stored in a
microtheory.  Properties use atom keys:

  * =|has_nl|=          — string, user-visible label
  * =|description|=     — string, longer human text
  * =|task_kind|=       — one of [primitive, compound, recurring, ongoing, milestone]
  * =|overlap_class|=   — one of [exclusive, foregroundable, backgroundable, ambient, batched]
  * =|status|=          — one of [open, in_progress, completed, cancelled, deleted, skipped,
                                  obsoleted, rejected, showstopper, ridiculous, habitual]
  * =|duration|=        — a term: fixed(Seconds) | range(Lo,Hi) | distribution(Kind,Params) | effort(Total)
  * =|earliest_start|=  — datetime term or unbound
  * =|latest_finish|=   — datetime term or unbound
  * =|needs_resource|=  — atom (may appear multiple times)
  * =|costs|=           — term: dollars(N) or similar
  * =|earns|=           — term
  * =|recurrence|=      — string (RRULE) or term
  * =|triggers_when|=   — goal (Prolog term) whose success unblocks task
  * =|created_by|=      — atom (user id)
  * =|source|=          — term describing where this came from
                          (=|spse2(Prefix, ID)|= for imports)

Edges are stored as =|edge_assert(Mt, From, Kind, To, Properties)|=.
The edge kind is an atom; common kinds:

  * =|depends|=         — From needs To done first   (planning)
  * =|provides|=        — From satisfies To's need   (causal)
  * =|eases|=           — From makes To easier       (preferential)
  * =|allen|=           — temporal, with =|relation=before|= (or any Allen name) property
  * =|attacks|=         — argumentative                (Dung)
  * =|supports|=        — argumentative
  * =|contingent_on|=   — branch taken iff sensing result matches property
  * =|subsumes|=        — abstraction edge (for HTN-ish decomposition)
  * =|prefer|=          — preference ordering
*/

% ---------------------------------------------------------------------
% Enumerations
% ---------------------------------------------------------------------

%%  valid_task_kind(?Kind) is nondet.
valid_task_kind(primitive).
valid_task_kind(compound).
valid_task_kind(recurring).
valid_task_kind(ongoing).
valid_task_kind(milestone).

%%  valid_overlap_class(?Class) is nondet.
valid_overlap_class(exclusive).
valid_overlap_class(foregroundable).
valid_overlap_class(backgroundable).
valid_overlap_class(ambient).
valid_overlap_class(batched).

%%  valid_edge_kind(?Kind) is nondet.
%
%   Known edge kinds.  The predicate is extensible by adding clauses
%   from application code; the core provides a reasonable default
%   set matching SPSE2 + argumentation + contingency.

valid_edge_kind(depends).
valid_edge_kind(provides).
valid_edge_kind(eases).
valid_edge_kind(allen).
valid_edge_kind(attacks).
valid_edge_kind(supports).
valid_edge_kind(contingent_on).
valid_edge_kind(subsumes).
valid_edge_kind(prefer).

% ---------------------------------------------------------------------
% Task CRUD
% ---------------------------------------------------------------------

%%  task_create(+Mt, +TaskId, +Properties) is det.
%
%   Create TaskId in microtheory Mt.  Properties is a list of
%   =|Key=Value|= or =|Key-Value|= pairs.  TaskId must be an atom.
%
%   Storage scheme: for each property, assert the fact
%   =|task_property(TaskId, Key, Value)|= into the microtheory.  A
%   marker fact =|task(TaskId)|= is also asserted so that =task_list/2=
%   is fast.
%
%   Multi-valued properties (like =needs_resource=) can be asserted by
%   repeating the key with different values, which the store preserves.

task_create(Mt, TaskId, Props) :-
    must_be(atom, Mt),
    must_be(atom, TaskId),
    must_be(list, Props),
    (   mt_exists(Mt) -> true ; existence_error(microtheory, Mt) ),
    mt_assert(Mt, task(TaskId)),
    forall(member(P, Props), assert_property_(Mt, TaskId, P)),
    broadcast(spse4(task_added(Mt, TaskId, Props))).

assert_property_(Mt, TaskId, Key=Value) :- !,
    validate_property_(Key, Value),
    mt_assert(Mt, task_property(TaskId, Key, Value)).
assert_property_(Mt, TaskId, Key-Value) :- !,
    validate_property_(Key, Value),
    mt_assert(Mt, task_property(TaskId, Key, Value)).
assert_property_(_, _, P) :-
    domain_error(property_pair, P).

% Lightweight validation at assertion time.  String-typed keys get a
% string check so that we catch atom-vs-string slips early.
validate_property_(has_nl, V)        :- !, must_be(string, V).
validate_property_(description, V)   :- !, must_be(string, V).
validate_property_(task_kind, V)     :- !, must_be(oneof([primitive, compound, recurring, ongoing, milestone]), V).
validate_property_(overlap_class, V) :- !, must_be(oneof([exclusive, foregroundable, backgroundable, ambient, batched]), V).
validate_property_(status, V)        :- !, must_be(oneof([open, in_progress, completed, cancelled, deleted, skipped, obsoleted, rejected, showstopper, ridiculous, habitual]), V).
validate_property_(_, _).  % any other key is permitted without schema

%%  task_retract(+Mt, +TaskId) is det.
%
%   Remove TaskId and all its properties from Mt.  Also removes all
%   edges incident to TaskId.

task_retract(Mt, TaskId) :-
    must_be(atom, Mt),
    must_be(atom, TaskId),
    % Capture incident edges first so we can broadcast their removal.
    findall(edge(TaskId, K, To),  ist(Mt, edge(TaskId, K, To)),  OutEdges),
    findall(edge(From, K, TaskId), ist(Mt, edge(From, K, TaskId)), InEdges),
    mt_retract(Mt, task(TaskId)),
    forall(ist(Mt, task_property(TaskId, K, V)),
           mt_retract(Mt, task_property(TaskId, K, V))),
    forall(member(edge(TaskId, K, To), OutEdges),
           edge_retract(Mt, TaskId, K, To)),
    forall(member(edge(From, K, TaskId), InEdges),
           edge_retract(Mt, From, K, TaskId)),
    broadcast(spse4(task_removed(Mt, TaskId))).

%%  task_exists(+Mt, +TaskId) is semidet.
task_exists(Mt, TaskId) :-
    ist(Mt, task(TaskId)).

%%  task_list(+Mt, -TaskIds) is det.
task_list(Mt, TaskIds) :-
    findall(T, ist(Mt, task(T)), TaskIds).

%%  task_property(+Mt, +TaskId, ?Key, ?Value) is nondet.
task_property(Mt, TaskId, Key, Value) :-
    ist(Mt, task_property(TaskId, Key, Value)).

%%  task_set_property(+Mt, +TaskId, +Key, +Value) is det.
%
%   Replace the value(s) for Key on TaskId.  This retracts any prior
%   values for that key first.

task_set_property(Mt, TaskId, Key, Value) :-
    must_be(atom, Key),
    validate_property_(Key, Value),
    forall(ist(Mt, task_property(TaskId, Key, V0)),
           mt_retract(Mt, task_property(TaskId, Key, V0))),
    mt_assert(Mt, task_property(TaskId, Key, Value)),
    broadcast(spse4(task_property_changed(Mt, TaskId, Key, Value))).

% ---------------------------------------------------------------------
% Edges
% ---------------------------------------------------------------------

%%  edge_assert(+Mt, +From, +Kind, +To, +Properties) is det.
%
%   Assert a typed edge in microtheory Mt.  Kind must be a known
%   edge kind (see =valid_edge_kind/1=).  Properties is a list of
%   Key=Value pairs attached to the edge.
%
%   The edge is idempotent on (From, Kind, To).  Properties are _added_
%   if the edge exists; they do not overwrite.

edge_assert(Mt, From, Kind, To, Props) :-
    must_be(atom, Mt),
    must_be(atom, From),
    must_be(atom, Kind),
    must_be(atom, To),
    must_be(list, Props),
    (   valid_edge_kind(Kind) -> true
    ;   domain_error(edge_kind, Kind)
    ),
    (   ist(Mt, edge(From, Kind, To))
    ->  IsNew = false
    ;   mt_assert(Mt, edge(From, Kind, To)),
        IsNew = true
    ),
    forall(member(K=V, Props), mt_assert(Mt, edge_property(From, Kind, To, K, V))),
    (   IsNew == true
    ->  broadcast(spse4(edge_added(Mt, From, Kind, To, Props)))
    ;   true
    ).

%%  edge_retract(+Mt, +From, +Kind, +To) is det.
edge_retract(Mt, From, Kind, To) :-
    (   ist(Mt, edge(From, Kind, To))
    ->  mt_retract(Mt, edge(From, Kind, To)),
        forall(ist(Mt, edge_property(From, Kind, To, K, V)),
               mt_retract(Mt, edge_property(From, Kind, To, K, V))),
        broadcast(spse4(edge_removed(Mt, From, Kind, To)))
    ;   true
    ).

%%  edge(?Mt, ?From, ?Kind, ?To) is nondet.
edge(Mt, From, Kind, To) :-
    mt_exists(Mt),
    ist(Mt, edge(From, Kind, To)).

%%  edge_property(+Mt, +From, +Kind, +To, ?Pairs) is det.
%
%   Retrieve all Key=Value properties attached to the edge as a list.
edge_property(Mt, From, Kind, To, Pairs) :-
    findall(K=V, ist(Mt, edge_property(From, Kind, To, K, V)), Pairs).

%%  edges_of_kind(+Mt, +Kind, -Edges) is det.
%
%   Edges is a list of =|From-To|= pairs for all edges of the given
%   Kind in Mt.
edges_of_kind(Mt, Kind, Edges) :-
    findall(From-To, edge(Mt, From, Kind, To), Edges).

% ---------------------------------------------------------------------
% Legacy SPSE2 vocabulary (convenience facades)
% ---------------------------------------------------------------------

depends(Mt, A, B) :- edge(Mt, A, depends, B).
provides(Mt, A, B) :- edge(Mt, A, provides, B).
eases(Mt, A, B) :- edge(Mt, A, eases, B).

%%  has_nl(?Mt, ?TaskId, ?String) is nondet.
has_nl(Mt, TaskId, String) :-
    task_property(Mt, TaskId, has_nl, String).

%%  completed(?Mt, ?TaskId) is nondet.
completed(Mt, TaskId) :-
    task_property(Mt, TaskId, status, completed).

% ---------------------------------------------------------------------
% Graph queries
% ---------------------------------------------------------------------

%%  task_blockers(+Mt, +TaskId, -BlockerIds) is det.
%
%   Blockers = every task TaskId depends on that is not yet
%   =completed=.  Returns a deduplicated list.

task_blockers(Mt, TaskId, Blockers) :-
    findall(Dep,
            ( depends(Mt, TaskId, Dep),
              \+ completed(Mt, Dep) ),
            Raw),
    list_to_set(Raw, Blockers).

%%  task_ready(+Mt, -ReadyIds) is det.
%
%   A task is ready if it is =open= and has no un-completed blockers
%   and its =triggers_when= (if any) succeeds.

task_ready(Mt, ReadyIds) :-
    findall(T,
            ( ist(Mt, task(T)),
              \+ task_property(Mt, T, status, completed),
              \+ task_property(Mt, T, status, cancelled),
              \+ task_property(Mt, T, status, deleted),
              task_blockers(Mt, T, []),
              trigger_satisfied_(Mt, T) ),
            Raw),
    list_to_set(Raw, ReadyIds).

trigger_satisfied_(Mt, TaskId) :-
    (   task_property(Mt, TaskId, triggers_when, Goal)
    ->  catch(call(Goal), _, fail)
    ;   true
    ).

% ---------------------------------------------------------------------
% Projection
% ---------------------------------------------------------------------

%%  project_graph(+Mt, +Filter, -proj(Nodes,Edges)) is det.
%
%   Filter a microtheory's graph to produce a pair of node and edge
%   lists suitable for shipping to a visualiser.
%
%   Filter is a term:
%     * =|all|=                        — no filter
%     * =|kind(K)|=                    — only edges of kind K
%     * =|status(S)|=                  — only tasks with status S
%     * =|kinds([K1,K2,...])|=         — any of those kinds
%     * =|and(F1, F2)|=                — conjunction
%     * =|or(F1, F2)|=                 — disjunction
%     * =|not(F)|=                     — negation

project_graph(Mt, Filter, proj(Nodes, Edges)) :-
    findall(node(Id, Props),
            ( ist(Mt, task(Id)),
              task_matches_(Mt, Id, Filter),
              findall(K=V, task_property(Mt, Id, K, V), Props) ),
            Nodes),
    findall(edge(From, Kind, To, Props),
            ( edge(Mt, From, Kind, To),
              edge_matches_(Kind, Filter),
              findall(K=V, ist(Mt, edge_property(From, Kind, To, K, V)), Props) ),
            Edges).

task_matches_(_Mt, _Id, all).
task_matches_(Mt,  Id,  status(S)) :-
    task_property(Mt, Id, status, S).
task_matches_(_,   _,   kind(_)).
task_matches_(_,   _,   kinds(_)).
task_matches_(Mt,  Id,  and(F1, F2)) :-
    task_matches_(Mt, Id, F1),
    task_matches_(Mt, Id, F2).
task_matches_(Mt,  Id,  or(F1, F2)) :-
    (   task_matches_(Mt, Id, F1)
    ;   task_matches_(Mt, Id, F2)
    ).
task_matches_(Mt,  Id,  not(F)) :-
    \+ task_matches_(Mt, Id, F).

edge_matches_(_Kind, all).
edge_matches_(Kind,  kind(Kind)).
edge_matches_(Kind,  kinds(Ks))     :- memberchk(Kind, Ks).
edge_matches_(_,     status(_)).
edge_matches_(Kind,  and(F1, F2))   :-
    edge_matches_(Kind, F1), edge_matches_(Kind, F2).
edge_matches_(Kind,  or(F1, F2))    :-
    (   edge_matches_(Kind, F1)
    ;   edge_matches_(Kind, F2)
    ).
edge_matches_(Kind,  not(F))        :-
    \+ edge_matches_(Kind, F).

% ---------------------------------------------------------------------
% Legacy SPSE2 importer
% ---------------------------------------------------------------------

%%  import_spse2_holds(+HoldsList, +TargetMt) is det.
%
%   Import a list of SPSE2 =|holds(Context, Fact)|= facts into
%   TargetMt.  SPSE2 uses hyphenated atom predicates like
%   =|'has-NL'/2|=; these are translated to the SPSE4 vocabulary
%   (underscore-separated atoms, strings for NL).  An identifier of the
%   form =|'entry-fn'(Prefix, Id)|= becomes the atom
%   =|'spse2_<Prefix>_<Id>'|= to avoid collisions across contexts.
%
%   The =Context= component of each =|holds/2|= fact is recorded as a
%   property =|source=spse2(Context)|= on the resulting task.

import_spse2_holds(HoldsList, TargetMt) :-
    must_be(list, HoldsList),
    must_be(atom, TargetMt),
    (   mt_exists(TargetMt) -> true ; mt_create(TargetMt) ),
    forall(member(holds(Ctx, Fact), HoldsList),
           import_fact_(Ctx, Fact, TargetMt)).

import_fact_(Ctx, goal(EntryFn), Mt) :-
    legacy_id_(EntryFn, TaskId),
    (   task_exists(Mt, TaskId) -> true
    ;   task_create(Mt, TaskId, [source=spse2(Ctx), task_kind=primitive, status=open])
    ).
import_fact_(_Ctx, 'has-NL'(EntryFn, NL), Mt) :-
    legacy_id_(EntryFn, TaskId),
    ensure_task_(Mt, TaskId),
    (   atom(NL) -> atom_string(NL, NLString)
    ;   string(NL) -> NLString = NL
    ;   NLString = ""
    ),
    task_set_property(Mt, TaskId, has_nl, NLString).
import_fact_(_Ctx, depends(A, B), Mt) :-
    legacy_id_(A, AId), legacy_id_(B, BId),
    ensure_task_(Mt, AId), ensure_task_(Mt, BId),
    edge_assert(Mt, AId, depends, BId, []).
import_fact_(_Ctx, provides(A, B), Mt) :-
    legacy_id_(A, AId), legacy_id_(B, BId),
    ensure_task_(Mt, AId), ensure_task_(Mt, BId),
    edge_assert(Mt, AId, provides, BId, []).
import_fact_(_Ctx, eases(A, B), Mt) :-
    legacy_id_(A, AId), legacy_id_(B, BId),
    ensure_task_(Mt, AId), ensure_task_(Mt, BId),
    edge_assert(Mt, AId, eases, BId, []).
import_fact_(_Ctx, complete(EntryFn), Mt) :-
    legacy_id_(EntryFn, TaskId),
    ensure_task_(Mt, TaskId),
    task_set_property(Mt, TaskId, status, completed).
import_fact_(_Ctx, completed(EntryFn), Mt) :-
    legacy_id_(EntryFn, TaskId),
    ensure_task_(Mt, TaskId),
    task_set_property(Mt, TaskId, status, completed).
import_fact_(_Ctx, cancelled(EntryFn), Mt) :-
    legacy_id_(EntryFn, TaskId),
    ensure_task_(Mt, TaskId),
    task_set_property(Mt, TaskId, status, cancelled).
import_fact_(_Ctx, deleted(EntryFn), Mt) :-
    legacy_id_(EntryFn, TaskId),
    ensure_task_(Mt, TaskId),
    task_set_property(Mt, TaskId, status, deleted).
import_fact_(_Ctx, showstopper(EntryFn), Mt) :-
    legacy_id_(EntryFn, TaskId),
    ensure_task_(Mt, TaskId),
    task_set_property(Mt, TaskId, status, showstopper).
import_fact_(_Ctx, habitual(EntryFn), Mt) :-
    legacy_id_(EntryFn, TaskId),
    ensure_task_(Mt, TaskId),
    task_set_property(Mt, TaskId, task_kind, recurring).
import_fact_(_Ctx, costs(EntryFn, V), Mt) :-
    legacy_id_(EntryFn, TaskId),
    ensure_task_(Mt, TaskId),
    task_set_property(Mt, TaskId, costs, V).
import_fact_(_Ctx, earns(EntryFn, V), Mt) :-
    legacy_id_(EntryFn, TaskId),
    ensure_task_(Mt, TaskId),
    task_set_property(Mt, TaskId, earns, V).
import_fact_(_, _, _).   % silently ignore facts we don't yet translate

ensure_task_(Mt, TaskId) :-
    (   task_exists(Mt, TaskId) -> true
    ;   task_create(Mt, TaskId, [task_kind=primitive, status=open])
    ).

%%  legacy_id_(+EntryFn, -TaskId) is det.
%
%   Translate =|'entry-fn'(Prefix, Id)|= or bare atom into a canonical
%   SPSE4 task atom.

legacy_id_('entry-fn'(Prefix, Id), TaskId) :- !,
    term_to_atom(id(Prefix, Id), TaskId0),
    % Sanitise: atom is ok as-is; nothing to do.
    TaskId = TaskId0.
legacy_id_(Atom, Atom) :- atom(Atom), !.
legacy_id_(Other, Atom) :-
    term_to_atom(Other, Atom).

%%  import_spse2_file(+Path, +TargetMt) is det.
%
%   Load a Prolog file of =|holds(Context, Fact).|= terms and import
%   them into TargetMt.  Convenience wrapper.

import_spse2_file(Path, TargetMt) :-
    must_be(atom, TargetMt),
    setup_call_cleanup(
        open(Path, read, Stream),
        read_all_holds_(Stream, HoldsList),
        close(Stream)),
    import_spse2_holds(HoldsList, TargetMt).

read_all_holds_(Stream, List) :-
    read_term(Stream, T, []),
    (   T == end_of_file
    ->  List = []
    ;   T = holds(_, _)
    ->  List = [T|Rest],
        read_all_holds_(Stream, Rest)
    ;   % skip non-holds terms
        read_all_holds_(Stream, List)
    ).
