# 0306 — `s.(*P)` on a protocol value: ctx recovered AS `*P` — a silent type lie

> **RESOLVED (2026-07-18)** — the `.protocol_to_pointer` emission arm
> (coerce.zig) refuses pointer-to-PROTOCOL pointees with a pointed
> diagnostic naming both honest spellings (the concrete recovery
> `p.(*YourConcrete)` / `p.(*void)`, and `@` to point at the protocol value
> itself); a placeholder typed as the target keeps downstream sane while
> `hasErrors()` aborts the build. Concrete and `*void` recoveries unchanged
> (memory/0845 green). Regression:
> examples/diagnostics/1252-diagnostics-reinterpret-refusals.sx.

## Symptom

The postfix ctx-recovery conversion (`p.(*T)` — recover the typed concrete
pointer from a protocol value) also fires when the pointer target's pointee
is itself a PROTOCOL: `s.(*Sizable)` on `s : Sizable` silently returns the
ctx pointer (which addresses the CONCRETE value, e.g. a `Widget`) bitcast
to `*Sizable`. The result claims to point at a protocol value but points at
concrete bytes. Since e8fd6f74 landed dispatch through `*P`, calling a
method on the lie loads the concrete bytes as `{ctx, type_id, vtable}` —
garbage dispatch.

## Reproduction

```sx
#import "modules/std.sx";
Sizable :: protocol { size :: (self: *Self) -> i64; }
Widget :: struct { value: i64; }
impl Sizable for Widget { size :: (self: *Widget) -> i64 { self.value } }
main :: () {
    w := Widget.{ value = 5 };
    s : Sizable = w;
    pv := s.(*Sizable);          // silently accepted — prints "made: true"
    print("made: {}\n", pv != null);
    // pv.size() would garbage-dispatch through Widget bytes
}
```

Expected: a diagnostic. The ctx recovery is defined for CONCRETE pointees
(`s.(*Widget)` — correct and stays); a pointer-to-protocol target should
refuse: "the ctx recovery yields a pointer to the CONCRETE value — use
`s.(*Widget)`; to lend a view of the protocol value itself, use `@s`".

## Investigation prompt

src/ir/conversions.zig `classifyXX`: the `.protocol_to_pointer` arm
(`getProtocolInfo(src) != null and dst is pointer`) does not inspect the
pointee. Add: when `getProtocolInfo(dst.pointer.pointee) != null`, do NOT
classify as ctx recovery — fall through to a pointed refusal (the postfix
arm's diagnostic site in lower/expr.zig, or a dedicated arm). Keep
`*void` and concrete pointees working exactly as today (pin
memory/0845 exercises them). Verification: the repro diagnoses;
`sx run examples/memory/0845-*.sx` unchanged; `zig build test` green.

## Discovered

2026-07-18, erasure-model stress review, probe SR-P9
(.sx-tmp/sr-p9-proto-to-starP.sx). Pre-existing accept; upgraded from
"inert lie" to "exploitable garbage dispatch" by the landed `*P` slice —
which is why the review probed it.
