# 0213 — wrapping a protocol value into an optional heap-allocates a block that is never freed

> **RESOLVED (2026-07-02).** Root cause: a `?P` (protocol child) destination
> never reached the node-aware `buildProtocolErasure` — `classifyXX` routed
> `xx s : ?P` to the generic `.coerce` ladder, whose `.optional_wrap` arm
> re-coerced the already-materialized VALUE through the node-less
> `.erase_protocol` arm (`src/ir/lower/coerce.zig`), which alloca-copies the
> receiver and then heap-boxes it via `context.allocator` (`heap_copy=true` →
> `allocViaContext` in `src/ir/lower/protocol.zig:buildProtocolValue`) with no
> owner to ever free it. The decl path (`op : ?P = s`, implicit) had the same
> node-less `coerceToType` in its optional branch (`src/ir/lower/stmt.zig`).
> Fix: new `XXPlan.erase_protocol_wrap` — dst `?P` erases to the CHILD with
> the operand node in hand (borrow-mode for lvalues, exactly like the plain
> `p : P = xx s` path), then wraps inline; the decl optional branch routes a
> protocol child through `buildProtocolErasure(node)` the same way. Rvalue
> sources (struct literals, call results) keep the self-contained heap copy,
> matching the plain path. Regression test:
> `examples/protocols/0422-protocols-optional-erasure-no-alloc.sx` (GPA
> net-zero gate over all matrix forms + borrow-visibility checks).

## Symptom

Constructing a `?P` (optional of a PROTOCOL type) from a protocol value —
whether via direct erasure (`op : ?P = xx s`) or from an already-erased
plain value (`op : ?P = p`) — performs ONE hidden heap allocation through
`context.allocator` that no code path ever frees. Observed: a GPA
leak-gated program shows `alloc_count` +1 per optional-protocol
construction; expected: 0 — plain protocol erasure (`p : P = xx s`) is
borrow-mode per specs §3 and allocates nothing, and optionals of ordinary
aggregates are inline (no box).

Blast radius today: every `http.Config` with `tls: ?TlsAcceptor` or
`fibers: ?FiberRunner` set leaks one block per Config construction (the
Q3.3 red example `examples/http/1700` fails its net-zero GPA gate by
exactly +1; the working tree carries its in-progress feature code).

## Reproduction

Standalone (also at `.sx-tmp/opt-proto-repro.sx`); expected exit 0 /
`plain 0 opt 0`, observed exit 1 / `plain 0 opt 1`:

```sx
#import "modules/std.sx";

P :: protocol {
    ping :: (self: *Self) -> i64;
}

S :: struct { v: i64 = 7; }

impl P for S {
    ping :: (self: *S) -> i64 { return self.v; }
}

main :: () -> i32 {
    gpa := GPA.init();
    plain : i64 = -1;
    opt : i64 = -1;
    push Context.{ allocator = xx gpa } {
        s := S.{};
        p : P = xx s;            // borrow-mode erasure — no allocation
        plain = gpa.alloc_count;
        op : ?P = xx s;          // optional wrap — allocates, never freed
        opt = gpa.alloc_count;
        if op == null { opt = 100; }
        if p.ping() != 7 { plain = 100; }
    }
    print("plain {} opt {}\n", plain, opt);
    if plain != 0 or opt != 0 { return 1; }
    return 0;
}
```

Form matrix (probe at `.sx-tmp/opt-proto-forms.sx`):

| form                                     | allocs (pre-fix) |
|------------------------------------------|--------|
| `p : P = xx s` (plain, value)            | 0 (borrow — spec §3) |
| `op : ?P = xx s` (optional, VALUE local) | **1, leaked** |
| `op : ?P = p` (optional, from plain `P`) | 0 (CORRECTED — src == child skips the coercion; the original filing misattributed a neighboring probe's +1) |
| `op : ?P = xx @s` (optional, POINTER)    | 0 |
| `h.op = xx @s` (field assign, pointer)   | 0 (why 1679/TLS passes its gate) |
| `h : H = .{ op = xx s }` (literal, value)| **1, leaked** |
| `?P = null`                              | 0 |

SCOPE NOTE (from the fix's adversarial review): the fix covers the `xx`
flavors. IMPLICIT (no-`xx`) coercion sites — `take(s)` call args,
`h.op = s` field assigns, `.{ op = s }` literal fields, `op = s` local
assigns — still box +1 unfreed, **exactly like the PLAIN protocol path
does on the same forms** (a pre-existing node-less-coercion limitation,
symmetric, neither introduced nor worsened by this fix).

So the box appears when the erasure SOURCE is a value (or an
already-erased protocol value), in an optional destination — the compiler
apparently materializes a heap copy of the receiver instead of borrowing
the local's address as the plain-protocol path does.

## Investigation prompt

In the sx compiler at /Users/agra/projects/sx: wrapping a protocol value
into an optional (`?P` where `P :: protocol`) emits a hidden
`context.allocator` allocation that is never freed; plain protocol
erasure is borrow-mode (no allocation), and optionals of ordinary structs
are inline. Suspected area: the optional-construction lowering path for
protocol-typed payloads — likely in `src/ir/lower/` where a `?T` wrap is
lowered (optional payload storage), special-casing or falling into a
box-the-payload path for protocol (fat pointer + vtable) values instead
of the inline-payload representation other aggregates use; the erasure
side lives in `src/ir/lower/protocol.zig`. What the fix likely needs:
represent `?Protocol` with an inline payload (tag + the fat protocol
value), matching non-optional protocol values and optional structs — no
allocation on wrap, nothing to free. Check both construction forms
(direct `xx` erasure into `?P`, and `?P` from an already-erased `P`) and
struct-literal fields of optional-protocol type. Verification: run the
repro above (`.sx-tmp/opt-proto-repro.sx` or inline from this file) —
expect `plain 0 opt 0`, exit 0. Then `zig build test` — the full corpus
must stay green (NOTE: `examples/http/1700` is expected-RED at the
current master base — it is a committed red test for the in-flight Q3.3
feature whose leak gate this bug breaks; it fails by LEAK +1 pre-fix and
may still fail for feature reasons on a stale base — do not chase it
beyond the leak accounting; `examples/http/1679` — TLS, sets
`?TlsAcceptor` — has a net-zero gate and must go from its current state
to green if it was tolerating the leak). Fast-forward your worktree to
master HEAD before starting.
