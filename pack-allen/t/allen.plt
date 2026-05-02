/*  Tests for pack-allen  */

:- use_module(library(plunit)).
:- use_module('../prolog/allen').

:- begin_tests(allen).

test(thirteen_relations) :-
    all_relations(Rs),
    length(Rs, 13).

test(inverse_involutive, [forall(allen_relation(R))]) :-
    allen_inverse(R, Inv),
    allen_inverse(Inv, R).

test(before_schedules_correctly) :-
    once(schedule([a, b],
                  [constraint(a, before, b)],
                  [interval(a, AS, AE), interval(b, BS, _)])),
    AS < AE,
    AE < BS.

test(meets_schedules_correctly) :-
    once(schedule([a, b],
                  [constraint(a, meets, b)],
                  [interval(a, _, AE), interval(b, BS, _)])),
    AE =:= BS.

test(equals_schedules_correctly) :-
    once(schedule([a, b],
                  [constraint(a, equals, b)],
                  [interval(a, AS, AE), interval(b, BS, BE)])),
    AS =:= BS,
    AE =:= BE.

test(during_schedules_correctly) :-
    once(schedule([a, b],
                  [constraint(a, during, b)],
                  [interval(a, AS, AE), interval(b, BS, BE)])),
    BS < AS,
    AE < BE.

test(overlaps_schedules_correctly) :-
    once(schedule([a, b],
                  [constraint(a, overlaps, b)],
                  [interval(a, AS, AE), interval(b, BS, BE)])),
    AS < BS, BS < AE, AE < BE.

test(chain_before_meets) :-
    once(schedule([a, b, c],
                  [ constraint(a, before, b),
                    constraint(b, meets,  c) ],
                  Solution)),
    memberchk(interval(a, _, AE), Solution),
    memberchk(interval(b, BS, BE), Solution),
    memberchk(interval(c, CS, _), Solution),
    AE < BS,
    BE =:= CS.

test(inconsistent_fails, [fail]) :-
    schedule([a, b],
             [ constraint(a, before, b),
               constraint(a, after,  b) ],
             _).

:- end_tests(allen).
