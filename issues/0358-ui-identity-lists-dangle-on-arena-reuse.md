# 0358 — the third frame crashes: Ui identity lists dangle on arena reuse

Status: FIXED 2026-07-25 — `Ui.begin_build` detaches its three
per-build lists instead of zeroing their lengths. Regression:
examples/ui/1934-ui-identity-lists-survive-arena-reuse.sx.

## Symptom

Any app whose view tree outgrows the frame arena's first chunk
segfaulted on its THIRD tick, with no input and no state change —
builds 1 and 2 identical and fine:

    tick 1 nodes 218 hits 98
    tick 2 nodes 218 hits 98
    Segmentation fault at address 0xf

The crash surfaced far from the cause, inside layout:

    frame #0: measure_vstack at layout.sx:98
        children.items[i].view.size_that_fits(child_proposal)

— a container child read as garbage, because the build that produced it
had been writing through a dangling pointer.

Reported by Agra from the sudoku game (a 9x9 board plus three control
rows, 218 render nodes). It reproduced with no input at all, which is
what separated it from the router.

## Cause

`Ui` holds three lists that are, by their own comment, "allocated from
the ambient (frame) allocator — never retained across builds":

    chain: List(ChainSegment)
    occ: List(OccCounter)
    seen_keys: List(SeenKey)

`begin_build` reset only their LENGTHS:

    self.chain.len = 0;
    self.occ.len = 0;
    self.seen_keys.len = 0;

so each kept the `items.ptr` / `cap` it was given on the previous build
— pointers into that build's frame arena. The `Ui` lives on the UiRoot
and outlives every arena; its pointers must not.

The frame loop double-buffers, so arena A is reused on tick 3. `Arena`
chunks are a prepend list and `reset` frees everything below the newest
chunk:

    reset :: (a: *Arena) {
        it := a.first.next;
        while it != null { next := it.next; a.parent.dealloc_bytes(it); it = next; }
        a.first.next = null;
        a.end_index = 0;
    }

A tree that fits in one chunk therefore survives the bug — the stale
pointer still addresses live (merely rewound) memory, so builds simply
scribbled where nothing read. A tree that GREW past the first chunk does
not: tick 1's `occ` and `seen_keys` sit in a chunk that tick 3's reset
returns to the parent allocator, and tick 3's `next_occurrence` /
`key_scope` then write into freed memory. Two ticks of latency and a
size threshold are why this survived the UI corpus, whose scenes are
small.

`FrameLoop.tick` already models the rule correctly for the snapshot's
own lists — "the slot's backings died with the arena reset — detach,
never free" — so the fix is to say the same thing here.

## Fix

    self.chain.detach();
    self.occ.detach();
    self.seen_keys.detach();

`detach` nulls ptr, len and cap without freeing, exactly as the snapshot
slots do; the next append allocates fresh from the current arena.

## Note

The general hazard: any structure that outlives a frame arena must
detach, not truncate, every list it filled from that arena. `len = 0`
looks like a reset and behaves like one right up until the arena grows.
`Sink` is safe because it is frame-local and recreated per container;
the store's entries are gpa-owned. Those two plus `Ui` are the only
places that hold lists across a build boundary today.
