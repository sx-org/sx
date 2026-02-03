# 0303 — concrete lvalue passed to a `*Protocol` param: no diagnostic, LLVM verifier crash

> **RESOLVED (2026-07-18)** — by IMPLEMENTING the ruled semantics (Agra:
> "start with the implementation"): a concrete lvalue → `*P` is now the
> borrowed-VIEW coercion (viewOfConcreteAddr in coerce.zig: borrow-mode
> protocol value with ctx = the lvalue's address, spilled to a frame slot;
> node-aware arm in call.zig's arg loop + pointer arm in coerceCallArgs +
> decl-init arm in stmt.zig), and protocol methods dispatch through `*P`
> (pointer arms at both dispatch/param-lookup sites). A bare VALUE reaching
> the node-less layer diagnoses ("no durable storage to borrow"), and the
> new aggregate↔scalar pun guard in noneReinterpretIsUnsafe backstops every
> remaining unmodeled aggregate pun. Regression:
> examples/protocols/0829-protocols-pointer-view-params.sx +
> examples/diagnostics/1251-diagnostics-protocol-view-refusals.sx.
> specs §Borrowed Views.

## Symptom

Passing a concrete struct lvalue to a parameter of pointer-to-protocol type
is accepted by the front-end with NO diagnostic; the emitted call passes the
struct **by value** where the signature expects a pointer, and compilation
aborts with an LLVM verifier failure instead of a user error.

Observed:
```
LLVM verification failed: Call parameter type does not match function signature!
  %load = load { i64 }, ptr %alloca, align 8
 ptr  %call = call i64 @take_view(ptr @__sx_default_context, { i64 } %load)
```

Expected: a compile diagnostic at the call site (there is no defined
conversion from a concrete value to `*Protocol` today).

## Reproduction

```sx
#import "modules/std.sx";
Sizable :: protocol { size :: (self: *Self) -> i64; }
Widget :: struct { value: i64; }
impl Sizable for Widget { size :: (self: *Widget) -> i64 { self.value } }
take_view :: (v: *Sizable) -> i64 { 0 }
main :: () {
    w := Widget.{ value = 7 };
    print("{}\n", take_view(w));
}
```

`sx run` → LLVM verification failure, exit without a proper diagnostic.

## Investigation prompt

The arg-lowering discipline (lower/call.zig — args lower under their
declared param types via astCalleeParamTypes, the 0302 fix) resolves the
param type `*Sizable`, finds no applicable conversion from `Widget`, and
appears to pass the raw value through unchanged — a silent-fallback-class
gap: a failed arg coercion must produce a diagnostic, never fall through to
codegen. Look at the coercion call the arg loop makes (coerceToType /
lowerXX path in src/ir/lower/coerce.zig) and what it returns when no ladder
arm applies for a struct→pointer pair; the caller in call.zig likely does
not check for "no progress". Fix: diagnose "cannot pass a 'Widget' value
where '*Sizable' is expected" (span at the argument). NOTE: the REFLECT
erasure-model redesign (current/CHECKPOINT-REFLECT.md ⏯ block) intends to
DEFINE this cell as the borrowed-view coercion (frame-temp erasure +
address); the immediate fix should be the honest refusal so the crash is
gone regardless of when that model lands. Verification: the repro produces
a clean single diagnostic; `zig build test` stays green.

## Discovered

2026-07-18, REFLECT erasure-model stress review, probe SR-P2b
(.sx-tmp/sr-p2b.sx). Pre-existing; unrelated to the ProtocolRaw commit
(2080d34e — no compiler-source changes in the coercion path).
