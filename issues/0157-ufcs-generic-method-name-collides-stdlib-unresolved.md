# 0157 — UFCS generic method whose name collides with a stdlib re-export leaves `$R` unresolved → LLVM panic

> **RESOLVED.** Root cause: a bare-ufcs call `(recv).name(args)` resolved `name`
> via a single last-wins `fn_ast_map[name]` with NO receiver-type filtering — a
> user `cancel :: ufcs (t: *Task($R))` colliding with the stdlib re-export
> `cancel :: ufcs (f: *Future($R))` picked the wrong one, `$R` never bound, and
> `.unresolved` reached LLVM → panic. Fix (`src/ir/lower/call.zig`): for every
> generic-ufcs dispatch, `selectUfcsGenericByReceiver` enumerates ALL module
> authors of the name (`program_index.module_decls` — covers
> namespaced-imported modules, not just flat-visible ones), keeps those whose
> receiver binds all type-params, and picks the most receiver-SPECIFIC one
> (concrete `*Task($R)` over a bare `(x: $T)`), deduping re-exports by fd
> identity; two distinct equally-specific binders → a deterministic "ambiguous,
> qualify the call" diagnostic; none bind → "cannot infer" (never an
> `.unresolved` into codegen). Regression test:
> `examples/generics/0217-generics-ufcs-method-name-collides-stdlib.sx`
> (user `cancel(*Box($R))` vs stdlib `cancel` → resolves to the user method).
>
> Residual (acceptable, no worse than pre-fix): when the receiver-matching
> author isn't in `module_decls` (synthetic), the call falls back to the
> last-wins `fd0` if it binds. Determinism is guaranteed for all enumerable
> authors. The same missing-unbound-param guard also covers the qualified
> struct-method path (call.zig ~960) — left as-is (separate, not hit here).

## Symptom

One-line: a user-defined **generic** UFCS method whose name collides with a
stdlib re-exported generic UFCS (`cancel`, re-exported by `std.sx` from
`io.sx`), called via UFCS on a *different* generic struct, leaves that struct's
type parameter `$R` **unresolved**; the `.unresolved` TypeId then reaches LLVM
emission and panics.

- **Observed:** compiler panic during codegen —
  `thread … panic: unresolved type reached LLVM emission — a type resolution
  failure was not diagnosed/aborted`
  at `src/backend/llvm/types.zig:196` (`.unresolved => @panic(...)`), reached via
  `fieldLLVMType` → `toLLVMTypeInfo` → `declareFunction`.
- **Expected:** the UFCS call resolves to the user's `cancel` (receiver type
  `*Box($R)` ≠ the stdlib `cancel`'s `*Future($R)`), `$R` binds to `i64`, the
  program prints `1`. If the call were genuinely ambiguous/unresolvable, a
  **diagnostic** must be emitted (e.g. "cannot infer generic type parameter
  'R'", which the *non-UFCS* form `cancel(c)` already produces) — never a raw
  codegen panic.

## Reproduction

`issues/0157-ufcs-generic-method-name-collides-stdlib-unresolved.sx`:

```sx
#import "modules/std.sx";

Box :: struct ($R: Type) { value: R; flag: i64; }

// Name collides with std.sx's re-exported `cancel :: io_mod.cancel`
// (generic ufcs over `*Future($R)`).
cancel :: ufcs (b: *Box($R)) { b.flag = 1; }

main :: () -> i64 {
    x : Box(i64) = ---; x.value = 7; x.flag = 0;
    (@x).cancel();          // expected: prints 1
    print("{}\n", x.flag);  // actual: $R unresolved -> LLVM panic
    return 0;
}
```

Run: `./zig-out/bin/sx run issues/0157-...sx` → panics.

### Isolation already done (the trigger is the NAME, nothing else)

Bisected from the B1.4a async-task work (a user `cancel :: ufcs (t: *Task($R))`
on `std/sched.sx`). All of these are IRRELEVANT to the crash — it reproduces or
not based solely on whether the method name collides with a `std.sx` re-export:

- **Renaming `cancel`** to any name NOT exported by `std.sx` (`drop`, `m`,
  `zz_cancel99`, …) → **compiles & runs, prints `1`.** This is the whole bug:
  same body, same struct, same call site — only the name differs.
- Body is irrelevant: `{ b.flag = 1; }` (ignores `$R`), `{ b.value = b.value; }`
  (touches `$R`), and `-> $R { return b.value; }` all crash under the name
  `cancel`.
- Struct shape is irrelevant: single field `{ value: R; }` and two fields
  `{ value: R; flag: i64; }` both crash; field order doesn't matter.
- Construction is irrelevant: an explicit `x : Box(i64) = ---` local crashes
  just as a heap `*Box(i64)` returned from another generic ufcs does. No
  closures / allocator / fibers needed.
- The sibling stdlib name **`wait`** (also re-exported by `std.sx` from `io.sx`,
  generic ufcs over `*Future($R)` returning `$R`) does **NOT** crash when
  user-redefined over `*Box($R)` — it resolves and runs. So only *some*
  colliding names trip it; `cancel` (a void-returning generic ufcs) does.
- The **non-UFCS** spelling `cancel(c)` instead of `c.cancel()` produces a clean
  diagnostic — `error: cannot infer generic type parameter 'R' for 'cancel'
  from this call's arguments` — rather than the panic. So the UFCS path is
  silently skipping the inference-failure diagnostic the non-UFCS path emits,
  and falling through to codegen with `$R` = `.unresolved`.

`std.sx` re-exports the colliding name at line ~101:
`cancel :: io_mod.cancel;` (and `io.sx:127` `cancel :: ufcs (f: *Future($R))`).

## Investigation prompt (paste into a fresh session)

> Fix issue 0157. A user-defined generic UFCS method whose name collides with a
> stdlib re-exported generic UFCS (`std.sx` re-exports `cancel :: io_mod.cancel`,
> a generic `ufcs (f: *Future($R))` from `io.sx`) is mis-resolved when called via
> UFCS on a different generic struct. Repro:
> `./zig-out/bin/sx run issues/0157-ufcs-generic-method-name-collides-stdlib-unresolved.sx`
> → `panic: unresolved type reached LLVM emission` at
> `src/backend/llvm/types.zig:196`. Renaming the user method to a non-colliding
> name makes it work, and the **non-UFCS** call form (`cancel(c)`) already emits
> the correct diagnostic `cannot infer generic type parameter 'R' for 'cancel'`.
>
> Suspected area: UFCS method/overload resolution + generic-arg inference (look
> in `src/ir/lower.zig` / the call-lowering + UFCS-candidate-selection path, and
> the generic-instantiation inference that binds `$R` from the receiver argument
> — grep for where UFCS rewrites `recv.f(args)` into the candidate set and where
> a generic callee's type params are inferred from actual arg types). The bug:
> when an overload set for the UFCS name contains BOTH the stdlib
> `cancel(*Future($R))` and the user `cancel(*Box($R))`, the resolver appears to
> bind `$R` against the wrong candidate (or fails to bind it and proceeds anyway)
> for the receiver `*Box(i64)`, leaving `Box`'s `$R` = `.unresolved`. The fix
> likely needs to either (a) pick the candidate whose receiver type unifies with
> the actual receiver (`*Box(i64)` → user `cancel`) BEFORE inferring type params,
> or (b) when inference fails for the chosen candidate, emit the SAME
> "cannot infer generic type parameter 'R'" diagnostic the non-UFCS path emits —
> never fall through to codegen with an `.unresolved` field type.
>
> Verification: the repro must now print `1` (the user `cancel` runs) — OR, if the
> overload truly is meant to be ambiguous, must emit a clean diagnostic instead
> of the LLVM panic. Then move the repro into the feature suite per CLAUDE.md
> (`examples/generics/...` or wherever name-collision UFCS belongs) and re-run
> `zig build test`. Also re-enable the BLOCKED B1.4a work: the suspending
> fiber-task layer (`go`/`wait`/`cancel`) is already implemented in
> `library/modules/std/sched.sx`; its example
> `examples/concurrency/1813-concurrency-fiber-async-suspend.sx` (a `cancel`
> UFCS over `*Task($R)`) is what surfaced this — once 0157 is fixed, seed
> `examples/concurrency/expected/1813-...exit`, capture goldens with
> `-Dname=...1813...sx -Dupdate-goldens`, and verify the full suite.

## Status: OPEN
