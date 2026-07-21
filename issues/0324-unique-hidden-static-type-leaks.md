# 0324 — a unique hidden type leaks through bare static method lookup

> **RESOLVED (2026-07-21).** Bare static-method heads now obey the same
> own/direct-flat visibility boundary as other type positions. The std facade
> intentionally authors `GPA :: mem.GPA`, preserving the supported bare
> `GPA.init()` prelude surface without reviving any other globally unique hidden
> type. Focused negative and positive regressions pass at `--opt 0` and
> `--opt 3`; the combined compiler corpus remains tracked by the compression
> checkpoint.

## Symptom

If `deep.sx` declares `Hidden :: struct { make :: () -> Hidden { .{} } }`,
`bridge.sx` flat-imports `deep.sx`, and `main.sx` flat-imports only
`bridge.sx`, the bare call `Hidden.make()` succeeds whenever `Hidden` has one
process-wide author. A bare type annotation `x: Hidden` is correctly rejected
as not visible. Adding a second hidden `Hidden` author also makes the static
call fail, so visibility currently depends on unrelated global multiplicity.

The fallback is in `src/ir/lower/nominal.zig` (`staticHeadInSource`): its
`.not_visible` arm consults the global type table and returns the unique
author's TypeId.

## Required behavior

- Static method heads obey the same own/direct-flat visibility boundary as
  annotations, literals, aliases, and other type positions.
- A facade that intentionally exposes a type does so with an explicit alias
  (`Public :: internal.Public`), independent of how many hidden declarations
  share the spelling elsewhere in the program.
- Preserve the supported allocator prelude by explicitly re-exporting `GPA`
  from its intended stdlib facade before deleting the compatibility fallback.
- Add negative unique-hidden and positive explicit-re-export regressions.

## Resolution

`staticHeadInSource` now returns `.not_visible` directly when source-aware
nominal selection rejects a name. It no longer consults the process-wide type
table or changes behavior based on whether an unrelated second author exists.

`library/modules/std.sx` explicitly declares `GPA :: mem.GPA`. This is an
ordinary facade-owned alias, so `#import "modules/std.sx"; GPA.init()` remains
valid under the same one-hop rule that governs every other exported type.
`Arena` and codec engine types are not added to the prelude.

Permanent coverage:

- `0906-modules-unique-hidden-static-not-visible` rejects the unique transitive
  `Hidden.make()` leak;
- `0907-modules-explicit-static-reexport` proves that a facade-owned alias
  retains static methods;
- `1725-std-deflater-static-head-hidden` proves nested std codec imports cannot
  revive bare internal `Deflater.init()`;
- `1726-std-gpa-explicit-prelude-reexport` preserves bare `GPA.init()`.

All four examples pass their expected outcomes at both `--opt 0` and
`--opt 3` after a clean `zig build`.
