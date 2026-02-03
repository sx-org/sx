# 0156 — deferred `..` spread (pack captured into a closure / tuple spread) crashes the backend

> **✅ RESOLVED (Part 2, 2026-07-04)** — semantics decision **(a)**: a `..`
> spread of a concrete tuple/array IS a real feature (specs.md §"Tuple
> parallels": "`..tuple` … spreads a tuple's fields into call args … a pack
> [can] be materialized once (`stored := .(..xs)`) and later re-spread
> (`f(..stored)`)"), and capturing a pack into a closure MATERIALIZES the
> monomorphized element values into the env.
>
> Fixes:
> - **Value spread** — `..t` on a concrete tuple (always) / fixed array (when
>   the callee has no slice-variadic param) expands to N positional args in
>   the call arg loop (`valueSpreadRefs`, `src/ir/lower/pack.zig`); pack-fn
>   call sites expand spreads at AST level (`expandSpreadArgNodes`), so
>   `print(fmt, ..t)` AND pack forwarding `g(..xs)` work; `.(..t)` re-splices
>   into tuple literals; a tuple spread into a slice variadic repacks
>   per-element (the old pass-tuple-as-slice LLVM verification failure is
>   gone); a non-spreadable operand gets a located diagnostic.
> - **Pack capture** — `collectCaptures` (`src/ir/lower/closure.zig`)
>   materializes a captured pack into a tuple IN THE PARENT (where the
>   elements are live) and stores it by value in the env; `lowerLambda`
>   clears the mono's pack state around the body, so `..args` / `args[i]`
>   inside the closure lower through the ordinary tuple paths — never a
>   re-expansion of the spawner's dead frame.
>
> Regression test: `examples/packs/0830-packs-runtime-tuple-spread.sx`
> (tuple/array spread, pack re-spread, pack-fn spread, variadic repack,
> tuple re-splice, deferred closure over a captured pack, heterogeneous
> capture, comptime-indexed capture). Unit tests: `src/ir/lower.test.zig`
> ("pack spread: expandSpreadArgNodes …").
>
> **Residual (separate pre-existing bugs, NOT this issue):** the repro's
> `captured :: () =>` spelling declares a local STATIC fn
> (`lowerLocalFnDecl`) whose references to enclosing locals silently lower
> to undef — garbage at runtime, NO diagnostic — reproducible with no
> packs/spreads at all (`x := 41; f :: () -> i64 { return x + 1; }` prints
> garbage). Spelled `captured := () => …` (a real closure) the repro prints
> `out: 42`. Also found: capture analysis skips a local that shadows a
> global fn name (e.g. a `dst`-style param named `out` vs std's `out`), so
> the closure writes through garbage. Both reported for separate filing.

> **Two bugs were conflated under this number.** Investigation split them:
>
> **Part 1 — `$R` (single-type generic) in a type-arg slot inside a pack-fn body
> → LLVM panic — ✅ FIXED.** The parser tags every `$name` expression as
> `comptime_pack_ref`, so a single-type binding (`$R` from `Closure(..$args) ->
> $R`) used as `Box($R)` / `size_of(Box($R))` reached `resolveTypeWithBindings`
> (the resolver `instantiateGenericStruct` runs each type-arg through) as a
> `comptime_pack_ref` it had no arm for → catch-all `else` → `.unresolved` →
> `src/backend/llvm/types.zig:196` panic. Fix: mirror `resolveTypeArg`'s
> `comptime_pack_ref` arm in `resolveTypeWithBindings` (`src/ir/lower.zig`) —
> look up `type_bindings`, else emit a loud "pack used where a single type is
> required" diagnostic (never a silent default type). Regression test:
> `examples/generics/0216-generics-typearg-in-pack-fn-body.sx` (`size_of(Box($R))`
> in a pack-fn → `r: 42`).
>
> **Part 2 — deferred `..` spread crashes — ✅ FIXED (see banner above).**

## Part 2 — Symptom (was OPEN, now fixed)

A comptime variadic pack is **comptime state**, not a runtime value: a spread
`f(..args)` is expanded at the spread site from `pack_arg_nodes` (the original
call-site arg AST, referencing the *caller's* locals). Trying to make a `..`
spread cross a **deferred / value boundary** crashes instead of either working
or diagnosing:

- **pack captured into a closure** then spread later — `() => { ... worker(..args) ... }`
  — **SEGFAULTs at runtime** (the deferred body re-expands `args[i]` from the
  spawner's locals, which are gone by the time the closure runs on another
  stack), or panics in the backend when types don't resolve.
- **spreading a concrete TUPLE** — `t := .{40, 2}; w(..t)` — **panics**
  (`unresolved type reached LLVM emission`): `..` only accepts a comptime pack,
  not a runtime aggregate, and the unsupported case degrades to `.unresolved`
  rather than a diagnostic.

Expected: either (a) a `..` spread of a concrete tuple/array is a real feature
that lowers to N positional args, and capturing a pack into a closure
materializes it; or (b) both are rejected with a clean diagnostic at the spread
site. Never a segfault / `.unresolved`-reaches-backend.

## Reproduction (Part 2)

```sx
#import "modules/std.sx";
main :: () {
    w := (a: i64, b: i64) -> i64 => a + b;
    t := .{40, 2};
    out : i64 = 0; po := @out;
    captured :: () => { po.* = w(..t); };   // tuple spread inside a closure
    captured();
    print("out: {}\n", out);                // panics: unresolved type reached LLVM emission
}
```

(Pack-into-closure variant — segfault: see the original repro shape in this
issue's history; `runner :: ufcs (io, worker: Closure(..$args)->i64, ..$args)`
with `captured :: () => { po.* = worker(..args); }` segfaults at runtime.)

## Why it is NON-BLOCKING for the fiber async work (B1.4a)

The fiber `async`/`await` layer does NOT need a `..` spread to cross the fiber
boundary. Deferred async is expressed as a **nullary thunk** that captures its
inputs at the call site (where they are live) — `async(io, work: Closure() ->
$R)`, used `context.io.async(() => a + b)`. The user's lambda captures `a`/`b`;
`async` spawns the already-bound nullary closure as a fiber. No pack crosses the
deferral. This is the idiomatic deferred-async shape (cf. `go func(){...}()`),
proven end-to-end (`.sx-tmp/pnullary.sx` → `log: 1 2 3 42 100`). So Part 2 is
filed for its own session, not a B1.4a blocker.

## Investigation prompt (Part 2)

Decide the intended semantics of `..` on a concrete value first (consult
`specs.md` §packs). If a `..` spread of a runtime tuple/array SHOULD lower to N
positional args: implement it in the pack-spread call lowering (`src/ir/lower/pack.zig`
`lowerPackElems` / the `.spread_expr` handling) for a concrete-aggregate operand
(emit a GEP+load per element), and make closure capture of a pack materialize
the pack's monomorphized element values into the env. If `..` is intentionally
comptime-pack-only: emit a diagnostic at the spread site when the operand is a
runtime value or a captured pack ("cannot spread a runtime value / a captured
pack; `..` applies to a comptime pack only"), and ensure the capture-analysis
pass rejects a `comptime_pack_ref` capture cleanly — never let `.unresolved`
reach the backend (the segfault path must become a diagnostic). Verify: the
Part-2 repro above either prints `out: 42` or emits one clean diagnostic — never
a segfault / panic.
