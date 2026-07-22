# 0345 — statement-keyword member names die with a misleading struct-parse error

Status: RESOLVED (language extension, Agra-decided 2026-07-22)

## Resolution

Every keyword EXCEPT `inline` is a legal bare member name in: struct
fields, struct methods/constants, protocol methods, and impl method
definitions (a keyword-named protocol method must be implementable
without ceremony; a keyword has no builtin to shadow, so the
type-spelling impl restriction does not carry over). Reachable through
every member position: literal init (keyword fields take only the
`name = value` form — positional if-expressions still parse), dot
access (already worked via dotMemberName), and `?.` chaining (extended).
`inline` stays backtick-only and rejects bare with a targeted
escape-hint via the ONE shared reject helper (failMemberDeclName — no
per-site special cases). Value-binding positions unchanged.

Parser: isMemberDeclName + failMemberDeclName; sites: struct member
loop (method dispatch + field paths), protocol body, impl block, struct
literal, `?.`. specs.md: new "Statement keywords are member names too"
paragraph. Pins: examples/types/0891 (acceptance incl. impl dispatch,
chaining, positional-expr backtrack, backtick inline),
examples/diagnostics/1277 (bare-inline targeted reject).
`InputQueue.enqueue` restored to its natural name `push`.

## Symptom

A struct method named `push` (the context-push statement keyword) fails
to parse with a diagnostic that neither names the token nor hints at the
cause, pointing at the member as if the struct body were malformed:

```
error: expected field name in struct
  --> q4.sx:4:5
   |
 4 |     push :: (self: *Q, ev: i64) {
```

## Repro

```sx
#import "modules/std.sx";
Q :: struct {
    events: List(i64) = .{};
    push :: (self: *Q, ev: i64) {
        self.events.append(ev);
    }
}
main :: () { q := Q.{}; q.push(1); print("{}\n", q.events.len); }
```

## Expected vs actual

Expected: either (a) `push` is accepted as a member name — the spec's
member-position exemption covers bare RESERVED TYPE spellings
(`obj.name` access is never type-classified; the same argument applies
to statement keywords: a member is always accessed as `obj.push(…)`,
never in statement-head position), or (b) a targeted diagnostic:
"`push` is a statement keyword and cannot name a struct member; rename
or escape it".

Actual: the generic "expected field name in struct" with no mention of
the keyword, at the member's line. Cost: real debugging time — the
error reads as a struct-syntax problem and survives bisecting every
other member. (Hit while building `InputQueue.push`; renamed to
`enqueue`.)

## Suspected area

Parser struct-member loop: the member-name token check accepts
identifiers + backtick escapes but bails on keyword tokens before the
`::` lookahead that would disambiguate a member declaration.

## Notes

Whether `push` (and `if`/`while`/`for`/`case`…) should be *legal* member
names via the exemption argument is a language call — splitting the two:
the diagnostic fix is uncontroversial; the exemption extension needs
Agra's sign-off. Filed from G2 Step 1 (non-blocking; workaround-free
rename).
