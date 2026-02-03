# 0240 — `List(Tuple(...))` .append segfaults in __platform_memmove

> **RESOLVED (verified 2026-07-10).** Current master correctly instantiates `List(Tuple(...))`; first append and indexed field access round-trip without a layout fault. The consolidated regression keeps this case pinned.

## Symptom

One-line: appending to a `List` instantiated with a named-tuple element
type — `List(Tuple(a: i64, b: bool))` — segfaults inside
`__platform_memmove`; inline and alias spellings alike.

- Observed: segfault at runtime on the first `.append`.
- Expected: the tuple element stores like any struct element.

Pre-existing on master (verified on the pre-0196 parent by the 0196
review, 2026-07-03) — NOT caused by the tuple-alias fix; the generic
instantiation of List with a structural tuple type arg presumably gets
a wrong element size/layout (same family as the 0221 defaults-key gap:
generic instantiation machinery keyed/laid-out off the nominal name).

## Reproduction

```sx
#import "modules/std.sx";

main :: () -> i32 {
    l : List(Tuple(a: i64, b: bool)) = .{};
    l.append(.(a = 1, b = true));      // segfault in __platform_memmove
    print("{}\n", l.items[0].a);
    0
}
```

## Investigation prompt

Instantiate-generic-struct with a STRUCTURAL (tuple) type argument:
check what `instantiateGenericStruct` (src/ir/lower.zig) and the
type-arg resolution do with a `Tuple(...)` type-expr argument — likely
the type arg resolves to a stub/wrong TypeId so `size_of(T)` inside
List's methods (element stride for memmove) is wrong (0 or 1). Probe
`size_of` inside a generic fn with a tuple type arg first to isolate.
Also probe arrays `[3]Tuple(...)`, `Box(Tuple(...))` field layout, and
a tuple type arg via `$T` inference vs explicit. Verify: the repro
prints 1; List of tuples round-trips growth (append past capacity);
corpus green; regression under examples/generics/ (0220 free).

Found by the adversarial review of the issue-0196 fix (2026-07-03),
reproduced on the pre-fix parent.
