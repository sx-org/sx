# 0253 — qualified variant construction with an anonymous struct payload fails

## Symptom

One-line: `Event.key_up(.{ key = .escape })` — the QUALIFIED spelling of
a tagged-union variant construction with an anonymous struct payload —
fails with `'key' is not a variant of 'Event'` plus a cascading
`unresolved 'key_up'`; the UNQUALIFIED `.key_up(.{ key = .escape })`
form works.

- Observed: two bogus diagnostics; the qualified form is unusable for
  anonymous-payload variants.
- Expected: `Type.variant(payload)` behaves exactly like
  `.variant(payload)` with the type made explicit.

Pre-existing (A/B-verified on master by the issue-0191 fix worker,
2026-07-04).

## Reproduction

```sx
#import "modules/std.sx";

Key :: enum { escape; space; }
Event :: enum {
    key_up: struct { key: Key = .space; };
    quit;
}

main :: () -> i32 {
    e1 : Event = .key_up(.{ key = .escape });      // works
    e2 := Event.key_up(.{ key = .escape });        // error: 'key' is not a variant of 'Event' + unresolved 'key_up'
    _ := e1; _ := e2;
    0
}
```

## Investigation prompt

The qualified path routes through a different call arm than the
enum-literal-callee path (src/ir/lower/call.zig — the unqualified
`.key_up(...)` hits the variant-payload arm the 0191 fix touched at
~1399; the qualified `Event.key_up(...)` presumably resolves
field_access-callee → misclassifies the anonymous literal's field
`key` as a variant name of Event). Find where the qualified spelling
dispatches and route it to the same variant-construction machinery.
ALSO fold (from the 0191 worker's report): two sibling variant-payload
sites at call.zig ~827 and ~955 (instantiateTypeFunction paths) still
compute the coercion SOURCE type via `inferExprType(c.args[0])` — the
phantom-src pattern the 0191 fix corrected at ~1399 (use
getRefType(payload) instead); they're untriggerable until this bug is
fixed, so fix them together. Verify: both spellings construct equal
values; payload defaults apply; probe nested/enum payloads; corpus
green; regression under examples/types/ or generics/.

Found by the issue-0191 fix worker (2026-07-04); pre-existing.
