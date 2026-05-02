# pack-spse4-core — SPSE4 core task ontology

The core data model of the **Shared Priority System Editor v4** —
a multi-relation graph-based planning-domain editor written in
SWI-Prolog.  Part of the FRKCSA stack.

## Concept

A _priority system_ is a labelled directed multigraph stored in one
or more microtheories:

- **Nodes** are tasks (first-class entities with properties).
- **Edges** are typed binary relations of distinct _kinds_:
  temporal (Allen), `depends`, `provides`, `eases`, `attacks`,
  `supports`, `contingent_on`, `subsumes`, `prefer`.

Storing everything in microtheories (via `pack-mt-store`) lets
multiple domains — medical, financial, household, packaging-work —
coexist without bleeding into each other, with explicit
specialization edges where inheritance is wanted.

## Install

```prolog
?- pack_install('https://github.com/aindilis/pack-allen.git').
?- pack_install('https://github.com/aindilis/pack-mt-store.git').
?- pack_install('https://github.com/aindilis/pack-spse4-core.git').
?- use_module(library(spse4_core)).
```

## Example: the autopackager priority queue

```prolog
:- use_module(library(mt_store)).
:- use_module(library(spse4_core)).

:- initialization(demo).

demo :-
    mt_create(autopackager, [owner=andrew]),

    task_create(autopackager, pkg_vampire,
                [ has_nl = "Package vampire 4.9 for Debian",
                  task_kind = primitive,
                  overlap_class = foregroundable,
                  status = in_progress,
                  needs_resource = build_vm ]),
    task_create(autopackager, pkg_eprover,
                [ has_nl = "Package E 3.1 for Debian",
                  task_kind = primitive,
                  overlap_class = foregroundable,
                  status = completed ]),
    task_create(autopackager, submit_to_frkcsa_repos,
                [ has_nl = "Submit vampire to FRKCSA package repositories",
                  task_kind = primitive,
                  status = open ]),

    edge_assert(autopackager, submit_to_frkcsa_repos, depends, pkg_vampire, []),

    task_ready(autopackager, Ready),
    format("Ready tasks: ~w~n", [Ready]).
```

## Task properties

All user-visible text (labels, descriptions, notes) is stored as
**strings**.  Internal identifiers and enumerated values are
**atoms**.  This matches Covington's coding conventions.

| Key              | Value type                          |
|------------------|-------------------------------------|
| `has_nl`         | string — label                      |
| `description`    | string — longer text                |
| `task_kind`      | atom — `primitive \| compound \| recurring \| ongoing \| milestone` |
| `overlap_class`  | atom — `exclusive \| foregroundable \| backgroundable \| ambient \| batched` |
| `status`         | atom — `open \| in_progress \| completed \| cancelled \| deleted \| skipped \| obsoleted \| rejected \| showstopper \| ridiculous \| habitual` |
| `duration`       | term — `fixed(N) \| range(Lo,Hi) \| distribution(K,Ps) \| effort(Total)` |
| `earliest_start` | datetime term                       |
| `latest_finish`  | datetime term                       |
| `needs_resource` | atom — may repeat                   |
| `costs`/`earns`  | term — e.g. `dollars(30)`           |
| `recurrence`     | string — RRULE                      |
| `triggers_when`  | callable goal                       |
| `source`         | arbitrary term (e.g. `spse2(Ctx)`)  |

Arbitrary keys are accepted; the listed ones are schema-validated.

## Edge kinds and filters

```prolog
% Project by relation kind:
project_graph(medical, kind(depends), proj(Nodes, Edges)).

% Compose filters:
project_graph(medical,
              and(kind(depends), not(status(completed))),
              proj(Nodes, Edges)).
```

## Legacy SPSE2 import

```prolog
?- import_spse2_file('~/spse2-dumps/pse.holds', legacy_pse).
```

The importer maps:
- `holds(Ctx, goal('entry-fn'(P, I)))` → task
- `holds(Ctx, 'has-NL'(..., NL))` → `has_nl` string
- `holds(Ctx, depends(A, B))` → `edge(A, depends, B)`
- `holds(Ctx, complete(...))` → `status=completed`
- and the usual SPSE2 statuses, `costs`, `earns`, etc.

## What's not yet here

- Scheduler wrapper around `pack-allen` (next commit)
- `triggers_when/1` with `when/2` integration
- HTN method decomposition
- PDDL domain emission (`pack-pddl`, separate commit)
- Pengines server layer (`pack-spse4-server`, separate commit)
- Cytoscape.js client

## Tests

```
swipl -g "[t/spse4_core], run_tests" -t halt prolog/spse4_core.pl
```

## License

GPLv3.
