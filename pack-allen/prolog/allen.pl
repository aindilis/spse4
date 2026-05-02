/*  pack-allen -- Allen interval algebra for SWI-Prolog

    Part of FRKCSA / SPSE4.  Distributed under the MIT License.

    This module implements Allen's interval algebra (Allen, 1983): the
    thirteen primitive binary relations between two time intervals,
    their inverses, the composition table, and a CLP(FD)-backed scheduler
    that assigns concrete integer start/end times to a set of intervals
    while respecting a set of asserted qualitative constraints.

    The module uses strings (not atoms) for any user-visible label text
    and atoms for relation names and interval identifiers, following
    Covington's Prolog coding standards.
*/

:- module(allen,
          [ allen_relation/1,           % ?Rel
            allen_inverse/2,            % ?Rel, ?Inverse
            allen_compose/3,            % +R1, +R2, -Composed
            schedule/3,                 % +Intervals, +Constraints, -Solution
            relation_implies/2,         % +R1, +R2   (strict -> loose)
            all_relations/1             % -List
          ]).

:- use_module(library(clpfd)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(assoc)).

/** <module> Allen interval algebra

Allen's thirteen primitive relations hold between any two closed
intervals on a linear timeline:

  * =|before|=        A ends strictly before B starts
  * =|meets|=         A ends at the same instant B starts
  * =|overlaps|=      A starts before B, ends inside B
  * =|starts|=        A and B start together, A ends first
  * =|during|=        A is strictly inside B
  * =|finishes|=      A and B end together, A starts later
  * =|equals|=        A and B coincide
  * plus the inverses =|after|=, =|met_by|=, =|overlapped_by|=,
    =|started_by|=, =|contains|=, =|finished_by|=

Intervals are referenced by ground atom identifiers within a single
=schedule/3= call; the scheduler creates fresh CLP(FD) variables per
call and returns a list of =|interval(Id, Start, End)|= with integer
time points.

Typical use:

==
?- schedule([a, b, c],
            [ constraint(a, before, b),
              constraint(b, overlaps, c) ],
            Solution).
==
*/

%%  allen_relation(?Rel) is nondet.
allen_relation(before).
allen_relation(after).
allen_relation(meets).
allen_relation(met_by).
allen_relation(overlaps).
allen_relation(overlapped_by).
allen_relation(starts).
allen_relation(started_by).
allen_relation(during).
allen_relation(contains).
allen_relation(finishes).
allen_relation(finished_by).
allen_relation(equals).

%%  all_relations(-List) is det.
all_relations(Rs) :-
    findall(R, allen_relation(R), Rs).

%%  allen_inverse(?Rel, ?Inverse) is semidet.
allen_inverse(before,         after).
allen_inverse(after,          before).
allen_inverse(meets,          met_by).
allen_inverse(met_by,         meets).
allen_inverse(overlaps,       overlapped_by).
allen_inverse(overlapped_by,  overlaps).
allen_inverse(starts,         started_by).
allen_inverse(started_by,     starts).
allen_inverse(during,         contains).
allen_inverse(contains,       during).
allen_inverse(finishes,       finished_by).
allen_inverse(finished_by,    finishes).
allen_inverse(equals,         equals).

%%  relation_implies(+R1, +R2) is semidet.
%
%   Trivially reflexive closure; full transitive closure is via
%   CLP(FD) propagation in =schedule/3=.
relation_implies(R, R) :- allen_relation(R).

%%  allen_compose(+R1, +R2, -Composed) is det.
%
%   Compose two Allen relations: given A R1 B and B R2 C, Composed is
%   the list of relations that must hold between A and C.  Only a
%   partial table is encoded here; for any pair not listed we return
%   the full 13-element disjunction (the top element of the Allen
%   lattice).  CLP(FD) handles the actual constraint propagation.
allen_compose(before, before,         [before]).
allen_compose(before, meets,          [before]).
allen_compose(before, overlaps,       [before]).
allen_compose(before, starts,         [before]).
allen_compose(before, during,         [before, meets, overlaps, starts, during]).
allen_compose(meets,  before,         [before]).
allen_compose(meets,  meets,          [before]).
allen_compose(meets,  overlaps,       [before]).
allen_compose(meets,  finished_by,    [meets]).
allen_compose(equals, R,              [R]) :- allen_relation(R).
allen_compose(R,      equals,         [R]) :- allen_relation(R).
allen_compose(_, _, Rs) :- all_relations(Rs).

% ---------------------------------------------------------------------
% Private: constraint posting against a caller-supplied map
% ---------------------------------------------------------------------
%
% We map each interval id to a pair (Start, End) of CLP(FD) variables
% held in an association list (library(assoc)).  Constraints are posted
% against these variables directly -- no assertz/retract games, so
% labelling really does ground them.

allen_constraint_(before,        _AS, AE, BS,  _BE) :- AE #< BS.
allen_constraint_(after,         AS, _AE,_BS,  BE) :- BE #< AS.
allen_constraint_(meets,         _AS, AE, BS,  _BE) :- AE #= BS.
allen_constraint_(met_by,        AS, _AE,_BS,  BE) :- BE #= AS.
allen_constraint_(overlaps,      AS, AE, BS,  BE) :- AS #< BS, BS #< AE, AE #< BE.
allen_constraint_(overlapped_by, AS, AE, BS,  BE) :- BS #< AS, AS #< BE, BE #< AE.
allen_constraint_(starts,        AS, AE, BS,  BE) :- AS #= BS, AE #< BE.
allen_constraint_(started_by,    AS, AE, BS,  BE) :- AS #= BS, BE #< AE.
allen_constraint_(during,        AS, AE, BS,  BE) :- BS #< AS, AE #< BE.
allen_constraint_(contains,      AS, AE, BS,  BE) :- AS #< BS, BE #< AE.
allen_constraint_(finishes,      AS, AE, BS,  BE) :- BS #< AS, AE #= BE.
allen_constraint_(finished_by,   AS, AE, BS,  BE) :- AS #< BS, AE #= BE.
allen_constraint_(equals,        AS, AE, BS,  BE) :- AS #= BS, AE #= BE.

% ---------------------------------------------------------------------
% Scheduler
% ---------------------------------------------------------------------

%%  schedule(+Intervals, +Constraints, -Solution) is nondet.
%
%   Given a list of atom interval identifiers and a list of
%   =|constraint(A, Rel, B)|= terms, find an assignment of integer
%   start and end points that satisfies every constraint.  Solution is
%   a list =|interval(Id, Start, End)|= in the same order as Intervals.
%
%   Each interval has duration >= 1 and bounds in 0..1000.  These
%   bounds are deliberately generous for MVP use; callers wanting
%   different bounds should post additional constraints via the
%   underlying CLP(FD) layer, or a future =schedule/4= with options.
%
%   Nondeterministic: backtracking yields alternative schedules in the
%   order produced by CLP(FD) labelling.

schedule(Intervals, Constraints, Solution) :-
    must_be(list, Intervals),
    maplist(must_be(atom), Intervals),
    must_be(list, Constraints),
    % Build the id -> (S,E) map.
    empty_assoc(Empty),
    foldl(add_interval_, Intervals, Empty, Map),
    % Collect all variables for labelling (in stable order).
    intervals_vars_(Intervals, Map, Vars),
    % Post constraints.  Must use maplist (not forall) because CLP(FD)
    % attribute-variable bindings are undone on backtracking, and
    % forall's internal double-negation backtracks out of each success.
    maplist(post_constraint_map_(Map), Constraints),
    % Label.
    label(Vars),
    % Build the solution list in input order.
    maplist(solution_entry_(Map), Intervals, Solution).

add_interval_(Id, In, Out) :-
    S in 0..1000,
    E in 1..1001,
    E #> S,
    put_assoc(Id, In, S-E, Out).

intervals_vars_([], _, []).
intervals_vars_([Id|Ids], Map, [S, E | Rest]) :-
    get_assoc(Id, Map, S-E),
    intervals_vars_(Ids, Map, Rest).

post_constraint_map_(Map, constraint(A, Rel, B)) :-
    must_be(atom, A),
    must_be(atom, Rel),
    must_be(atom, B),
    get_assoc(A, Map, AS-AE),
    get_assoc(B, Map, BS-BE),
    allen_constraint_(Rel, AS, AE, BS, BE).

solution_entry_(Map, Id, interval(Id, S, E)) :-
    get_assoc(Id, Map, S-E).
