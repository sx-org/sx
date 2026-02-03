# 0191 — `coerceToType` silently welds a type-incompatible value into the return slot (no diagnostic)

**Status:** RESOLVED (2026-07-03)

> **Root cause:** `coerceMode`'s `.none` arm passed any unmodeled coercion
> through UNCHANGED — a width-mismatched pair (16-byte `string` into an
> 8-byte `i64` return slot, a struct into a scalar arg) was silently
> bit-welded. Every implicit consumer (value-body returns, explicit
> returns, failable success returns/forwards, call args, struct-literal
> fields, array elements, if/match arm merges) trusted the result.
>
> **Fix:** the `.none` arm now (a) records EXPLICIT `xx`/`cast` passthroughs
> in `Lowering.xx_passthrough_refs` (the escape hatch stays open), and
> (b) for IMPLICIT coercions diagnoses a width-mismatched unmodeled pair
> ("cannot coerce a value of type 'A' to 'B'") via the same
> unsafe-reinterpret predicate as `checkAssignable` (issue 0197) —
> same-width reinterpretations (`i64 → isize`, fn-ref → fn slot) stay
> allowed. Return paths get a dedicated `checkReturnable` guard with the
> value's span ("cannot return a value of type 'A' where 'B' is
> expected"): trailing-expression bodies, explicit `return`, inlined
> comptime returns, lambda tails, failable success returns (single +
> multi-value + forward slots), and pure-failable value returns. The
> enum-variant payload coercion (`.key_up(.{ ... })`) now coerces from the
> lowered ref's authoritative type instead of a re-inference that
> reported the steering target (the union itself) as the source. A
> string literal into a C-import `[*]u8`/`[*]i8` param (`char const *`)
> is now a MODELED literal-only coercion (data pointer, same blessing as
> `cstring`) instead of the old by-ABI-accident header passthrough. The
> `??` default lowering skips the no-op coerce for unmodeled
> width-mismatched pairs so its focused diagnostic stays the only one.
>
> **Regression test:** `examples/diagnostics/1215-diagnostics-return-type-mismatch.sx`
> (trailing-expr + explicit-return forms, exit 1). Predicate pinned in
> `src/ir/conversions.test.zig` ("unmodeled width-mismatched coercion is
> flagged unsafe").

## Symptom

Returning a value whose type is not coercible to the declared return
type (e.g. a `string` where `i64` is expected) is **silently accepted**:
the compiler reinterprets the bytes instead of emitting a type-mismatch
diagnostic, producing garbage at runtime with **exit 0**.

- Observed: `bad :: () -> i64 { "not an int" }` compiles and runs,
  printing a garbage integer (the string's pointer reinterpreted as
  `i64`), exit 0.
- Expected: a clear "cannot return 'string' where 'i64' is expected"
  (type-mismatch) diagnostic + non-zero exit.

This is the silent-clobber failure mode the project forbids: a bad
coercion fabricated rather than rejected.

## Reproduction

```sx
#import "modules/std.sx";

bad :: () -> i64 { "not an int" }      // trailing expression
main :: () { print("{}\n", bad()); }
```

Run: `./zig-out/bin/sx run repro.sx` → exit 0, prints e.g. `4352919116`
(should error). The explicit-return form is identical:

```sx
bad :: () -> i64 { return "not an int"; }
```

It is **not** failable-specific — a plain non-failable return reproduces
it. A value-failable `-> i64 !E { "not an int" }` welds the 16-byte
string struct into the declared `i64` slot (`ret { i64, i32 } { {ptr,i64}
..., i32 0 }`), so the caller's `catch` can even phantom-fire on the
garbage tag.

## Investigation prompt

Root cause: `coerceToType` (in `src/ir/lower/` — grep for `pub fn
coerceToType`) performs the requested coercion (or a bit-reinterpret)
WITHOUT first checking that the source type is actually coercible to the
destination. The value/explicit-return/failable-success return paths all
call it and trust the result. The companion `lowerFailableSuccessReturn`
inherits the same gap.

Likely fix: `coerceToType` should validate coercibility (the same rules
used for assignment / call-argument coercion) and, when the source type
cannot coerce to the destination, emit a
`diagnostics.addFmt(.err, span, "cannot coerce '<src>' to '<dst>'...")`
and return a sentinel (or have callers handle a `null`/`.unresolved`),
rather than reinterpreting bytes. Thread the offending value's span
through (the return paths already plumb a span — see issue 0190's
`lowerValueBody`/`lowerReturn` work).

Verification: the repros above must error with a type-mismatch diagnostic
+ exit 1; legitimate coercions (`i32` → `i64`, `&T` → `*T`, numeric
widening, struct-literal → struct, etc.) must keep working; the full
corpus must stay green. Add a diagnostics regression example for the
incompatible-return case.

(Found by adversarial review during the issue-0190 fix, commit
`df1327e3`. Pre-existing — independent of the 0190 change; reproduces on
plain non-failable returns.)
