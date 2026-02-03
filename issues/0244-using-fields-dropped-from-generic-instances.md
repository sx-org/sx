# 0244 — `#using` fields are dropped from generic struct instantiations

> **RESOLVED (2026-07-10).** Generic struct instantiation now expands the template's `#using` entries and keeps field-default slots aligned with the expanded layout.

## Symptom

One-line: a generic struct with a `#using` field loses it on
instantiation — accessing the using-field (or its splice-through
members) on `Box(i64)` fails "field 'bx' not found", while the same
`#using` on a non-generic struct works.

- Observed: `error: field '<name>' not found` on the instance (identical
  pre- and post-issue-0221 fix — pre-existing).
- Expected: instantiation carries `#using` fields and their spliced
  member set like a non-generic struct.

Mechanism (from the 0221 review's investigation):
`instantiateGenericStruct` (src/ir/lower/generic.zig) builds the
instance's fields only from `tmpl.field_names` and never expands
`using_entries`.

## Reproduction

```sx
#import "modules/std.sx";

Base :: struct { bx: i64 = 1; }
Box :: struct($T: Type) { item: T; #using base: Base; }

main :: () -> i32 {
    b : Box(i64) = .{ item = 5, base = .{} };
    print("{}\n", b.bx);      // error: field 'bx' not found (via #using splice)
    print("{}\n", b.base.bx); // probe the direct field too
    0
}
```

(Adjust the `#using` spelling to whatever specs.md §structs defines —
probe a working non-generic `#using` example first, e.g. grep the
corpus for `#using`, and mirror its shape exactly.)

## Investigation prompt

In `instantiateGenericStruct` (src/ir/lower/generic.zig), mirror
whatever the non-generic decl path does with `using_entries` (find it
in src/ir/lower/nominal.zig — the struct registration that populates
the splice/member-forwarding tables) so the instance registers the same
using expansion, with type args substituted if a using-field's type
mentions `$T` (`#using base: Wrapper(T)` — probe that shape too). Mind
the issue-0221 defaults machinery (field_defaults index-aligned with
field_names): if using expansion ADDS fields to the instance, keep the
defaults alignment intact — coordinate with the 0221 landing.
Verify: the repro prints 1 twice; non-generic #using unchanged; nested
using-in-generic-in-generic probed; corpus green; regression under
examples/generics/.

Found by the adversarial review of the issue-0221 fix (2026-07-04).
