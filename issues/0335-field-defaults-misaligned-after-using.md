# 0335 — field defaults are lost on any struct with `#using` before them

> **RESOLVED (2026-07-21).** `registerStructDecl` now builds the defaults
> array IN the layout interleave (null per `#using`-embedded field, the
> declared default at each explicit field's flattened position), matching
> what the generic path already did. Regression: the `align:` leg of
> `examples/modules/0921-modules-nominal-defaults-constants-using.sx`
> (opt 0/3). The open design question below (should base defaults flow
> through `#using`?) stays with Agra — the fix deliberately keeps the
> existing generic-path semantics (they do not).

## Symptom

`Thing :: struct { #using Base; x: i64 = 10; }` — `Thing.{ tag = 1 }.x`
prints `0`, expected `10`.

Observed with the 2026-07-21 tree (post-`5a802a72`). Discovered while
re-deriving issue 0320 (its cross-module default collapse compounds with
this — the zero-fill in that probe was this bug, the cross-bind was 0320's).

## Reproduction

```sx
#import "modules/std.sx";
Base :: struct { tag: i64; }
Thing :: struct { #using Base; x: i64 = 10; }
main :: () -> i32 {
    t := Thing.{ tag = 1 };
    print("x={}\n", t.x);   // prints 0, expected 10
    return 0;
}
```

## Root cause

`registerStructDecl` (src/ir/lower/nominal.zig) stores `sd.field_defaults`
raw — indexed by EXPLICIT field position — while the registered layout and
every literal-lowering consumer index the FLATTENED field list (with
`#using` bases spliced in). After one embedded base field, every
subsequent default is off by the base's field count and falls outside the
array. The generic-instantiation path (src/ir/lower/generic.zig,
`instance_defaults`) already builds the aligned form (null per embedded
field), so generic structs are unaffected.

## Fix (this stream, bundled with the 0320 identity fix)

Build the layout-aligned defaults array in `registerStructDecl` exactly as
the generic path does: null for each `#using`-embedded field, the declared
default at each explicit field's flattened position.

## Open design question (for Agra — NOT decided by the fix)

Should a base's OWN field defaults flow through `#using`
(`Base :: struct { tag: i64 = 5; }` + `#using Base` → does `Thing.{}` get
`tag = 5`)? The fix keeps the current generic-path semantics: embedded
fields have NO defaults. If defaults should flow, that is a deliberate
language-semantics change needing a spec note and its own slice.

## Verification

The repro prints `x=10`; regression folded into
`examples/modules/0921-modules-nominal-defaults-constants-using.sx`
(single-module alignment leg); full corpus green.
