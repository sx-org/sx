> **RESOLVED** (2026-06-27). Root cause: a value whose type has NO modeled
> coercion to the destination slot (`classify == .none`) was passed through the
> `coerceMode` `.no_op, .none => return val` arm UNCHANGED — a raw reinterpreting
> store. When the value's byte width differed from the slot's (a 16-byte `string`
> into a 4-byte `i32`), the store overran the slot and corrupted memory / SIGSEGV'd.
>
> Fix: a shared guard `checkAssignable` / `noneReinterpretIsUnsafe`
> (`src/ir/lower/coerce.zig`) rejects a `.none` store ONLY when the byte WIDTHS
> differ (`typeSizeBytes`, the LLVM-accurate ABI size — NOT the field-padded
> `sizeOf`). A same-width `.none` is a legitimate bit-compatible reinterpretation
> (`*T → [*]T`, `i64 → isize`, a bare fn-ref into a function slot) and stays
> allowed; an explicit `xx`/`cast` always passes (the escape hatch). Cascades are
> suppressed via `externalErrorsExist()` (the guard tallies its own diagnostics,
> so a pre-lowering error — an unknown annotation type — or a failed initializer
> doesn't trigger a pile-on, while independent mismatches each still report).
> Wired into EVERY annotated-slot store site: var-decl, body-local const-decl,
> scalar reassignment (local + global), struct/tuple field, array/slice/pointer
> element, pointer deref, multi-assignment targets, and named-return defaults.
> (`destructure-decl` infers target types from the RHS, so it has no annotation
> to mismatch.) Regression tests: `examples/diagnostics/1205` (var/const/reassign)
> + `examples/diagnostics/1206` (field/element/deref/multi-assign width overrun).
>
> NOTE: a sibling runtime-safety gap surfaced during the fix's adversarial
> review — unboxing an `Any` to a mismatched type is unchecked (silent-wrong /
> segfault). That is a DIFFERENT code path (`unbox_any`, not the `.none`
> passthrough) and is filed separately as **issue 0198**.

# 0197 — annotated assignment with an incompatible type is unchecked (segfaults)

**Symptom** — A variable / constant declared with an explicit type annotation and
an initializer of an INCOMPATIBLE type is accepted with no diagnostic; the value
is passed through unchanged (a `.none` coercion plan), bit-mangling the slot and
segfaulting at run time.

- Observed: `x : i32 = "hi";` compiles, then crashes (`Segmentation fault`).
- Expected: a compile-time diagnostic — `cannot initialize 'x' of type 'i32'
  with a value of type 'string'` (or similar), exit code 1, no crash.

This is a GENERAL type-checking gap, not specific to any one feature. It was
surfaced while reviewing the multi-return feature (a named-return slot default
`-> (sum: i32 = "hi", …)` hit the same path; that site now has its own guard, but
the underlying annotated-assignment hole remains).

## Reproduction

```sx
#import "modules/std.sx";

main :: () -> i64 {
    x : i32 = "hi";        // string initializer for an i32 slot — no diagnostic
    print("{}\n", x);      // garbage, then SIGSEGV
    return 0;
}
```

`./zig-out/bin/sx run repro.sx` → prints garbage then `Segmentation fault`.
`./zig-out/bin/sx ir repro.sx` does NOT crash (it lowers fine) — the bad coercion
blows up only at run time.

## Investigation prompt

The annotated var/const-decl lowering stores the initializer into the slot
WITHOUT checking that the initializer's type can actually reach the annotated
type. The store goes through `coerceToType` → `coerceMode`
(`src/ir/lower/coerce.zig:596,606`), whose classifier
(`coercionResolver().classify`, `src/ir/conversions.zig:54`) returns `.none` for
an incompatible pair — and `coerceMode`'s `.no_op, .none => return val` arm
(coerce.zig ~614) then passes the value through unchanged, so a 16-byte `string`
lands in a 4-byte `i32` slot (and vice-versa), corrupting memory.

The fix likely belongs at the annotated var-decl / const-decl store sites
(`src/ir/lower/stmt.zig` `lowerVarDecl` ~line 450, and the const-decl path) and
anywhere else a value is stored into an explicitly-annotated slot: when
`classify(src_ty, dst_ty) == .none` and `src_ty != dst_ty`, emit a diagnostic
(`self.diagnostics.addFmt(.err, span, "...", ...)`) instead of silently coercing.
(The multi-return default site already does exactly this — see the
`coercionResolver().classify(...) == .none` guard in `bindNamedReturnSlots`,
`src/ir/lower/stmt.zig` — that pattern can be lifted to a shared helper and reused
at the assignment sites.)

Verification: `./zig-out/bin/sx run repro.sx` should print a type-mismatch
diagnostic and exit non-zero, NOT segfault. Add a `examples/diagnostics/` or
`examples/types/` negative example once fixed.
