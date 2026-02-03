> **RESOLVED** (2026-06-27). Fix: an IMPLICIT `Any → T` unbox is now a COMPILE
> ERROR (`coerceMode`'s `.unbox_any` arm, `mode == .implicit`, in
> `src/ir/lower/coerce.zig`). sx prevents this unsafe class at compile time —
> like the no-implicit-optional-unwrap rule — rather than with a runtime trap
> (the LLVM backend has no runtime-abort infra by design; compiled code relies on
> compile-time flow analysis). The escape hatches are unaffected: an explicit
> `xx some_any` (handled by `lowerXX`'s own unbox arm) and the compiler-generated
> type-dispatch / variadic-pack-extraction unboxes (which emit `.unbox_any`
> directly, not via `coerceMode`) all still work, as do `print`/`type_name`/`{}`
> formatting of an `Any`. So both 0198 cases are fixed: `s : S = some_any` (was a
> segfault) and `f : f64 = some_any` (was a silent `0.0`) now emit a clean
> compile error. Adversarial review found no false-positive (every legitimate
> `Any` pattern still works) and no surviving silent/segfault path. Regression
> test: `examples/diagnostics/1207-diagnostics-any-implicit-unbox-rejected.sx`.
>
> A SEPARATE pre-existing bug surfaced during the review — `Any == <concrete>`
> (one operand `Any`) aborts the LLVM verifier — filed as **issue 0199**.

# 0198 — unboxing an `Any` to a mismatched type is unchecked (silent-wrong / segfaults)

**Symptom** — Extracting a concrete value from an `Any` (the implicit
`Any → T` unbox, `classify == .unbox_any`) does NO runtime tag check: if the
boxed type does not match the unbox target `T`, the boxed bits are reinterpreted
blindly. For a scalar mismatch this silently produces garbage; for an aggregate
target it treats the boxed scalar as a pointer and dereferences it, **segfaulting**.

- Observed:
  - `Any(boxed i64 5) → i64` → `5` (correct).
  - `Any(boxed i64 5) → f64` → `0.000000` (silent garbage — raw bit reinterpret, no diagnostic).
  - `Any(boxed i64 5) → struct{a:i32; b:i32}` → **Segmentation fault** (the i64 `5`
    is treated as a struct pointer and dereferenced).
- Expected: a runtime trap / clean diagnostic on a tag mismatch (the `Any` box
  carries a type tag in field 0 — `{i64 tag, i64 value}` — so a checked unbox is
  feasible), OR at minimum no memory-unsafe dereference.

This is DISTINCT from issue 0197 (the compile-time `.none` annotated-assignment
gap, now fixed): here the static types `Any → T` are a *legal* unbox, so the
mismatch is only knowable at runtime via the tag. It was surfaced by the
adversarial review of the 0197 fix — the 0197 size guard correctly does NOT
fire here because `classify(Any, T) == .unbox_any`, not `.none`.

## Reproduction

```sx
#import "modules/std.sx";

S :: struct { a: i32; b: i32; }

main :: () -> i64 {
    x : Any = 5;        // boxes an i64
    s : S = x;          // Any → S unbox: NO tag check
    print("unreached\n");
    return 0;
}
```

`./zig-out/bin/sx run repro.sx` → `Segmentation fault`. `sx ir` lowers fine.

A non-crashing but silently-wrong variant: change `s : S = x;` to
`f : f64 = x;` — prints `0.000000` with no diagnostic.

## Investigation prompt

The unbox is lowered as `Op.unbox_any` (coerce.zig, the `.unbox_any` arm of
`coerceMode` / `lowerXX`) and emitted by `emitUnboxAny`
(`src/backend/llvm/ops.zig:2462`):

```zig
pub fn emitUnboxAny(self: Ops, instruction: *const Inst, un: UnaryOp) void {
    const any_val = self.e.resolveRef(un.operand);
    const any_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(any_val));
    if (any_kind == c.LLVMStructTypeKind) {
        const raw = c.LLVMBuildExtractValue(self.e.builder, any_val, 1, "ua.raw"); // field 1 = boxed value (i64)
        const target_ty = self.e.toLLVMType(instruction.ty);
        self.e.mapRef(self.e.coerceFromI64(raw, target_ty)); // ← no tag check; struct target derefs the scalar
    } else {
        self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
    }
}
```

The `Any` box is `{ i64 type_tag, i64 value }`. Field 0 is the type tag (the
boxing site stores the source `TypeId`). The fix likely needs `emitUnboxAny` to
compare field 0 against `instruction.ty`'s tag and, on mismatch, trap with a
located runtime diagnostic (mirror the optional-unwrap / bounds-check trap
pattern) rather than `coerceFromI64`-ing arbitrary bits. For an aggregate target
the current `coerceFromI64` path is itself wrong (a >8-byte boxed value is
heap-stored as a pointer in field 1; a fits-in-8 scalar is stored inline) — the
unbox must distinguish the two by the boxed type, which the tag enables.

Decision needed: does sx want `Any` unbox to be CHECKED (trap on mismatch, the
safe default) or remain an unchecked escape hatch (then `xx`/an explicit
checked-cast builtin should be the only spelling, and the implicit
`T x = some_any` unbox should at least not dereference a scalar as a pointer)?
See `specs.md` for the intended `Any` semantics before choosing.

Verification: run the repro; expect a clean trap/diagnostic (or a checked-cast
requirement), NOT a segfault, and the `f64` variant to not silently yield `0.0`.
