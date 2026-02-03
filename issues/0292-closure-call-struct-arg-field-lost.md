# 0292 — closure call with by-value struct arg: second field arrives zeroed

> **RESOLVED** (2026-07-17). Root cause: `emitCallClosure` /
> `emitCallIndirect` built the indirect call-site function type from the
> raw LLVM param types, while the callee's definition applies the
> default-ABI packing (`abiCoerceDefaultParamType`, ≤8-byte non-HFA
> structs → i64, the issue-0286 fix) — so the packed-struct arg landed in
> two registers the callee never read (second field zeroed). NOT caused
> by fd212db0's `resolveCallParamTypes` change (the suspected origin);
> the mismatch dates to the 0286 packing. Fix: both indirect call sites
> now run declared param types through `abiCoerceDefaultParamType` so the
> call-site signature mirrors the definition (`coerceArg` handles the
> value spill). Same-class mismatch through `abi(.c)` fn pointers is
> tracked separately as issue 0295. Regression test:
> `examples/closures/0319-closures-indirect-call-small-struct-abi.sx`
> (closure + default-conv fn-pointer matrix: packed / wide / HFA params,
> literal + pre-bound args).

## Symptom

Calling a `closure` whose parameter is a small struct passed by value: the
argument's SECOND field reads as 0 inside the closure body. First field is
correct. Pinned example `examples/types/0129-types-tuple-operators.sx`
(section C5.C5, "closure-rstruct") currently FAILS against its golden:
expected `closure-rstruct: 11 22`, actual `11 20` (i.e. `p.y` contributed 0).

Pre-existing on master (verified 2026-07-16 with a clean tree at HEAD =
fd212db0 — NOT introduced by the `Any`→`any` rename work that discovered it).

## Reproduction

```sx
#import "modules/std.sx";

Point :: struct { x: i32; y: i32; }

main :: () {
    off := Point.{ x = 10, y = 20 };
    f := closure((p: Point) -> Point => Point.{ x = p.x + off.x, y = p.y + off.y });
    r := f(Point.{ x = 1, y = 2 });
    print("{} {}\n", r.x, r.y);
}
```

Expected: `11 22`. Actual: `11 20` (`p.y` is 0 in the closure body; the
capture `off` reads fine — `x` path proves capture works, `y` path shows the
PARAM's second field lost).

## Investigation prompt

Suspected origin: fd212db0 ("Fix generic slice-param method calls and
float-target index lowering", 2026-07-16) — its 0288 half changed
`resolveCallParamTypes` so callee declared params give each arg a target
type. A closure call site (`f(Point.{...})`) with a by-value struct literal
arg may now take a different arg-lowering path (target-typed literal →
packing/ABI classification?) that drops or mis-offsets the second field.
Note the struct is 8 bytes ({i32,i32}) — adjacent to the small-struct
packing area of issue 0286 (default-ABI small byte-struct params).

Suggested approach: confirm by building fd212db0~1 and running the repro
(expect `11 22`); then diff the closure-call lowering of the repro between
the two commits (`sx ir` on the repro, look at the trampoline call's arg
materialization). Check both: struct-literal args (`f(Point.{..})`) and
pre-bound locals (`q := Point.{..}; f(q)`) — and widths {i32,i32} vs
{i64,i64} vs {u8,u8} to map the blast radius.

Verification: repro prints `11 22`; `zig build test` green including
`0129-types-tuple-operators` (its golden is CORRECT and must not be
regenerated to the broken value); add the reduced repro as a regression
example under `examples/closures/`.
