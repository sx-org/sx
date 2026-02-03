# 0238 — spreading a comptime pack into a slice-VARIADIC fn fails "unresolved 'spread_expr'"

> **RESOLVED (2026-07-04)** — fixed by the issue-0156 Part 2 landing
> (`fix(ir): issue 0156p2 — value spread is real`): the pack-fn call-site
> AST expansion (`expandSpreadArgNodes`, src/ir/lower/pack.zig) now
> expands pack spreads before the variadic boxing, so
> `print("{} {}\n", ..xs)` inside a pack fn works. Verified on master
> post-landing (prints "1 two"); pinned by
> examples/packs/0830-packs-runtime-tuple-spread.sx and the 0156p2
> adversarial review (its probe matrix covered two-hop pack forwarding).


## Symptom

One-line: inside a pack fn (`show :: (..xs: $T)`), forwarding the pack
into a slice-variadic callee — `print("{} {}\n", ..xs)` — fails with
"unresolved 'spread_expr'" plus cascading pack-index-OOB errors from
fmt.sx; the comptime-pack → slice-variadic forwarding path doesn't
compose.

- Observed: "unresolved 'spread_expr'" + cascade.
- Expected: the pack elements expand positionally into the variadic
  callee (the same expansion a direct call site gets), boxed into the
  variadic slice as usual.

## Reproduction

```sx
#import "modules/std.sx";

show :: (..xs: $T) {
    print("{} {}\n", ..xs);    // error: unresolved 'spread_expr' + cascade
}

main :: () {
    show(1, 2);
}
```

## Investigation prompt

The pack-spread lowering (src/ir/lower/pack.zig — lowerPackElems /
spread handling) expands `..xs` at plain call sites, but when the callee
is slice-VARIADIC the arg pipeline (packVariadicCallArgs in the same
area, recently guarded by the issue-0188 fix) receives the un-expanded
spread node — trace where a pack spread inside a pack-fn body meets the
variadic boxing and which side should expand first (pack expansion
before variadic packing is the natural order). Mind the 0188 guards
(AST/lowered-arg alignment) — extend them rather than bypassing.
Verify: the repro prints "1 2"; nested pack-fn → pack-fn → print chains
work; non-variadic pack forwarding (`worker(..xs)`) unchanged; corpus
packs suite green; regression under examples/packs/ (0831 free).

Found by the issue-0188 fix worker (2026-07-03). Base on master after
the 0188 landing (same files).
