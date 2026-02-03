# 0300 — `struct_field_type` on a runtime SLICE tag segfaults

> **RESOLVED (2026-07-17).** Root cause: the runtime member tables sized
> their rows from `memberCount`, which is null for slices/optionals
> (no static count) — so those tags got a null master-table slot that
> `rt_member_type` dereferenced unchecked. Fix: direction (1) — a new
> `TypeTable.memberTableLen` (memberCount, plus ONE row for kinds that
> answer `memberType` without a count) drives the master builder, the
> name arrays, and the `field_name_get` GEP sizing; `memberType` gained
> `.slice` (element, row 0) and `.optional` (child, row 0) arms, so the
> LLVM tables and the comptime VM answer identically. The static
> type-position fold (`fieldTypeOf`) gained the same two arms for
> parity. Regression test:
> `examples/types/0869-types-runtime-member-type-slice-optional.sx`
> (struct/array/vector/slice/optional runtime tags + static parity).

## Symptom

`struct_field_type(t, 0)` where `t` is a RUNTIME `Type` (from
`type_of(av)` on an `any`) works for struct tags and — notably — for
vector tags (returns the element type), but a runtime **slice** tag
crashes: `Segmentation fault at address 0x0` inside the JIT'd program.
The runtime field-type master-index table (1a S3b-2) has no row (or a
null row) for slice TypeIds, and the lookup dereferences it unchecked —
the silent-table-gap class the project's REJECTED PATTERNS ban.

## Reproduction

```sx
#import "modules/std.sx";

main :: () {
    s : []i64 = .[10, 20, 30];
    sv : any = s;
    st := type_of(sv);
    print("{}\n", type_name(st));                      // []i64 — fine
    print("{}\n", type_name(struct_field_type(st, 0))); // SEGFAULT
}
```

Expected: either `i64` (slices join the element-type answer vectors
already give) or a clean runtime/compile diagnostic ("slice tags do not
answer struct_field_type") — never a null-deref.

## Investigation prompt

Suspected area: the runtime field-family master-index tables
(src/backend/llvm/reflection.zig / the 1a S3b-2 emission) — the
per-TypeId row for `.slice` kinds is absent/null while `.vector` rows
carry the element; the rt dispatch for `struct_field_type` with a
runtime tag indexes the table without a kind gate. Fix direction
(prefer 1): (1) give slice tags an element row — S4.3b's table-driven
fmt slice arm needs exactly `element_type-of-runtime-slice-tag`, so
covering it serves the migration; also decide arrays' runtime answer
stays consistent (the fmt array arm already relies on
`struct_field_type(type, 0)` for arrays). (2) At minimum, kind-gate the
rt lookup and trap with a message instead of dereferencing null.

Verification: the repro prints `[]i64` then `i64` (or the decided
diagnostic); add a pinned example covering runtime
`struct_field_type` over struct/array/vector/slice tags; `zig build
test` green. Found while planning the S4.3b fmt-arm migration
(2026-07-17); the W2b "receiver narrowing" note says arrays/vectors
DROPPED out of struct_field_* for VALUE receivers — the runtime-tag
TYPE query rows are a separate table and are inconsistent between
vector (works) and slice (crash).
