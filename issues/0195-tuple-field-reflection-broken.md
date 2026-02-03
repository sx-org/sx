# Issue 0195 — `field_count` / `field_name` broken on tuple types (silent 0 + segfault)

> **RESOLVED.** Fixed across both the lowering count switches and the LLVM backend. Root cause as
> diagnosed below: `field_count`/`memberCount` had no `.tuple` arm (silent 0), and the backend's
> `field_name_get` emission built a **zero-length** name array for any non-struct/enum kind while
> sizing its GEP at the real count → out-of-bounds GEP → segfault.
>
> **Scope broadened during adversarial review:** the same defect was live for `.array` / `.vector`
> (`field_count([4]i64)` returned 4 but `field_name([4]i64, 0)` segfaulted — an exact clone). Rather
> than patch each kind in each of the (then three) parallel count switches, the backend was unified to
> derive BOTH the name-array build (`getOrBuildFieldNameArray`, `src/backend/llvm/reflection.zig`) AND
> the GEP sizing (`emitFieldNameGet`, `src/backend/llvm/ops.zig`) from the **single source of truth**
> `TypeTable.memberCount` / `memberName` — so the array length and the GEP type can never disagree
> again, for any kind. Members with no name (positional-tuple / array / vector elements) reflect as
> `""` (one slot per member, always in-bounds); named-tuple elements recover their labels.
>
> **Fix sites:** `src/ir/lower/call.zig` (`field_count` `.tuple` arm) · `src/ir/types.zig`
> (`memberCount` `.tuple` arm) · `src/backend/llvm/reflection.zig` + `src/backend/llvm/ops.zig`
> (unified to `memberCount`/`memberName`). The COMPILER-API VM readers (`type_field_count` /
> `type_field_name`, `src/ir/comptime_vm.zig`) ride the same `memberCount`/`memberName` and now report
> tuples correctly (positional `type_field_name` still fails loud via `failMsg`, not a crash).
> Delivered via the worker-fix override; adversarially reviewed (the review surfaced the array/vector
> clone). Regression: `examples/comptime/0646-comptime-field-reflect-tuple-array.sx` (struct / enum /
> positional + named tuple / array / vector). Full suite green.
>
> Original writeup below.

---

Status: **(historical — see RESOLVED banner).** Hit while building `race` (the A1 async deliverable),
whose comptime tuple→tagged-union synthesis must reflect the input named tuple's labels + element
types. The reflection builtins are inconsistent across tuple types: `field_type` works, but
`field_count` silently returns 0 and `field_name` segfaults.

## Symptom

The comptime reflection `#builtin`s (`field_count` / `field_name` / `field_type`, declared in
`library/modules/std/core.sx`) behave correctly on structs/enums but are broken on **tuple** types —
even though `field_type`'s own doc (meta.sx) says it returns "the i-th field / variant-payload /
**element** type", i.e. tuples are meant to be covered:

| builtin | on `struct {a:i64; b:bool}` | on `Tuple(i64, bool)` | expected on tuple |
|---|---|---|---|
| `field_count(T)`     | `2` ✓ | **`0`** ✗ (silent wrong default) | `2` |
| `field_type(T, i)`   | `i64`/`bool` ✓ | `i64`/`bool` ✓ | (correct) |
| `field_name(T, i)`   | `a`/`b` ✓ | **SEGFAULT** ✗ | the label for a named tuple (`a`/`b`), or empty/`null` for a positional tuple |

`field_count` returning 0 is the classic forbidden silent-default (CLAUDE.md "Silent unimplemented
arms"): callers that trust the count then index out of range — which is almost certainly why
`field_name(tuple, 0)` segfaults (it is reached with a count the caller believes is 0, or the
field-name path itself lacks the tuple case).

## Root cause (located)

`field_type` works because `TypeTable.memberType` **has** a `.tuple` arm
(`src/ir/types.zig:585` — `.tuple => |t| if (i < t.fields.len) t.fields[i] else null`).

`field_count` is broken because its lowering has a hardcoded switch with **`else => 0`** and **no
`.tuple` arm**:

```zig
// src/ir/lower/call.zig:2187-2200  (field_count(T) → const_int(N))
const count: i64 = switch (info) {
    .@"struct" => |s| @intCast(s.fields.len),
    .@"union" => |u| @intCast(u.fields.len),
    .tagged_union => |u| @intCast(u.fields.len),
    .@"enum" => |e| @intCast(e.variants.len),
    .array => |a| @intCast(a.length),
    .vector => |v| @intCast(v.length),
    else => 0,                       // ← tuple falls here → silently 0
};
```

`TypeTable.memberCount` (`src/ir/types.zig:525-536`) has the **same gap** — it lists struct / union /
tagged_union / enum / array / vector then `else => null`, with no `.tuple` arm. (`memberCount` backs
the `abi(.compiler)` `type_field_count` VM reader, so the COMPILER-API reflection path is silently
wrong on tuples too, not just the `#builtin`.)

`field_name` lowering is at `src/ir/lower/call.zig:2299` (emits a `field_name_get` instruction).
`memberName` (`src/ir/types.zig:561-569`) DOES have a `.tuple` arm (returns `t.names[i]` if the tuple
is named, else null), so the segfault is in the `field_name_get` runtime/emit path for tuples (or a
downstream consequence of the bogus count) — to be confirmed during the fix.

## Reproduction

```sx
#import "modules/std.sx";

main :: () -> i32 {
    // tuple field_count silently returns 0 (should be 2):
    print("tuple field_count = {}\n", field_count(Tuple(i64, bool)));   // prints 0

    // tuple field_type works fine:
    print("tuple field_type 0 = {}\n", type_name(field_type(Tuple(i64, bool), 0)));   // i64

    // tuple field_name SEGFAULTS (comment the line above out is not needed; this alone crashes):
    print("tuple field_name 0 = {}\n", field_name(Tuple(a: i64, b: bool), 0));   // SIGSEGV

    return 0;
}
```

Baseline (works): the same three builtins on `S :: struct { a: i64; b: bool; }` print `2`, `a`/`b`,
`i64`/`bool` correctly. `type_info(Tuple(...))` also already reflects a tuple correctly (see
`examples/comptime/0623-comptime-metatype-tuple.sx`), so the type table fully knows the tuple's
elements — only `field_count` / `field_name` drop the tuple case.

## Investigation prompt (ready to paste)

> The comptime reflection builtins `field_count` / `field_name` are broken on tuple types:
> `field_count(Tuple(i64, bool))` returns 0 instead of 2, and `field_name(Tuple(a: i64, b: bool), 0)`
> segfaults. `field_type` already works on tuples. Make `field_count` / `field_name` cover tuples the
> same way `field_type` does, including named-tuple labels.
>
> Fixes, in order:
> 1. **`src/ir/lower/call.zig:2187-2200`** (`field_count` lowering): the `switch` over the type info
>    has `else => 0` and no `.tuple` arm. Add `.tuple => |t| @intCast(t.fields.len)`. (Replacing the
>    `else => 0` silent default with a loud `else => @panic`/diagnostic for genuinely-unsupported kinds
>    would also surface the next such gap, per CLAUDE.md's anti-silent-default rule.)
> 2. **`src/ir/types.zig:525-536`** (`TypeTable.memberCount`): same missing `.tuple` arm — add
>    `.tuple => |t| @intCast(t.fields.len)`. This backs `type_field_count` (the COMPILER-API VM
>    reader), so it is silently 0 on tuples too. Verify with a comptime `type_field_count` probe.
> 3. **`field_name` segfault**: `src/ir/lower/call.zig:2299` emits a `field_name_get` instruction;
>    `TypeTable.memberName` (`src/ir/types.zig:561-569`) already handles tuples (named → label, else
>    null). Find where the `field_name_get` path for a tuple faults — likely it indexes assuming a
>    struct/enum layout, or is reached with the bogus 0 count from bug (1). A positional tuple has no
>    names → decide the contract (return empty string `""`? a diagnostic?) and make it not crash.
>    A named tuple must return the label (`a`/`b`).
>
> Verification: the reproduction above prints `tuple field_count = 2`, `tuple field_type 0 = i64`,
> `tuple field_name 0 = a` (named) — no segfault. Add a regression example under
> `examples/comptime/` exercising `field_count` / `field_name` / `field_type` on both a positional and
> a named tuple. Then the blocked `race` synthesis (reflect a named tuple of task handles → mint a
> tagged-union with the tuple's labels as variant names) can proceed.

## Why this blocks `race`

`race((a: fa, b: fb))` must, at comptime, read the input named tuple's field **labels** (`a`, `b`) to
name the synthesized `RaceResult` union's variants, and each element **type** to set the variant
payloads. `field_type` already gives the types, but without a working `field_count` (how many arms)
and `field_name` (the labels) the named-tuple synthesis cannot be written. The type-construction side
(`declare`/`define`/`make_enum`) and struct/enum reflection are all proven working
(`examples/comptime/0619-0623`); tuple field reflection is the one missing piece.
