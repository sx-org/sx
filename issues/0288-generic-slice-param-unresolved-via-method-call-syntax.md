# 0288 — struct method with a `[]$T` param crashes LLVM emission when called with method syntax

> **RESOLVED** (fixed 2026-07-16 in fd212db0; banner added 2026-07-17 —
> the fix landed without one). `resolveCallParamTypes` resolved a generic
> method's declared params with no bindings installed, interning
> `[]unresolved` poison that `any_to_string`'s slice category scan later
> monomorphized into an uncompilable `slice_to_string__unresolved`. Fixed
> by binding through the receiver-prepended call site before resolving
> params, and skipping `.unresolved`-based container types in the category
> scan. Regression test:
> `examples/generics/0221-generics-slice-param-method-call.sx`.

## Symptom

A struct method whose parameter is a generic **slice** (`xs: []$T`) fails to
bind `T` when called as `recv.method(args)`. The unresolved type is never
diagnosed and reaches the backend, panicking the compiler:

```
thread panic: unresolved type reached LLVM emission — a type resolution failure was not diagnosed/aborted
src/backend/llvm/types.zig:196  toLLVMTypeInfo
src/backend/llvm/types.zig:38   toLLVMType
src/ir/emit_llvm.zig:2641       toLLVMType
src/backend/llvm/ops.zig:2031   emitIndexGet
src/ir/emit_llvm.zig:1719       emitInst
```

Observed: compiler panic (no diagnostic, exit via `@panic`).
Expected: `T` binds to the argument's element type, exactly as it does for the
same method called in explicit form.

The defect is specific to the **slice**-shaped generic param reached through
**method-call syntax**. Three neighbouring shapes all work, which brackets it
tightly:

| call | param | result |
|---|---|---|
| `b.take(a)` | `xs: []$T` | **panic** |
| `Box.take(@b, a)` | `xs: []$T` | ok |
| `b.take(7)` | `v: $T` | ok |
| `free_take(@n, a)` | `xs: []$T` (free fn) | ok |

Passing an already-materialized `[]i64` instead of a `[4]i64` panics too, so
the array→slice coercion is not the trigger.

## Reproduction

```sx
#import "modules/std.sx";

Box :: struct {
    n: i64;
    take :: (self: *Box, xs: []$T) -> i64 { xs.len }
}

main :: () {
    b := Box.{ n = 1 };
    a : [4]i64 = .[1, 2, 3, 4];
    print("{}\n", Box.take(@b, a));   // ok — prints 4
    print("{}\n", b.take(a));         // panics the compiler
}
```

Control (swap the slice param for a scalar and the same method syntax is fine):

```sx
#import "modules/std.sx";

Box :: struct {
    n: i64;
    take :: (self: *Box, v: $T) { print("scalar {}\n", v); }
}

main :: () {
    b := Box.{ n = 1 };
    b.take(7);   // ok — prints "scalar 7"
}
```

## Investigation prompt

`src/ir/calls.zig` plans `obj.method(args)` in the "Instance method call"
branch (~line 317). That branch resolves the callee with
`self.l.resolveFuncByName(qualified)`, which only finds **already-lowered,
non-generic** functions — a generic method has no mono to find, so the branch
produces nothing and the call falls through with `.unresolved`.

Contrast the free-function UFCS branch immediately below it (~line 360), which
*does* handle generics explicitly: when `fd0p.type_params.len > 0` it builds
`eff_call_args` with the **receiver prepended at index 0** before inferring, so
binding positions line up with `fd.params[0]`, and re-selects the overload by
receiver.

The instance-method branch appears to be missing the equivalent generic path.
Note `GenericResolver.buildTypeBindings` (`src/ir/generics.zig` ~line 200)
walks `fd.params` in lockstep with `args_ast` via `s2_arg_idx`; if the receiver
is absent from `args_ast` while `self` occupies `fd.params[0]`, every
subsequent param reads the wrong arg slot (or runs off the end, leaving the
param uninferred) — which matches the observed "slice param never binds".

Why the scalar `$T` control passes while `[]$T` panics is not yet explained and
is worth pinning down first — it suggests the scalar case is rescued by a
different route, and that route is the one to mirror (or unify with) for the
slice case.

Two things to fix, independent of each other:

1. **The crash** — the instance-method plan should bind generic methods
   (receiver prepended, mirroring the UFCS branch's `eff_call_args`).
2. **The missing diagnostic** — an unresolved type reaching
   `toLLVMTypeInfo` should have been reported as a type error and aborted
   compilation. Whatever the root cause, an unbound `$T` must produce a
   diagnostic, never a backend panic.

Verify with the reproduction above (both lines should print `4`), plus a
regression example under `examples/`.

## Context

Hit while writing a sudoku game against `modules/ui`. `Rng.shuffle` is the
natural spelling for a shuffle helper:

```sx
Rng :: struct {
    state: u64;
    shuffle :: (self: *Rng, xs: []$T) { ... }
}
rng.shuffle(order);   // panics
```
