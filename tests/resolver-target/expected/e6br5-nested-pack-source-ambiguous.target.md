# Nested-pack ambiguity — target spec

The `08xx` resolver-target cases carry exact target bytes, frozen in
`*.exit/*.stdout/*.stderr` here. This case has none: no implementation emits its
diagnosed form, so its target is a specification rather than bytes.

- **exit:** `1` (see `e6br5-nested-pack-source-ambiguous.exit`).
- **stderr:** at least one `error: type 'Box' is ambiguous: it is declared in
  multiple flat-imported modules; qualify the reference or remove the duplicate
  import`, pointing at the nested `*Box` leaf inside
  `Closure(Closure(*Box, ..$inner) -> $IR, ..$args) -> $R`.
- **stdout:** empty (the build fails before `main` runs).

When the resolver diagnoses this case, its byte-exact `stdout`/`stderr` replace
this file and the case moves to an active marker, like the `08xx` cases.
