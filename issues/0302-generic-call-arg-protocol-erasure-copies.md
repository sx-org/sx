# 0302 — `xx <lvalue>` arg to a GENERIC fn's protocol param heap-copies instead of borrowing

> **RESOLVED (2026-07-17).** Root cause: the early generic-call arg loop
> (lower/call.zig) lowered every arg with a CLEARED target (to stop the
> ambient target leaking), so an `xx local` arg had no protocol target —
> the erasure ran node-lessly in the later value-wise `coerceCallArgs`
> and heap-copied through context.allocator. Fix: the loop now resolves
> the DECLARED param types up front via `astCalleeParamTypes` (in the
> callee's source, $T bindings inferred from the arg nodes), aligns them
> to the arg positions, and lowers each arg under its param target —
> exactly like the direct-call path; unresolvable slots keep the null
> target. Zero corpus fallout. Regression test:
> `examples/memory/0846-memory-generic-arg-erasure-borrows.sx`
> (direct/generic parity, ambient-copy absence, the free(s, xx local)
> pairing, $T params unaffected).

## Symptom

Passing `xx local` to a protocol-typed parameter borrows the local for a
NON-generic callee (the documented protocol-erasure discipline: lvalue →
borrow, mutations visible), but the same argument to a **generic** callee
(any fn with a `$T` param, even when the protocol param itself is
concrete) heap-copies the local through `context.allocator`. Mutations
made through the protocol value then hit the silent COPY — the caller's
local never changes — and the copy leaks (allocated through whatever
allocator is ambient, with no owner to free it).

## Reproduction

```sx
#import "modules/std.sx";
#import "modules/std/mem.sx";

Tracker :: struct { allocs: i64; deallocs: i64; }
impl Allocator for Tracker {
    alloc_bytes :: (self: *Tracker, size: i64) -> *void { self.allocs += 1; c.libc_malloc(size) }
    dealloc_bytes :: (self: *Tracker, ptr: *void) { self.deallocs += 1; c.libc_free(ptr); }
}

poke :: (a: Allocator) { p := a.alloc_bytes(8); a.dealloc_bytes(p); }
gen_poke :: (s: $P, a: Allocator) { p := a.alloc_bytes(8); a.dealloc_bytes(p); _ = s; }

main :: () {
    t := Tracker.{ allocs = 0, deallocs = 0 };
    poke(xx t);
    print("direct: {}/{}\n", t.allocs, t.deallocs);    // 1/1 — borrow, correct
    t2 := Tracker.{ allocs = 0, deallocs = 0 };
    gen_poke(1, xx t2);
    print("generic: {}/{}\n", t2.allocs, t2.deallocs); // 0/0 — WRONG: copied
}
```

Observed: `direct: 1/1` then `generic: 0/0` (the counters land on a
heap copy; with a pushed tracking context the copy's allocation shows up
on the AMBIENT allocator). Expected: `generic: 1/1` — argument-position
`xx <lvalue>` erasure borrows regardless of the callee being generic.

## Investigation prompt

Suspected area: the generic-call argument-lowering path (monomorphization
in src/ir/lower/call.zig / generic.zig) lowers `xx` args WITHOUT the
node-aware protocol-erasure discipline that the direct-call path applies
(`buildProtocolErasure`'s lvalue-borrow branch, coerce.zig ~85) — the
operand loses its lvalue identity (or the erasure runs against a
materialized temp) and falls into the rvalue heap-copy branch through
`context.allocator`. The fix likely threads the ORIGINAL argument node
into the generic path's erasure decision, exactly as the non-generic
path does. Verification: the repro prints `generic: 1/1`; add a pinned
example (memory category) covering a generic callee + `xx local`
Allocator arg with a mutation-visibility assert; `zig build test` green.
Found during S4.4 (2026-07-17) — the free(s, allocator) helper was made
non-generic (ctx-pointer param) partly on merits, which sidesteps this
for std; user generic fns with allocator params remain exposed.
