# 0343 — statement-position `#error` fell to `unknown_expr`; fired at the library line inside generics

> **RESOLVED (2026-07-22)** as part of the `#error`/`compile_error`
> consolidation. Two defects:
> 1. A `#error` directive in fn-body statement position had no lowering arm
>    — it stumbled into the `unresolved 'unknown_expr'` fallback instead of
>    emitting its message, despite the spec's "fires when reached in live
>    code" covering statement position.
> 2. The lower-time rejection spelling (`compile_error`, now removed)
>    anchored its diagnostic at the LIBRARY's source line — a comptime
>    panic's stack-bottom anchor — instead of the user call that forced the
>    bad instantiation.
> Fix: `.error_directive` lowering arm fires at lower time (pruned arms
> never lower — per-monomorphization rejection works like the module-scope
> OS-match form), anchored at the OUTERMOST instantiation call site
> (`mono_sites` chain pushed in `lowerGenericCall`) with the directive's
> location as a note. `compile_error` and the paren-less `#error "msg";`
> spelling both removed with migration diagnostics. Regression:
> `examples/diagnostics/1276-diagnostics-error-directive-generic.sx`
> (per-instance firing + user-site anchor + note), 1105 (migration
> diagnostic), 1235 (respelled), 1255/1275 goldens re-anchored.

## Symptom (pre-fix)

```sx
f :: () { #error "statement-position error"; }
main :: () { f(); }
// → error: unresolved 'unknown_expr' (wrong mechanism, wrong message)
```

And the trivial-state rejection anchored at `store.sx:39` instead of the
user's `use_state(...)` call.
