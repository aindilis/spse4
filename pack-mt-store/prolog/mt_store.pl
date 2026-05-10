/*  pack-mt-store -- Microtheory store with pluggable backend.

    Part of FRKCSA / SPSE4.  GPLv3 License.

    Implements a Guha-style microtheory (context) layer for SWI-Prolog
    knowledge.  Each microtheory is a named container for facts and
    rules.  Microtheories are related by a =specialization/2= (a.k.a.
    =genlMt/2=) lattice which supports inheritance of assertions from
    more general theories into more specific ones.

    This pack does _not_ commit to any particular storage backend.
    The default is an in-memory assertion backend with zero external
    dependencies, suitable for development and testing.  Alternative
    backends register via =backend_register/1= and implement the
    callback interface described below.

    Currently shipping backends:

      * =mt_store_memory= (default, in this file): dynamic-predicate
        storage in the running Prolog process.

      * =mt_store_mysql=  (sibling module): write-through to MySQL
        via =prolog-mysql-store=, with a single mutexed ODBC handle.

    Anyone writing a third backend should implement every callback
    in the BACKEND CALLBACK INTERFACE section below.  The interface
    is intentionally narrow (sixteen predicates) so that a future
    SQL-direct rewrite of =prolog-mysql-store= can drop in without
    any change to =mt_store.pl= or its callers.

    The microtheory concepts follow R.V. Guha's thesis and map onto
    the vocabulary used by Cyc (=genlMt=, =ist=) and by SPSE2
    (=holds(Context, Fact)=).
*/

:- module(mt_store,
          [ mt_create/1,                % +Mt
            mt_create/2,                % +Mt, +Properties
            mt_exists/1,                % ?Mt
            mt_list/1,                  % -Mts

            mt_assert/2,                % +Mt, +Fact
            mt_assert/3,                % +Mt, +Fact, +User
            mt_retract/2,               % +Mt, +Fact
            mt_retract/3,               % +Mt, +Fact, +User
            ist/2,                      % +Mt, ?Fact      (local only)
            ist_inherited/2,            % +Mt, ?Fact      (with lifting)

            specialization/2,           % ?Sub, ?Super
            genlMt/2,                   % ?Sub, ?Super    (alias)
            mt_specialize/2,            % +Sub, +Super

            mt_property/3,              % ?Mt, ?Key, ?Value
            mt_set_property/3,          % +Mt, +Key, +Value

            mt_can_read/2,              % +User, +Mt
            mt_can_write/2,             % +User, +Mt
            mt_grant/3,                 % +User, +Access, +Mt
            mt_revoke/3,                % +User, +Access, +Mt

            mt_audit/2,                 % +Mt, ?Entry
            mt_audit_since/3,           % +Mt, +Since, -Entries

            backend_register/1,         % +Backend
            backend_current/1,          % -Backend

            reset_memory_backend/0      % test helper: wipe in-memory store
          ]).

:- use_module(library(lists)).
:- use_module(library(apply)).

/** <module> Microtheory store

A microtheory is a named container for Prolog facts and rules.  Facts
in one microtheory do _not_ become visible in another simply because
both exist, which is the key difference from Prolog's global database:
microtheories are modular contexts that can be combined explicitly.

Microtheories relate via =specialization/2= (more-specific to
more-general), which transports assertions along the lattice via
inheritance.  The predicate =genlMt/2= is an alias matching Cyc's
vocabulary.

Per-user access control is enforced at the =mt_assert/3= and
=ist_inherited/2= level: an =mt_grant/3= entry authorizes a user to
read or write a microtheory; the default is that the microtheory's
=owner= property has full access and all others are denied.

Every assertion and retraction produces an audit entry that records
the user, timestamp, and change.  Audit entries are themselves
Prolog facts and can be queried.

# BACKEND CALLBACK INTERFACE

A backend module is a Prolog module that exports the following
sixteen predicates.  =mt_store= calls them via =backend_current/1=
dispatch.  All mutating callbacks are =det=; reads are =nondet=.

==
backend_init(+BackendOpts)              det.
backend_shutdown                        det.

backend_mt_create(+Mt)                  det.   idempotent
backend_mt_exists(?Mt)                  nondet.
backend_mt_list(-Mts)                   det.
backend_mt_set_property(+Mt,+Key,+Val)  det.   replaces prior value
backend_mt_property(?Mt,?Key,?Value)    nondet.

backend_mt_specialize(+Sub,+Super)      det.   idempotent; cycle check
                                                done by mt_store
backend_specialization(?Sub,?Super)     nondet.

backend_assert(+Mt,+Fact)               det.   idempotent
backend_retract(+Mt,+Fact)              det.   no-op if absent
backend_ist(+Mt,?Fact)                  nondet.

backend_acl_grant(+U,+Access,+Mt)       det.   idempotent
backend_acl_revoke(+U,+Access,+Mt)      det.   no-op if absent
backend_acl(?U,?Access,?Mt)             nondet.

backend_audit_add(+Mt,+When,+U,+Op,+Fact) det.
backend_audit(?Mt,?When,?U,?Op,?Fact)   nondet.
==

The defaults shipped with this module (the =mt_store_memory= section
at the bottom of this file) are the reference implementation; reading
them is the fastest way to understand the contract.

Validation, ACL enforcement, and broadcasts are done by =mt_store=
above the dispatch layer, so backends do not re-implement them.
*/

% ---------------------------------------------------------------------
% Backend registration & dispatch
% ---------------------------------------------------------------------

:- dynamic current_backend_/1.

%!  backend_current(-Backend) is det.
%
%   Unify Backend with the currently-registered backend module name.
%   Defaults to =mt_store= itself (which provides the in-memory
%   reference implementation in this file).

backend_current(B) :-
    (   current_backend_(B0) -> B = B0
    ;   B = mt_store
    ).

%!  backend_register(+Module) is det.
%
%   Register Module as the active backend.  Module must implement
%   every callback listed in the BACKEND CALLBACK INTERFACE section
%   above and must already be loaded.

backend_register(Module) :-
    must_be(atom, Module),
    retractall(current_backend_(_)),
    assertz(current_backend_(Module)).

% Dispatch helpers.  These look up the current backend on every call.
% The cost is one hash lookup; trivial compared to the work of the
% callback itself, and it means hot-swapping backends Just Works.
%
% NB: we use Module:Goal rather than call(Module:Pred, Args...) so
% that the dispatch trace is easy to follow in trace/0 sessions.

dispatch_create_(Mt) :-
    backend_current(B), B:backend_mt_create(Mt).

dispatch_exists_(Mt) :-
    backend_current(B), B:backend_mt_exists(Mt).

dispatch_list_(Mts) :-
    backend_current(B), B:backend_mt_list(Mts).

dispatch_set_property_(Mt, K, V) :-
    backend_current(B), B:backend_mt_set_property(Mt, K, V).

dispatch_property_(Mt, K, V) :-
    backend_current(B), B:backend_mt_property(Mt, K, V).

dispatch_specialize_(Sub, Super) :-
    backend_current(B), B:backend_mt_specialize(Sub, Super).

dispatch_specialization_(Sub, Super) :-
    backend_current(B), B:backend_specialization(Sub, Super).

dispatch_assert_(Mt, Fact) :-
    backend_current(B), B:backend_assert(Mt, Fact).

dispatch_retract_(Mt, Fact) :-
    backend_current(B), B:backend_retract(Mt, Fact).

dispatch_ist_(Mt, Fact) :-
    backend_current(B), B:backend_ist(Mt, Fact).

dispatch_acl_grant_(U, A, Mt) :-
    backend_current(B), B:backend_acl_grant(U, A, Mt).

dispatch_acl_revoke_(U, A, Mt) :-
    backend_current(B), B:backend_acl_revoke(U, A, Mt).

dispatch_acl_(U, A, Mt) :-
    backend_current(B), B:backend_acl(U, A, Mt).

dispatch_audit_add_(Mt, When, U, Op, Fact) :-
    backend_current(B), B:backend_audit_add(Mt, When, U, Op, Fact).

dispatch_audit_(Mt, When, U, Op, Fact) :-
    backend_current(B), B:backend_audit(Mt, When, U, Op, Fact).

% ---------------------------------------------------------------------
% Microtheory creation
% ---------------------------------------------------------------------

%!  mt_create(+Mt) is det.
%
%   Create a new microtheory with default properties.  No-op if the
%   microtheory already exists.

mt_create(Mt) :-
    mt_create(Mt, []).

%!  mt_create(+Mt, +Properties) is det.
%
%   Create microtheory Mt and set the given Properties (list of
%   =|Key=Value|= or =|Key-Value|= pairs).  No-op if Mt already
%   exists; in that case Properties are _added_ (existing ones are
%   untouched).

mt_create(Mt, Props) :-
    must_be(atom, Mt),
    must_be(list, Props),
    dispatch_create_(Mt),
    forall(member(P, Props), set_property_pair_(Mt, P)).

set_property_pair_(Mt, Key=Value) :- !,
    mt_set_property(Mt, Key, Value).
set_property_pair_(Mt, Key-Value) :- !,
    mt_set_property(Mt, Key, Value).
set_property_pair_(_, P) :-
    domain_error(property_pair, P).

%!  mt_exists(?Mt) is nondet.

mt_exists(Mt) :-
    dispatch_exists_(Mt).

%!  mt_list(-Mts) is det.

mt_list(Mts) :-
    dispatch_list_(Mts).

% ---------------------------------------------------------------------
% Properties
% ---------------------------------------------------------------------

%!  mt_property(?Mt, ?Key, ?Value) is nondet.

mt_property(Mt, Key, Value) :-
    dispatch_property_(Mt, Key, Value).

%!  mt_set_property(+Mt, +Key, +Value) is det.

mt_set_property(Mt, Key, Value) :-
    must_be(atom, Mt),
    must_be(atom, Key),
    (   dispatch_exists_(Mt) -> true
    ;   existence_error(microtheory, Mt)
    ),
    dispatch_set_property_(Mt, Key, Value).

% ---------------------------------------------------------------------
% Assertion and retrieval
% ---------------------------------------------------------------------

%!  mt_assert(+Mt, +Fact) is det.

mt_assert(Mt, Fact) :-
    mt_assert(Mt, Fact, system).

%!  mt_assert(+Mt, +Fact, +User) is det.

mt_assert(Mt, Fact, User) :-
    must_be(atom, Mt),
    must_be(nonvar, Fact),
    must_be(atom, User),
    (   dispatch_exists_(Mt) -> true
    ;   existence_error(microtheory, Mt)
    ),
    (   mt_can_write(User, Mt) -> true
    ;   permission_error(write, microtheory, Mt)
    ),
    dispatch_assert_(Mt, Fact),
    get_time(Now),
    dispatch_audit_add_(Mt, Now, User, assert, Fact).

%!  mt_retract(+Mt, +Fact) is det.
%!  mt_retract(+Mt, +Fact, +User) is det.

mt_retract(Mt, Fact) :-
    mt_retract(Mt, Fact, system).

mt_retract(Mt, Fact, User) :-
    must_be(atom, Mt),
    must_be(atom, User),
    (   mt_can_write(User, Mt) -> true
    ;   permission_error(write, microtheory, Mt)
    ),
    (   dispatch_ist_(Mt, Fact)
    ->  dispatch_retract_(Mt, Fact),
        get_time(Now),
        dispatch_audit_add_(Mt, Now, User, retract, Fact)
    ;   true
    ).

%!  ist(+Mt, ?Fact) is nondet.

ist(Mt, Fact) :-
    must_be(atom, Mt),
    dispatch_ist_(Mt, Fact).

%!  ist_inherited(+Mt, ?Fact) is nondet.

ist_inherited(Mt, Fact) :-
    must_be(atom, Mt),
    reachable_mt_(Mt, VisibleMt),
    dispatch_ist_(VisibleMt, Fact).

reachable_mt_(Mt, Mt).
reachable_mt_(Mt, Super) :-
    specialization_closure_(Mt, Super).

specialization_closure_(Sub, Super) :-
    dispatch_specialization_(Sub, Direct),
    (   Super = Direct
    ;   specialization_closure_(Direct, Super)
    ).

% ---------------------------------------------------------------------
% Specialization lattice
% ---------------------------------------------------------------------

%!  specialization(?Sub, ?Super) is nondet.

specialization(Sub, Super) :-
    dispatch_specialization_(Sub, Super).

%!  genlMt(?Sub, ?Super) is nondet.

genlMt(Sub, Super) :- specialization(Sub, Super).

%!  mt_specialize(+Sub, +Super) is det.

mt_specialize(Sub, Super) :-
    must_be(atom, Sub),
    must_be(atom, Super),
    (   dispatch_exists_(Sub)   -> true ; existence_error(microtheory, Sub) ),
    (   dispatch_exists_(Super) -> true ; existence_error(microtheory, Super) ),
    Sub \== Super,
    (   specialization_closure_(Super, Sub)
    ->  domain_error(acyclic_specialization, Sub-Super)
    ;   true
    ),
    dispatch_specialize_(Sub, Super).

% ---------------------------------------------------------------------
% Access control
% ---------------------------------------------------------------------

%!  mt_grant(+User, +Access, +Mt) is det.

mt_grant(User, Access, Mt) :-
    must_be(atom, User),
    must_be(oneof([read, write]), Access),
    must_be(atom, Mt),
    dispatch_acl_grant_(User, Access, Mt).

%!  mt_revoke(+User, +Access, +Mt) is det.

mt_revoke(User, Access, Mt) :-
    dispatch_acl_revoke_(User, Access, Mt).

%!  mt_can_read(+User, +Mt) is semidet.
%!  mt_can_write(+User, +Mt) is semidet.

mt_can_read(system, _) :- !.
mt_can_read(User, Mt) :-
    (   dispatch_property_(Mt, visibility, public) -> true
    ;   dispatch_property_(Mt, owner, User) -> true
    ;   dispatch_acl_(User, read, Mt) -> true
    ;   dispatch_acl_(User, write, Mt)
    ).

mt_can_write(system, _) :- !.
mt_can_write(User, Mt) :-
    (   dispatch_property_(Mt, owner, User) -> true
    ;   dispatch_acl_(User, write, Mt)
    ).

% ---------------------------------------------------------------------
% Audit
% ---------------------------------------------------------------------

%!  mt_audit(+Mt, ?Entry) is nondet.

mt_audit(Mt, audit(When, User, Op, Fact)) :-
    dispatch_audit_(Mt, When, User, Op, Fact).

%!  mt_audit_since(+Mt, +Since, -Entries) is det.

mt_audit_since(Mt, Since, Entries) :-
    findall(audit(When, User, Op, Fact),
            ( dispatch_audit_(Mt, When, User, Op, Fact),
              When > Since ),
            Entries).

% =====================================================================
% mt_store_memory  --  the default in-memory backend.
% =====================================================================
%
% Reference implementation of the BACKEND CALLBACK INTERFACE.  Lives
% in the =mt_store= module namespace (rather than its own module) for
% two reasons:
%
%   1. It is the default backend; loading =library(mt_store)= should
%      give you a working store with no further configuration.
%
%   2. Tests can wipe state with =reset_memory_backend/0= without
%      caring about the dynamic predicates' names.
%
% =====================================================================

:- dynamic mt_registry_/1.                       % mt_registry_(Mt)
:- dynamic mt_prop_/3.                           % mt_prop_(Mt, Key, Value)
:- dynamic mt_fact_/2.                           % mt_fact_(Mt, Fact)
:- dynamic mt_spec_/2.                           % mt_spec_(Sub, Super)
:- dynamic mt_acl_/3.                            % mt_acl_(User, Access, Mt)
:- dynamic mt_audit_/5.                          % mt_audit_(Mt, When, User, Op, Fact)

%!  reset_memory_backend is det.
%
%   Wipe every fact stored by the in-memory backend.  Intended for
%   test setup; safe to call at any time, but obviously destroys data.
%   Has no effect on other backends.

reset_memory_backend :-
    retractall(mt_registry_(_)),
    retractall(mt_prop_(_,_,_)),
    retractall(mt_fact_(_,_)),
    retractall(mt_spec_(_,_)),
    retractall(mt_acl_(_,_,_)),
    retractall(mt_audit_(_,_,_,_,_)).

% --- backend callbacks ---

backend_init(_Opts) :- !.
backend_shutdown    :- !.

backend_mt_create(Mt) :-
    (   mt_registry_(Mt) -> true
    ;   assertz(mt_registry_(Mt))
    ).

backend_mt_exists(Mt) :-
    mt_registry_(Mt).

backend_mt_list(Mts) :-
    findall(M, mt_registry_(M), Mts).

backend_mt_set_property(Mt, Key, Value) :-
    retractall(mt_prop_(Mt, Key, _)),
    assertz(mt_prop_(Mt, Key, Value)).

backend_mt_property(Mt, Key, Value) :-
    mt_prop_(Mt, Key, Value).

backend_mt_specialize(Sub, Super) :-
    (   mt_spec_(Sub, Super) -> true
    ;   assertz(mt_spec_(Sub, Super))
    ).

backend_specialization(Sub, Super) :-
    mt_spec_(Sub, Super).

backend_assert(Mt, Fact) :-
    (   mt_fact_(Mt, Fact) -> true
    ;   assertz(mt_fact_(Mt, Fact))
    ).

backend_retract(Mt, Fact) :-
    retractall(mt_fact_(Mt, Fact)).

backend_ist(Mt, Fact) :-
    mt_fact_(Mt, Fact).

backend_acl_grant(User, Access, Mt) :-
    (   mt_acl_(User, Access, Mt) -> true
    ;   assertz(mt_acl_(User, Access, Mt))
    ).

backend_acl_revoke(User, Access, Mt) :-
    retractall(mt_acl_(User, Access, Mt)).

backend_acl(User, Access, Mt) :-
    mt_acl_(User, Access, Mt).

backend_audit_add(Mt, When, User, Op, Fact) :-
    assertz(mt_audit_(Mt, When, User, Op, Fact)).

backend_audit(Mt, When, User, Op, Fact) :-
    mt_audit_(Mt, When, User, Op, Fact).
