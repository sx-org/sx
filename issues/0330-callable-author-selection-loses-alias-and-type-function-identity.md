# 0330 — callable author selection loses alias and type-function identity

> **OPEN (2026-07-21).** Independent adversarial review found internal
> source-selection defects. No public syntax/API change is required.

## Symptom

Bare callable selection does not follow `alias :: target_fn` chains, so a
visible own/one-hop alias can execute or capture an unrelated hidden global
winner. Bare type-function gates similarly prove one visible `Make` but then
obtain the body from the global function map.

Observed: declaration order can select another module's signature, body, or
defaults. Expected: calls, function values/closures, generic consumers, and
type-function heads carry the exact visible terminal `FnDecl` and author
source.

## Reproduction

Create a hidden module and a caller-owned/direct-flat module which both author:

```sx
target :: (x: i64 = 7) -> i64 { x }
run :: target;
Make :: ($T: Type) -> Type { return struct { value: T; }; }
```

Give the hidden versions incompatible results/layouts, import it first, then
call `run()`, capture `closure(run)`, pass `run` to generic/pack consumers, and
instantiate the visible `Make(i64)`. All uses must select the visible terminal.

## Investigation prompt

Make bare callable resolution follow aliases through exact `RawAuthor`/source
facts with cycle detection, returning the terminal declaration rather than a
visibility boolean followed by a global lookup. Apply the same rule to call
and parameterized-type spellings of type functions and declaration-scan
aliases. Preserve loud ambiguity and reject non-function const aliases. Add
call, closure/value, default, generic/pack, and type-function regressions at
opt 0/3, then run `zig build`, `zig build test`, and the full corpus.
