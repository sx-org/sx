# 0243 — `$T`-sigil spelling rejected as a reflection-builtin argument

> **RESOLVED (2026-07-10).** Per the generic syntax specification, `$` is declaration-site-only. Reflection calls now diagnose the use-site sigil directly and tell the author to write the bare parameter name.

## Symptom

One-line: `sz :: ($T: Type) -> i64 { return size_of($T); }` fails with
"size_of expects a type, got 'unresolved'" while the bare spelling
`size_of(T)` works in the identical context.

- Observed: the `$T` sigil form of a bound type param is rejected by the
  reflection builtins (size_of, and presumably align_of / field_count /
  field_name — probe all).
- Expected: `$T` and `T` refer to the same binding inside the fn body;
  both spellings should resolve (or, if `$` is declaration-site-only
  syntax by spec, the diagnostic should say THAT — "use 'T' to refer to
  the type parameter" — not "got 'unresolved'").

Pre-existing and independent of struct defaults (repros with no struct
at all). Found by the issue-0221 fix worker (2026-07-04): its
dependent-default monomorphization works for `size_of(T)` but the
`size_of($T)` spelling in a default expr hits the same rejection.

## Reproduction

```sx
#import "modules/std.sx";

sz :: ($T: Type) -> i64 { return size_of($T); }   // error: size_of expects a type, got 'unresolved'
szb :: ($T: Type) -> i64 { return size_of(T); }   // works

main :: () -> i32 {
    print("{}\n", szb(i64));   // 8
    print("{}\n", sz(i64));    // expected 8, or a spec-correct diagnostic
    0
}
```

## Investigation prompt

FIRST check specs.md §generics for whether `$name` is legal in USE
position (the `$` marks the binding declaration; body uses may be
defined as bare-name-only). If use-position `$T` is legal: the
classification helpers `reflectionArgIsType` / `isStaticTypeArg`
(src/ir/lower/call.zig ~2492, src/ir/lower/generic.zig ~249) mis-handle
the `.type_expr { is_generic = true }` node the parser produces for
`$T` — route it through the same binding lookup the bare spelling uses
(cf. the issue-0156 Part-1 fix, which handled the comptime_pack_ref
analog in resolveTypeWithBindings). If it's NOT legal: improve the
diagnostic to name the fix ("'$' marks the parameter declaration; write
'size_of(T)'") and apply it consistently across all reflection
builtins and type-arg positions (`Box($T)` inside a body — probe).
Verify: the repro either prints 8 twice or gives the targeted
diagnostic; all reflection builtins probed; corpus green; regression
example under examples/generics/ or diagnostics/ per the decision.

Found by the issue-0221 fix worker (2026-07-04).
