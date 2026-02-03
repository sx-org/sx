# 0226 — value-position match on a pointer-to-tagged-union subject panics (result-type inference misses the deref)

> **RESOLVED (2026-07-03).** Root cause: `inferMatchResultType`
> (`src/ir/lower/generic.zig`) typed each arm's body with the enclosing scope
> only — an arm payload capture (`case .rect: (v) { v * 2 }`) was never bound,
> so any arm whose value depends on the capture typed `.unresolved`. With a
> pointer subject (and, in fact, with a VALUE subject too whenever EVERY arm
> is capture-dependent — the original writeup's "value subject works" only
> held when some arm was inferable without its capture, e.g. a literal arm)
> the whole match typed `.unresolved`, leaked into the consumer's generic
> instantiation, and panicked at `declareFunction` → `toLLVMType`. Fix: the
> inference now normalizes the subject type exactly as `lowerMatch`'s capture
> path does (pointer-to-tagged-union/enum → pointee) and types each arm with
> its capture bound BY TYPE in a temporary scope (tagged-union variant payload
> / optional child; `Ref.none`, nothing lowered). Repro prints 8; statement
> position and value subjects unchanged. Regression test:
> `examples/types/0802-types-match-pointer-tagged-union-value.sx`.
>
> **Behavioral note (review fold).** Capture-typed FIRST arms now decide the
> match result type. An f64-payload match whose first arm is the capture and
> whose later arm is an int literal (`case .x: (a) { a } else: { 0 }`) used
> to type i64 off the literal arm and silently truncate the payload (baseline
> printed `2` for a `2.5` payload); it now types f64 and prints `2.500000`.

## Symptom

One-line: `r := if p == { case ... }` where `p` is a POINTER to a tagged
union panics `unresolved type reached LLVM emission` (via
`declareFunction`) — the same match in STATEMENT position works, and a
value subject works in both positions.

- Observed: exit 134 panic, no diagnostic.
- Expected: `r` gets the arms' common type (pointer subjects auto-deref
  for tagged unions — the capture path already handles this correctly).

The capture/arm lowering post-deref is fine; the leak is the match
RESULT-TYPE inference (`inferMatchResultType`) not dereferencing pointer
subjects, so the `if`-expression's unresolved type flows into the
consumer (e.g. the generic `print` instantiation's param type) and
reaches `declareFunction → toLLVMType`.

Pre-existing on master (verified on the baseline BEFORE the issue-0163
fix commits via stash by the 0163 fold worker, 2026-07-03).

## Reproduction

```sx
#import "modules/std.sx";
Shape :: enum { circle: i64; rect: i64; }
main :: () {
    s : Shape = .rect(4);
    p := @s;
    r := if p == { case .circle: (v) { v } case .rect: (v) { v * 2 } };  // panic
    print("{}\n", r);   // expected 8
}
```

Statement position (`if p == { case .rect: (v) { print("{}\n", v); } }`)
works — that isolates the result-type path.

## Investigation prompt

In `src/ir/lower/control_flow.zig`, the match lowering auto-derefs a
pointer-to-tagged-union subject for tag computation and captures, but
`inferMatchResultType` (or whichever path types the `if == { case }`
EXPRESSION result) types the arms against the RAW subject type — for a
pointer subject the arm/payload types come out `.unresolved` and the
whole match-expression type leaks unresolved to consumers. Mirror the
subject-deref the capture path performs before inferring arm types (find
where the subject type is normalized — tagged-union pointee — and route
the result-type inference through the same normalization). Verify: the
repro prints 8, exit 0; statement position unchanged; value subjects
unchanged; `else:` arms + mixed-type arms diagnose as they do for value
subjects; regression example under examples/types/ or an extension of an
existing match example. Full corpus green.

Found by the issue-0163 fold worker's probing (2026-07-03); reproduced
on the pre-0163 baseline.
