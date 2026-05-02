# pack-pddl — PDDL and HDDL for SWI-Prolog

A tokenizer-and-s-expression-based parser, emitter, and
planner-capability matcher for PDDL 1.2 / 2.1 / 2.2 / 3.0 (core) plus
HDDL methods / ordered-subtasks.

Part of FRKCSA / SPSE4; standalone use is supported.

## Install

```prolog
?- pack_install('https://github.com/aindilis/pack-pddl.git').
?- use_module(library(pddl)).
```

## Features

- **Parser** (`pddl_parse_file/2`, `pddl_parse_string/2`): tolerant
  s-expression recogniser, produces a structured AST.
- **Emitter** (`pddl_emit/2`, `pddl_emit_file/2`): AST → PDDL string.
- **Round-trip property**: `parse ∘ emit ∘ parse ≡ parse` for all
  supported PDDL features (verified by test suite).
- **Feature detection** (`pddl_features_used/2`): inspects an AST and
  returns the set of PDDL features it actually uses (not just what
  `:requirements` declares).
- **Planner capability table** (`planner_capabilities/2`): declarative
  declarations for 16 open-source planners (LAMA, Fast Downward, LPG,
  OPTIC, POPF, ENHSP, SMTPlan, SGPlan, Metric-FF, Scorpion, K*,
  ForbidIter, Lilotane, PANDA, Tree-REX, and variants).
- **Planner matching** (`eligible_planners/2`, `recommend_planner/2`):
  given an AST, enumerate planners that can handle it, or get a
  single heuristic recommendation.

## AST shape

Domain:

```prolog
domain(Name,
       [ requirements([strips, typing, ...]),
         types([typed(T, Parent), ...]),
         predicates([predicate(Name, [typed(Var, Type), ...]), ...]),
         functions([function(Name, Params), ...]),
         constants([typed(Name, Type), ...]),
         action(Name, Params, Precond, Effect),
         durative_action(Name, Params, Duration, Condition, Effect),
         derived(Head, Body),
         method(Name, Params, Task, Subtasks)
       ])
```

Problem:

```prolog
problem(Name,
        [ domain_ref(DomainName),
          requirements([...]),
          objects([typed(Name, Type), ...]),
          init([Fact, ...]),
          goal(GoalExpr),
          metric(Direction, Expr)
        ])
```

Expressions use atoms for function symbols (`and`, `or`, `not`,
predicate names) and `var(Name)` for variables.  The string
`(and (at ?x ?to) (not (at ?x ?from)))` parses as:

```prolog
and(at(var(x), var(to)), not(at(var(x), var(from))))
```

## Example

```prolog
?- use_module(library(pddl)).

?- pddl_parse_string(
     "(define (domain move-dom)
        (:requirements :strips :typing)
        (:types loc)
        (:predicates (at ?x - loc))
        (:action move
          :parameters (?from ?to - loc)
          :precondition (at ?from)
          :effect (and (not (at ?from)) (at ?to))))",
     AST),
   pddl_features_used(AST, F),
   recommend_planner(AST, P).
AST = domain('move-dom', [...]),
F = [strips, typing],
P = lama_first.
```

## Tests

```
swipl -g "[t/pddl], run_tests" -t halt prolog/pddl.pl
```

## Limitations (v0.1)

- Negative number literals (`-5`) in source are not tokenised; wrap
  in a function like `(- 5)` if needed.
- PDDL 3.0 preferences and trajectory constraints parse, but are
  not fed into feature detection for planner matching.
- HDDL coverage is methods + ordered-subtasks only.  Full HDDL
  (`:htn`, `:init-task` in problems, precondition blocks on
  methods) is v0.2.
- The composition table in feature detection defaults to the top
  element for uncovered pairs.

## Future

- v0.2: wider HDDL, PDDL+ processes/events, preferences in matching.
- v0.2: `planutils` adapter (invoke any eligible planner by name).
- v0.2: contingent planning feature class + CPOR/Contingent-FF
  support.

## License

MIT.
