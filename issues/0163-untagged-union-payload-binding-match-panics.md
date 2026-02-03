# 0163 — payload-binding match on a plain untagged `union` panics instead of diagnosing

> **RESOLVED (2026-07-03).** Root cause: in `lowerMatch`
> (`src/ir/lower/control_flow.zig`), the case-capture branch resolved the
> binding's payload type only for `.tagged_union` subjects; for a plain
> untagged `.@"union"` the type stayed `.unresolved` and was emitted into an
> `enum_payload`, leaking to `declareFunction` → `toLLVMType` and panicking.
> Fix (review-folded): the capture branch now guards generically — after the
> tagged-union variant resolution, any binding whose payload type is still
> `.unresolved` is rejected with a diagnostic before any IR is emitted.
> Untagged-union subjects (directly, or through a pointer — pointer subjects
> only auto-deref for tagged unions/enums) get the union-specific wording
> ("cannot bind a payload from untagged union '<T>' — it has no discriminant;
> use a tagged union (enum with payloads) instead"); every other non-bindable
> subject (payload-less enum, struct, integer, ...) gets "this case pattern
> cannot bind a payload from subject type '<T>' — only tagged union (enum
> with payload) variants are bindable"; an unknown variant on a TAGGED union
> keeps its existing single "no variant" diagnostic. The capture is always
> bound to an undef so the arm body lowers without cascading errors;
> compilation aborts before emission. Tagged-union bindings (value and
> pointer-subject statement position) and untagged-union matches WITHOUT a
> binding are unchanged. Regression test:
> `examples/diagnostics/1211-diagnostics-untagged-union-payload-binding.sx`
> (+ unit test in `src/ir/lower.test.zig`).

## Symptom

A `match`-style `if x == { case .variant: (v) { ... } }` with a PAYLOAD BINDING
`(v)` on a value of a plain UNTAGGED `union` type panics in the LLVM backend
instead of producing a diagnostic. An untagged union has no discriminant, so a
case-payload binding is not a valid construct and should be rejected at
typecheck.

- Observed: `thread panic: unresolved type reached LLVM emission` at
  `src/backend/llvm/types.zig:196`, reached via `emit_llvm.zig:1289`
  `declareFunction` → `toLLVMType(param.ty)` (exit 134).
- Expected: a clean diagnostic (e.g. "cannot bind a payload from an untagged
  union — use a tagged enum/union with a discriminant").

Surfaced during the issue-0160 review (blast-radius probing). NOT caused by 0160
— the panic path is union-match lowering → `declareFunction`, none of which the
0160 fix touches. Removing the `(v)` binding, or using a tagged `enum` instead,
both work.

## Reproduction

```sx
#import "modules/std.sx";
Shape :: union { circle: i64; rect: i64; }   // plain untagged union (no discriminant)
main :: () {
    s : Shape = .{ circle = 5 };
    r := if s == { case .circle: (v) { v } case .rect: (v) { v * 2 } };  // panic
    print("{}\n", r);
}
```

## Investigation prompt

The match/case lowering binds a case payload `(v)` whose type it resolves
against the union variant — but a plain `.@"union"` (untagged) has no per-variant
discriminant, so the binding's type leaks out as `.unresolved` and reaches
`declareFunction`. In the match-arm lowering (grep the case/`match_arm` path in
`src/ir/lower/`), reject a payload-binding case when the scrutinee type is an
untagged `.@"union"` (only `.tagged_union` / `.@"enum"` payloads are bindable):
emit a diagnostic and bail, before any `.unresolved` type is produced. Verify
with the repro (expect a clean error, not a panic). Add a diagnostics example.
