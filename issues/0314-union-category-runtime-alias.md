# 0314 — runtime `case union:` silently aliases `enum`; classifiers disagree on the `union` category

> **RESOLVED** (2026-07-18, same day, Agra-ruled). Root cause: the
> name→category mapping in `resolveTypeCategoryTags`
> (src/ir/lower/generic.zig) folded `"union"` into `.@"enum"`, leaving
> the correct `.@"union"` arm unreachable by name. Fix: `"union"` maps
> to its own category (untagged + tagged unions, mirroring the static
> classifier), and the TYPE-category match lowering
> (src/ir/lower/control_flow.zig) gained the any-switch's first-wins
> claim set + loud unreachable-arm error — before it, ANY overlapping
> arms (including the alias's own `enum`+`union`) were an LLVM
> duplicate-switch-case verifier crash. Regression tests:
> `examples/types/0888-types-type-match-union-category.sx` (runtime +
> static agreement, first-wins, concrete-before-category, boxing) and
> `examples/diagnostics/1257-diagnostics-type-match-unreachable-arm.sx`
> (the loud error). specs §Type Category Matching updated (union in the
> list; the stale "not registered" note replaced with the first-wins
> discipline). Rider discovered while verifying, filed separately:
> issue 0315 (builtin concrete arms silently dead in the type match).

## Symptom

In RUNTIME type dispatch (the type-category match on a `Type` value and
the `any`-subject type switch), the category name `"union"` resolves to
the **enum** tag set — `case union:` matches payload-less enums and
tagged unions, and does NOT match C-style untagged unions. The STATIC
classifier (`inline if T ==` over a bound generic param) gives `union`
its own meaning: untagged unions + tagged unions. The two classifiers
disagree in both directions, violating their documented mirror
invariant ("the static fold and the runtime tag switch can never
disagree on what a category means"):

| value's type            | static `case union:` | runtime `case union:` |
|-------------------------|----------------------|-----------------------|
| untagged `union {…}`    | matches              | does NOT match        |
| plain `enum {…}`        | does NOT match       | **matches**           |
| tagged union (payload)  | matches              | matches               |

Observed vs expected: `check(type_of(tu))` below answers `"other"`
(expected `"union"`), and swapping the arm to `case union:` over a plain
enum's type answers `"union"` (expected `"other"`).

## Reproduction

```sx
#import "modules/std.sx";

TU :: union { i: i64; f: f64; }     // C-style untagged union
E  :: enum { a; b; }                // plain enum

check :: (t: Type) -> string {
    if t == {
        case union: return "union";
        else:       return "other";
    }
    "unreached"
}

main :: () {
    tu := TU.{ i = 5 };
    print("untagged: {}\n", check(type_of(tu)));   // "other"  — expected "union"
    print("enum:     {}\n", check(type_of(E.a)));  // "union"  — expected "other"
}
```

The static side (correct today, the mirror target):

```sx
kind :: (x: $T) -> string {
    inline if T == {
        case union: return "union";
        else:       return "other";
    }
}
// kind(tu) → "union"; kind(E.a) → "other"
```

## Suspected area

`src/ir/lower/generic.zig`, `resolveTypeCategoryTags` — the name→category
mapping folds both spellings into one arm:

```zig
else if (std.mem.eql(u8, name, "enum") or std.mem.eql(u8, name, "union"))
    .@"enum"
```

so the `Category.@"union"` variant (whose match arm is correct:
`info == .@"union" or info == .tagged_union`) is unreachable by name.
The static classifier (`src/ir/lower/comptime.zig`,
`staticTypeMatchesCategory`) maps the two names separately and is the
reference behavior.

## Fix sketch + open decision

Map `"union"` to `.@"union"` so the runtime sets mirror the static ones.
Two riders to decide/handle:

1. **Overlap**: `enum` and `union` both include `.tagged_union`. The
   `any`-subject type switch has a first-wins `claimed` set, so mixed
   `case enum:` + `case union:` arms are fine there; the TYPE-category
   match path (`is_type_match`, control_flow.zig ~1365) has NO claim
   set — two arms listing the same tag would emit duplicate switch
   cases. Verify what the backend does with the duplicate today (the
   current alias already makes `case enum:` + `case union:` produce
   identical sets!) and add first-wins claiming to the type-match path
   if needed.
2. **Docs**: specs §Type Category Matching deliberately omits `union`
   from the available list and notes untagged unions "are not registered
   with the any type system and cannot be matched by category" — the
   concrete-name arm DOES match an untagged union's tag at runtime
   (verified), so that note wants re-examination in the same pass.
   §Type Switch's category list DOES name `union` — align both with
   whatever the ruling is.

This is a **user-visible semantics change** (runtime `case union:` stops
matching plain enums): Agra's call on landing it.

## Investigation prompt

> In ~/projects/sx: fix issue 0314. `resolveTypeCategoryTags`
> (src/ir/lower/generic.zig) maps the name "union" to the `.@"enum"`
> category, so runtime `case union:` matches enums and misses untagged
> unions — the static classifier (`staticTypeMatchesCategory`,
> src/ir/lower/comptime.zig) is the reference: `union` = `.union` +
> `.tagged_union`. Map "union" to `.@"union"`, then handle the
> enum/union overlap on `.tagged_union` in the TYPE-category match
> lowering (control_flow.zig ~1365), which unlike the any-switch path
> has no first-wins claim set — check for duplicate switch cases and add
> claiming if the backend doesn't tolerate them. Re-run the repro above
> (expect untagged→"union", enum→"other"), pin it as a types/ example,
> and align specs §Type Category Matching (the omitted `union` +
> the "not registered" note) and §Type Switch's category list with the
> landed behavior.
