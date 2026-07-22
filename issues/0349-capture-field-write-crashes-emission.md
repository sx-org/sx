# 0349 — field write through a by-value for-capture crashes LLVM emission instead of diagnosing

Status: OPEN (found converting ui/router.sx loops to `for`, 2026-07-23)

## Symptom

Issue 0219 made by-value captures immutable, with a shape-aware
diagnostic — but the guard catches only BARE reassignment (`x = v`).
A FIELD write through a by-value element capture slips past it and
dies in codegen:

    error: LLVM emission failed for struct_gep in '<fn>': cannot
    resolve aggregate type for base ref %N; IR must provide base_type
    or recoverable aggregate pointer metadata

Reproduces for every container shape: fixed array, slice, `List(T)`
(local or through `self`), with or without a paired index range.

## Repro

    #import "modules/std.sx";
    Item :: struct { n: i64 = 0; }
    main :: () {
        arr : [2]Item = .[.{ n = 1 }, .{ n = 2 }];
        for arr (e) { e.n = e.n + 10; }   // ← should be the 0219 error
        print("{}\n", arr[0].n);
    }

## Expected

The 0219 diagnostic, extended to field writes: a by-value capture is a
read-only alias — suggest `(*x)` for the for-element shape (write
through the pointer), copy-into-a-`:=`-local otherwise. `for arr (*e)
{ e.n += 10; }` is the correct spelling and WORKS today.

## Actual

Compiler-crash-grade emission failure naming IR internals.

## Note

specs.md carried a stale paragraph directly contradicting 0219 ("the
element capture is a direct alias — field writes go to the original")
— removed in the same change that filed this. The misleading text is
how the broken spelling got written in the first place.

## Suspected area

The 0219 immutability guard (assignment checking) — it tests the
assignment TARGET for being a capture binding but not a capture-rooted
field path; the unchecked struct_gep on a by-value element ref then
reaches emit_llvm without aggregate metadata (emit_llvm.zig:1918).
