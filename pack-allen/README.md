# pack-allen — Allen interval algebra for SWI-Prolog

Implements James F. Allen's thirteen primitive relations between time
intervals (Allen 1983, "Maintaining Knowledge About Temporal
Intervals", CACM 26:11), plus a CLP(FD)-backed scheduler that finds
concrete integer start/end assignments satisfying a set of asserted
qualitative constraints.

Part of the FRKCSA / SPSE4 stack, but standalone: it has no dependency
on any other FRDCSA module.

## Install

```prolog
?- pack_install('https://github.com/aindilis/pack-allen.git').
?- use_module(library(allen)).
```

## The thirteen relations

```
  before / after      A --- | ... | B ---        (no touch)
  meets  / met_by     A ---|B ---                (endpoint shared)
  overlaps /
    overlapped_by     A --|-- B                  (interior overlap)
  starts / started_by |A---   |B------           (same start)
  during / contains   B--|A--|--                 (strictly inside)
  finishes /
    finished_by       |--A---|  |---B---|        (same end)
  equals              |ABABAB|                   (coincide)
```

## Example

```prolog
?- use_module(library(allen)).
?- schedule([morning_meeting, lunch, afternoon_review],
            [ constraint(morning_meeting, before, lunch),
              constraint(lunch, meets, afternoon_review) ],
            Solution).
Solution = [ interval(morning_meeting, 0, 1),
             interval(lunch,           2, 3),
             interval(afternoon_review,3, 4) ].
```

## API

See the PlDoc in `prolog/allen.pl`:

- `allen_relation/1` — enumerate the thirteen primitives
- `allen_inverse/2` — converse of a relation
- `allen_compose/3` — compose two relations (partial table; falls
  back to top element for uncovered pairs)
- `interval/3` — declare or retrieve an interval
- `constrain_interval/3` — post a single Allen constraint
- `schedule/3` — solve a set of intervals + constraints

## Tests

```
swipl -g "[t/allen], run_tests" -t halt prolog/allen.pl
```

## License

GPLv3.
