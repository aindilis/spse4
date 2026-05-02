# pack-mt-store — Microtheory store for SWI-Prolog

A Guha-style microtheory (context) system for SWI-Prolog, with
pluggable storage backend, per-user access control, and an audit
trail on every change.

Implements the core vocabulary used by Cyc (`ist`, `genlMt`) and by
SPSE2 (`holds(Context, Fact)`), made native to SWI-Prolog.

Part of FRKCSA / SPSE4; standalone use is supported.  The default
backend is pure in-memory assertions with zero external dependencies,
suitable for development and testing.  A `prolog-mysql-store`
backend is planned.

## Install

```prolog
?- pack_install('https://github.com/aindilis/pack-mt-store.git').
?- use_module(library(mt_store)).
```

## Concepts

- **Microtheory**: a named container for Prolog facts and rules.
  Facts in one microtheory do _not_ leak into another.
- **Specialization (`genlMt`)**: a more-specific microtheory inherits
  facts from a more-general one.  The lattice must be acyclic.
- **Access control**: the microtheory's `owner` has full access.
  Others need explicit `mt_grant/3`.  A microtheory with property
  `visibility=public` is readable by everyone.
- **Audit**: every `mt_assert/3` and `mt_retract/3` records an entry
  with timestamp, user, operation, and fact.

## Example

```prolog
?- use_module(library(mt_store)).

?- mt_create(general_kb, [owner=andrew, visibility=public]).
?- mt_create(medical_kb, [owner=andrew]).
?- mt_specialize(medical_kb, general_kb).

?- mt_assert(general_kb, organism(andrew, human)).
?- mt_assert(medical_kb, takes(andrew, vitaminD)).

?- ist(medical_kb, Fact).
Fact = takes(andrew, vitaminD).

?- ist_inherited(medical_kb, Fact).
Fact = takes(andrew, vitaminD) ;
Fact = organism(andrew, human).

?- mt_audit(medical_kb, Entry).
Entry = audit(1713734400.0, andrew, assert, takes(andrew, vitaminD)).
```

## Vocabulary mapping

| SPSE2                      | This pack                         |
|----------------------------|-----------------------------------|
| `holds(Context, Fact)`     | `ist(Context, Fact)`              |
| context inheritance (ad hoc) | `specialization/2`, `genlMt/2`  |

| Cyc                        | This pack                         |
|----------------------------|-----------------------------------|
| `(ist Mt Fact)`            | `ist(Mt, Fact)`                   |
| `(genlMt Sub Super)`       | `genlMt(Sub, Super)`              |

## Tests

```
swipl -g "[t/mt_store], run_tests" -t halt prolog/mt_store.pl
```

## Status

v0.1 — foundation usable.  Planned:

- MySQL backend via `prolog-mysql-store`
- Lifting rules (Guha's cross-context inference)
- Default reasoning with exceptions
- Export to CycL text
- Export to RDF/Turtle

## License

GPLv3.
