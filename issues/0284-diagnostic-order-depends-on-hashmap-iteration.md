# 0284 — diagnostic emission order depends on hashmap iteration order

## ✅ RESOLVED

`convergeInferredErrorSets` now collects the `work` entries, sorts them by source
span (name as tiebreak, so the order is total even for entries with no return-type
node), and emits from the sorted list. Warnings come out top-to-bottom:

```
source order:   alpha bravo charlie delta echo_fn foxtrot golf hotel
warning order:  alpha bravo charlie delta echo_fn foxtrot golf hotel   (was: hotel foxtrot echo_fn golf delta bravo alpha charlie)
```

Behaviour-neutral when it landed — [[0283]] means these warnings never render, and
the corpus emits zero warnings even with rendering forced on, so there was nothing
observable to change. That was the point: **it disarms the trap before it can fire.**
[[0283]] is now safe to fix on its own, by anyone, with no ordering fallout.

Regression test: `src/ir/error_analysis.test.zig` — "empty-inferred warnings are
emitted in source order, not hashmap order". Asserts on the `DiagnosticList`
directly, so it works despite [[0283]]; it fails on the pre-fix tree.

The `inferred_error_sets.put` in the same loop was always order-insensitive (it is
a map); only the diagnostic emission cared.

## Symptom

`ErrorAnalysis.convergeInferredErrorSets` emits diagnostics from **inside a
`std.StringHashMap` iteration**, so the order of the emitted warnings is hash
order, not source order:

```zig
// src/ir/error_analysis.zig (convergeInferredErrorSets)
var sit = work.iterator();          // ← StringHashMap iteration order
while (sit.next()) |se| {
    const sorted = self.l.alloc.dupe(u32, se.value_ptr.tags.items) catch continue;
    std.mem.sort(u32, sorted, {}, std.sort.asc(u32));   // sorts TAGS, not the outer order
    ...
    diags.addFmt(.warn, rt.span, "function '{s}' is declared `!` but never errors ...");
}
```

The `std.mem.sort` on line 175 sorts the error *tags within* each set. The
**outer** loop — the one that decides diagnostic order — is unsorted.
`errors.zig` never sorts either, so insertion order *is* output order.

## Reproduction

Requires [[0283]] to be fixed first (warnings are otherwise invisible). With
rendering temporarily enabled:

```sx
#import "modules/std.sx";

alpha :: () -> ! { return; }
bravo :: () -> ! { return; }
charlie :: () -> ! { return; }
delta :: () -> ! { return; }
echo_fn :: () -> ! { return; }
foxtrot :: () -> ! { return; }
golf :: () -> ! { return; }
hotel :: () -> ! { return; }

main :: () -> ! {
    try alpha(); try bravo(); try charlie(); try delta();
    try echo_fn(); try foxtrot(); try golf(); try hotel();
    print("done\n");
}
```

```
source order:   alpha bravo charlie delta echo_fn foxtrot golf hotel
warning order:  hotel foxtrot echo_fn golf delta bravo alpha charlie
```

## Why it matters

Diagnostics should be reported in source order — scrambled order is poor UX on
its own. But the sharper reason is the **Odin port** ([[../PORT_PLAN.md]]): Zig's
`StringHashMap` and Odin's `map` do not share a hash function, so a faithful,
correct transliteration would emit these warnings in a *different* order. The
differential oracle would flag it as a port defect when nothing is wrong.

Audited the other 70 hashmap iteration sites: this is the only one that leaks
order into output. The rest either accumulate into sets (order-insensitive, e.g.
`semantic_diagnostics.zig:398-406`) or sort their results. IR emission order was
verified to follow **source** order, not hash order — so codegen is unaffected.

## Fix sketch

Collect the entries into a list, sort by source span (`rt.span`), then emit —
the same shape `imports.zig:1161` and `lsp/document.zig:99` already use to
neutralise directory-read order.

## Status

OPEN — filed during the pre-port stress sweep. **Latent today**, masked entirely
by [[0283]]: the order can't be observed because the warnings never render. The
trap arms itself the moment [[0283]] is fixed, so fix both together.
