# 0348 — duplicate `#objc_class` decls for one runtime class race the name-keyed registry silently

Status: RESOLVED 2026-07-22

## Resolution

`upsertRuntimeClass` (src/ir/lower/ffi.zig) replaces both raw
`runtime_class_map.put` sites. Extern declarations are C-header-like
per-module views: same sx name + same runtime binding MERGE into a
union surface (a synthesized decl with the member union — every
consumer sees it through the map, so no per-consumer source-awareness
was needed). Genuine conflicts diagnose, naming both source files:
different runtime bindings under one sx name, any sx-defined (export)
duplicate, same-name methods differing in static-ness/arity/#selector,
duplicate fields, and disagreeing #extends. Re-scans are idempotent
(no-op merges keep the existing entry).

Pins: examples/modules/1622 (union — both views' calls resolve on one
value; the CAMetalLayer race shape) and examples/modules/1623
(conflicting bindings reject). The existing corpus exercises the merge
too: ffi-objc/1317 redeclares NSObject (alloc/init) against objc.sx's
view — identical methods dedup rather than conflict. Method equality
is (name, arity, #selector); static-ness is deliberately NOT compared —
it derives from the `*Self` spelling (`self: *NSObject` vs
`self: *Self` are both instance receivers), and a true static/instance
pair already differs in arity (statics carry no self param). Note
ffi/quartzcore.sx STAYS — one decl per runtime class remains the
better layering; the compiler just no longer forces it.

## Symptom

Two modules each declaring `#objc_class("SameRuntimeName")` (different
sx decl names or the same) race for the program-wide name-keyed
runtime-class registry slot. Whichever loses resolves member calls
against the OTHER declaration's method surface — with no diagnostic.
The failure appears at the losing module's call sites as "unresolved
'<method>'" (best case) or dispatches a selector the winner declared
with a different signature (worst case, silent ABI mismatch).

## Observed instance

gpu/metal.sx grew its own `CAMetalLayer` declaration while
platform/uikit.sx already had one (`#extends CALayer` + `class`).
An example importing both (platform/1606) failed with:

    error: unresolved 'class' (in library/modules/platform/uikit.sx fn SxMetalView.layerClass)
      --> library/modules/platform/uikit.sx:906:25
      |  layerClass :: () => CAMetalLayer.class();

— uikit's own `CAMetalLayer.class()` resolved against metal.sx's decl
(no `#extends`, no `class`). Worked around structurally: the shared
declaration moved to modules/ffi/quartzcore.sx and both consumers
import it (the right layering anyway — one decl per runtime class).

## Expected

Either module-scoped resolution (each module's member calls resolve
against its own declaration — extern surface decls are C-header-like
and per-module views of one runtime class are legitimate), or a loud
duplicate-declaration diagnostic naming both modules. Silence is the
bug.

## Suspected area

The name-keyed runtime-class maps populated by
`registerRuntimeClassDecl` (src/ir/lower/decl.zig) and consumed by
member resolution — same "name-keyed program-wide map + first/last
wins" class as issue 0346's impl registry.

## Impact

Any two modules independently binding the same Obj-C class can break
each other at a distance. Low urgency in-repo (quartzcore.sx now owns
the shared layer decls) but a footgun for app code.
