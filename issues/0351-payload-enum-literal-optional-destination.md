# 0351 — payload-carrying enum literal fails against an optional destination

Status: FIXED 2026-07-23 — both resolution sites in the enum-literal
call path (the `.Variant(payload)` target check and the arg-lowering
payload-type derivation) now resolve through optional layers, exactly
as the bare-literal path has since issue 0098. Regression:
examples/optionals/0928-optionals-payload-enum-literal.sx.

## Symptom

A bare enum literal resolves against `?E` (`return .quit;` with
`-> ?E` works), but a PAYLOAD-carrying literal call does not — in
every destination position:

    E :: enum { quit; resize: f32; pair: P; }

    r :: () -> ?E { return .resize(1.5); }        // FAILED
    x : ?E = .resize(2.5);                        // FAILED
    take(.resize(3.5));                           // ?E param — FAILED

    error: cannot infer enum type for '.resize' — use an explicit
    type or assign to a typed variable

With an anonymous struct payload the failure shifted into the payload:
`.pair(.{ a = 1.0 })` against `?E` resolved the INNER literal against
E and reported "'a' is not a variant of 'E'".

## Cause

Two sites in `src/ir/lower/call.zig` checked `target_type` for
`.tagged_union` directly, so a `?E` destination (`.optional` wrapping
the union) fell through: the construction-target block, and the
earlier `enum_payload_ty` derivation that types anonymous payload
literals. The bare-literal path (`expr.zig`, issue 0098) already
unwraps optional layers in a loop.

## Fix

Mirror the 0098 while-unwrap at both sites: resolve through optional
layers to the tagged union; the constructed value wraps into the
optional at the ordinary coercion site.

## Found

Migrating platform hosts onto `?PlatformEvent` (G2 2d):
`translate_sdl_event`'s body had never been lowered by the corpus
(lazy lowering — no in-repo caller), so the shape survived the gates
until an out-of-tree consumer would have hit it.
