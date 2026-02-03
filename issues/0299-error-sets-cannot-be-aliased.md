# 0299 — error sets cannot be aliased (`Alias :: Base` → "unknown error set")

## Symptom

A `::` alias of a declared error set does not work in error-set positions:
`!Alias` reports "unknown error set 'Alias'", and a cross-module facade
alias (`CastError :: fmt.CastError;` in std.sx) resolves to a TYPE that the
`!` parser then rejects ("expected an error set after '!', found type
'CastError'"). Every other nominal kind (structs, enums, unions, type
aliases over builtins) supports the alias/facade pattern — error sets are
the exception, so a std part-file cannot re-export its error sets through
the std.sx facade.

Found during Step-4 S2 (postfix assertions): fmt.sx's
`CastError :: error { mismatch }` cannot be surfaced to consumers by
aliasing. Workaround-free resolution today: error TAGS are global by name,
so callers absorb `mismatch` via an inferred `!` or their own set
containing a same-named tag — but they cannot NAME the canonical set.

## Reproduction

```sx
#import "modules/std.sx";

Base :: error { boom }
Alias :: Base;

f :: () -> !Alias { raise error.boom; }   // error: unknown error set 'Alias'

main :: () {
    f() catch (e) { print("caught: {}\n", e); };
}
```

Expected: `Alias` is usable everywhere `Base` is (error channel `!Alias`,
`raise`, widening). Actual: "unknown error set 'Alias'".

## Investigation prompt

Suspected area: error-set resolution never consults the alias machinery —
`resolveErrorType` (src/ir/type_bridge.zig) resolves `!Name` through
`inner.resolveName`, and the per-decl registration
(`Lowering.registerErrorSetDecl`) keys sets by their declaring name; a
const alias RHS that is an identifier naming an error set is treated as a
plain type alias (or not registered at all — compare issue 0296's const
aliases, which only handle VALUE consts). The fix likely threads error-set
TypeIds through the same alias map type aliases use (`type_alias_map`) and
teaches the `!Name` resolution to accept an alias that resolves to an
`.error_set` TypeId; check `raise error.X` tag validation and escape
widening treat the aliased set identically. Then re-add the std.sx facade
alias for fmt.sx's `CastError` (see the note left in std.sx) and pin the
facade spelling (`-> !CastError` in a user file).

Verification: the repro prints `caught: boom`; a cross-module alias works
through the std.sx facade; `zig build test` green with a new errors-block
regression example.
