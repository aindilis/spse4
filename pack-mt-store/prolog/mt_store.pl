/*  pack-mt-store -- Microtheory store with pluggable backend.

    Part of FRKCSA / SPSE4.  GPLv3 License.

    Implements a Guha-style microtheory (context) layer for SWI-Prolog
    knowledge.  Each microtheory is a named container for facts and
    rules.  Microtheories are related by a =specialization/2= (a.k.a.
    =genlMt/2=) lattice which supports inheritance of assertions from
    more general theories into more specific ones.

    This pack does _not_ commit to any particular storage backend.
    The default is an in-memory assertion backend with zero external
    dependencies, suitable for development and testing.  A MySQL-backed
    backend using =prolog-mysql-store= can be plugged in by registering
    alternative implementations of =backend_assert/3= etc.

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
            backend_current/1           % -Backend
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
*/

% ---------------------------------------------------------------------
% Backend registration
% ---------------------------------------------------------------------
%
% The actual storage is delegated to a backend module that implements
% a small set of callbacks.  The default backend is defined in this
% file and uses dynamic predicates.  Replace by calling
% =backend_register/1= with the module name of an alternative.

:- dynamic current_backend_/1.

backend_current(B) :-
    (   current_backend_(B0) -> B = B0
    ;   B = mt_store   % fall back to ourselves
    ).

backend_register(Module) :-
    must_be(atom, Module),
    retractall(current_backend_(_)),
    assertz(current_backend_(Module)).

% ---------------------------------------------------------------------
% Default in-memory backend
% ---------------------------------------------------------------------

:- dynamic mt_registry_/1.                       % mt_registry_(Mt)
:- dynamic mt_prop_/3.                           % mt_prop_(Mt, Key, Value)
:- dynamic mt_fact_/2.                           % mt_fact_(Mt, Fact)
:- dynamic mt_spec_/2.                           % mt_spec_(Sub, Super)
:- dynamic mt_acl_/3.                            % mt_acl_(User, Access, Mt)
:- dynamic mt_audit_/5.                          % mt_audit_(Mt, When, User, Op, Fact)

% ---------------------------------------------------------------------
% Microtheory creation
% ---------------------------------------------------------------------

%%  mt_create(+Mt) is det.
%
%   Create a new microtheory with default properties.  No-op if the
%   microtheory already exists.

mt_create(Mt) :-
    mt_create(Mt, []).

%%  mt_create(+Mt, +Properties) is det.
%
%   Create microtheory Mt and set the given Properties (list of
%   =|Key=Value|= or =|Key-Value|= pairs).  No-op if Mt already
%   exists; in that case Properties are _added_ (existing ones are
%   untouched).

mt_create(Mt, Props) :-
    must_be(atom, Mt),
    must_be(list, Props),
    (   mt_registry_(Mt) -> true
    ;   assertz(mt_registry_(Mt))
    ),
    forall(member(P, Props), set_property_pair_(Mt, P)).

set_property_pair_(Mt, Key=Value) :- !,
    mt_set_property(Mt, Key, Value).
set_property_pair_(Mt, Key-Value) :- !,
    mt_set_property(Mt, Key, Value).
set_property_pair_(_, P) :-
    domain_error(property_pair, P).

%%  mt_exists(?Mt) is nondet.
%
%   True when Mt is a known microtheory.  On backtracking, enumerates
%   all microtheories.

mt_exists(Mt) :-
    mt_registry_(Mt).

%%  mt_list(-Mts) is det.
%
%   Unifies Mts with the list of all known microtheories in
%   assertion order.

mt_list(Mts) :-
    findall(M, mt_registry_(M), Mts).

% ---------------------------------------------------------------------
% Properties
% ---------------------------------------------------------------------

%%  mt_property(?Mt, ?Key, ?Value) is nondet.
%
%   True when microtheory Mt has property Key = Value.

mt_property(Mt, Key, Value) :-
    mt_prop_(Mt, Key, Value).

%%  mt_set_property(+Mt, +Key, +Value) is det.
%
%   Set a property on the microtheory, replacing any prior value
%   for that key.

mt_set_property(Mt, Key, Value) :-
    must_be(atom, Mt),
    must_be(atom, Key),
    (   mt_registry_(Mt) -> true
    ;   existence_error(microtheory, Mt)
    ),
    retractall(mt_prop_(Mt, Key, _)),
    assertz(mt_prop_(Mt, Key, Value)).

% ---------------------------------------------------------------------
% Assertion and retrieval
% ---------------------------------------------------------------------

%%  mt_assert(+Mt, +Fact) is det.
%
%   Assert Fact into microtheory Mt without recording a user.

mt_assert(Mt, Fact) :-
    mt_assert(Mt, Fact, system).

%%  mt_assert(+Mt, +Fact, +User) is det.
%
%   Assert Fact into Mt, attributing the change to User.  Fails with
%   permission_error if User lacks write access to Mt.  Records an
%   audit entry.

mt_assert(Mt, Fact, User) :-
    must_be(atom, Mt),
    must_be(nonvar, Fact),
    must_be(atom, User),
    (   mt_registry_(Mt) -> true
    ;   existence_error(microtheory, Mt)
    ),
    (   mt_can_write(User, Mt) -> true
    ;   permission_error(write, microtheory, Mt)
    ),
    (   mt_fact_(Mt, Fact) -> true                  % idempotent
    ;   assertz(mt_fact_(Mt, Fact))
    ),
    get_time(Now),
    assertz(mt_audit_(Mt, Now, User, assert, Fact)).

%%  mt_retract(+Mt, +Fact) is det.
%%  mt_retract(+Mt, +Fact, +User) is det.
%
%   Retract Fact from Mt, attributing to User.  No-op if the fact is
%   not present.

mt_retract(Mt, Fact) :-
    mt_retract(Mt, Fact, system).

mt_retract(Mt, Fact, User) :-
    must_be(atom, Mt),
    must_be(atom, User),
    (   mt_can_write(User, Mt) -> true
    ;   permission_error(write, microtheory, Mt)
    ),
    (   retract(mt_fact_(Mt, Fact))
    ->  get_time(Now),
        assertz(mt_audit_(Mt, Now, User, retract, Fact))
    ;   true
    ).

%%  ist(+Mt, ?Fact) is nondet.
%
%   "ist" = _is true in_.  True when Fact holds _locally_ in
%   microtheory Mt, with no inheritance from general microtheories.

ist(Mt, Fact) :-
    must_be(atom, Mt),
    mt_fact_(Mt, Fact).

%%  ist_inherited(+Mt, ?Fact) is nondet.
%
%   Like =ist/2= but also returns facts that hold in any microtheory
%   reachable from Mt via the =specialization/2= closure.  This is
%   Guha-style inheritance.
%
%   Duplicates (same Fact asserted in multiple ancestor microtheories)
%   are _not_ suppressed; use =setof/3= at the call site if you want
%   deduplication.

ist_inherited(Mt, Fact) :-
    must_be(atom, Mt),
    reachable_mt_(Mt, VisibleMt),
    mt_fact_(VisibleMt, Fact).

reachable_mt_(Mt, Mt).
reachable_mt_(Mt, Super) :-
    specialization_closure_(Mt, Super).

specialization_closure_(Sub, Super) :-
    mt_spec_(Sub, Direct),
    (   Super = Direct
    ;   specialization_closure_(Direct, Super)
    ).

% ---------------------------------------------------------------------
% Specialization lattice
% ---------------------------------------------------------------------

%%  specialization(?Sub, ?Super) is nondet.
%
%   True when microtheory Sub specializes Super.  Only the directly
%   asserted edges are enumerated; use =ist_inherited/2= if you need
%   the transitive closure.

specialization(Sub, Super) :-
    mt_spec_(Sub, Super).

%%  genlMt(?Sub, ?Super) is nondet.
%
%   Cyc-style alias for =specialization/2=.

genlMt(Sub, Super) :- specialization(Sub, Super).

%%  mt_specialize(+Sub, +Super) is det.
%
%   Assert that Sub specializes Super.  Both must exist.  Fails with
%   a domain_error if the assertion would introduce a cycle.

mt_specialize(Sub, Super) :-
    must_be(atom, Sub),
    must_be(atom, Super),
    (   mt_registry_(Sub)   -> true ; existence_error(microtheory, Sub) ),
    (   mt_registry_(Super) -> true ; existence_error(microtheory, Super) ),
    Sub \== Super,
    % cycle check: is Sub already (directly or transitively) an ancestor of Super?
    (   specialization_closure_(Super, Sub)
    ->  domain_error(acyclic_specialization, Sub-Super)
    ;   true
    ),
    (   mt_spec_(Sub, Super) -> true
    ;   assertz(mt_spec_(Sub, Super))
    ).

% ---------------------------------------------------------------------
% Access control
% ---------------------------------------------------------------------

%%  mt_grant(+User, +Access, +Mt) is det.
%
%   Grant User the given Access to Mt.  Access is one of =read=,
%   =write= (implies read).

mt_grant(User, Access, Mt) :-
    must_be(atom, User),
    must_be(oneof([read, write]), Access),
    must_be(atom, Mt),
    (   mt_acl_(User, Access, Mt) -> true
    ;   assertz(mt_acl_(User, Access, Mt))
    ).

%%  mt_revoke(+User, +Access, +Mt) is det.
%
%   Revoke User's Access to Mt.

mt_revoke(User, Access, Mt) :-
    retractall(mt_acl_(User, Access, Mt)).

%%  mt_can_read(+User, +Mt) is semidet.
%%  mt_can_write(+User, +Mt) is semidet.
%
%   Access check.  The microtheory's =owner= property grants both
%   read and write; explicit ACL entries grant the corresponding
%   access.  The pseudo-user =system= always has full access.  A
%   microtheory with =visibility=public=  is readable by everyone.

mt_can_read(system, _) :- !.
mt_can_read(User, Mt) :-
    (   mt_prop_(Mt, visibility, public) -> true
    ;   mt_prop_(Mt, owner, User) -> true
    ;   mt_acl_(User, read, Mt) -> true
    ;   mt_acl_(User, write, Mt)
    ).

mt_can_write(system, _) :- !.
mt_can_write(User, Mt) :-
    (   mt_prop_(Mt, owner, User) -> true
    ;   mt_acl_(User, write, Mt)
    ).

% ---------------------------------------------------------------------
% Audit
% ---------------------------------------------------------------------

%%  mt_audit(+Mt, ?Entry) is nondet.
%
%   Enumerate audit entries for Mt.  Each Entry is a term
%   =|audit(When, User, Op, Fact)|= where Op is =assert= or =retract=.

mt_audit(Mt, audit(When, User, Op, Fact)) :-
    mt_audit_(Mt, When, User, Op, Fact).

%%  mt_audit_since(+Mt, +Since, -Entries) is det.
%
%   Collect all audit entries for Mt whose timestamp is strictly
%   greater than Since (a Unix epoch float as returned by
%   =get_time/1=).

mt_audit_since(Mt, Since, Entries) :-
    findall(audit(When, User, Op, Fact),
            ( mt_audit_(Mt, When, User, Op, Fact),
              When > Since ),
            Entries).
