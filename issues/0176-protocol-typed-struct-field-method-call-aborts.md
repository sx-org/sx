# 0176 — calling a method through a protocol-typed struct field aborts (exit 133, no diagnostic)

> **RESOLVED** (root cause differs from the title's hypothesis). The crash had
> nothing to do with struct fields: erasing a type to a protocol when the type
> conforms only via a FREE FUNCTION (`speak :: (self: *Dog)`) rather than an
> explicit `impl Speaker for Dog { ... }` built a vtable of `unreachable` thunks
> → SIGABRT on dispatch. Per specs.md §"Storage and protocol conformance"
> (erasure is impl-driven, not structural), the repro was never valid. Fix
> (`src/ir/lower/protocol.zig`): a conformance gate `firstUnimplementedMethod` in
> `buildProtocolValue` emits a located diagnostic (missing impl, or a
> signature-mismatch when an impl method introduces its own `$T`) instead of
> building unreachable thunks; a `std.debug.panic` tripwire guards the
> `diagnostics == null` path so a non-conforming erasure can never silently ship
> as `undef`. Gate↔thunk equivalence verified bidirectional by 3+1 adversarial
> reviews; suite 788/0. Regressions:
> `examples/protocols/0419-protocols-struct-field-dispatch.sx` (positive),
> `examples/diagnostics/1197-diagnostics-protocol-erasure-no-impl.sx` +
> `1198-diagnostics-protocol-erasure-generic-method.sx` (negative). Updated
> `examples/memory/0808-*.sx` (it relied on a non-conforming erasure that never
> dispatched). (Adjacent pre-existing bug found + filed: 0178 — protocol impl
> method with a mismatched return/param TYPE silently miscompiles.)

## Symptom

A struct field whose type is a PROTOCOL holds an erased value fine, but calling a
method THROUGH that field aborts the process (exit 133, SIGABRT) with no
diagnostic. Reading a non-protocol sibling field is fine; constructing the struct
is fine. The crash needs the method call-through. Reproduces with BOTH
struct-literal init and field assignment, so it is not a struct-literal bug — the
protocol field's method dispatch / vtable through a struct slot is the suspect.
Pre-existing (reproduces on clean master).

## Reproduction

```sx
#import "modules/std.sx";
Speaker :: protocol { speak :: (self: *Self) -> i64; }
Dog :: struct { n: i64 = 0; }
speak :: (self: *Dog) -> i64 { return self.n; }
Holder :: struct { s: Speaker; b: i64 = 0; }
main :: () {
  d := Dog.{ n = 42 };
  h : Holder = .{ s = d, b = 5 };   // or:  h.s = d (field assign) — same crash
  print("{}\n", h.s.speak());        // <-- aborts here, exit 133, no output
}
```

Expected: `42`. Observed: silent abort, exit 133. Reading `h.b` (the non-protocol
field) prints `5` fine; the crash is specifically the call through `h.s`.

## Investigation prompt

The erased protocol value stored in a struct field appears to lose its
method-table / self pointer, so dispatch through `h.s.speak()` reads a
null/garbage vtable. Compare against a protocol value in a LOCAL variable
(`s : Speaker = d; s.speak()` — does THAT work?) to isolate whether the bug is in
storing the erased value into a struct field, or in dispatching through a field
access. Suspect the protocol fat-value `{vtable/typeinfo, data-ptr}` layout when
embedded as a struct field: the field store (`emitStructInit` / field assign) may
truncate or mis-place the fat value, or the method-dispatch lowering for
`field.method()` may not load the full protocol header. Look at how a protocol
local dispatches vs how a protocol struct-field dispatches
(`src/ir/lower/expr.zig` method-call / field-access lowering + `src/backend/llvm`
protocol dispatch). Follow the no-silent-fallback rule. Verify: the repro prints
`42`; both struct-literal and field-assign init; a protocol field reassigned to a
different concrete type dispatches correctly. Add a
`examples/protocols/04xx-protocol-struct-field-dispatch.sx` regression.
