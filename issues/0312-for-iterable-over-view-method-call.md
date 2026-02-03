# 0312 — `for view.method() (x)` — a method call on a `*P` view is not classified as an iterable

> **RESOLVED (2026-07-18).** Fix: CallResolver.plan resolves protocol methods through *P / ?P / ?*P receivers, so the call types and the for-iterable classifier sees the []T.
> Regression test: `examples/protocols/0882-protocols-view-method-iterable.sx`.

## Symptom

Iterating a method-call result directly works on an OWNED protocol
value but not on a `*P` view:

```sx
p : P = xx C.{};        for p.items() (*x) { … }   // OK
v : *P = c;             for v.items() (*x) { … }   // error
```

```
error: cannot iterate this expression — if the parens were call
arguments, a call iterable also needs a capture (`for f(n) (x) { }`)
or parentheses (`for (f(n)) { }`)
```

The parenthesized form `for (v.items()) (*x)` fails identically, so the
iterable-position classifier simply doesn't recognize a view-dispatch
call as an iterable-producing expression. Bind-first is the workaround
and compiles fine:

```sx
evs := v.items();
for evs (*x) { … }      // OK
```

Found as `for (g_plat.poll_events()) (*ev)` in m3te's frame loop
(`g_plat : *Platform`, `poll_events :: (self) -> []Event`) — the exact
line compiled when `g_plat` was an owned `Platform` value.

## Reproduction

```sx
#import "modules/std.sx";

P :: protocol {
    items :: (self: *Self) -> []i32;
}

C :: struct { a : [3]i32 = .[1, 2, 3]; }

impl P for C {
    items :: (self: *C) -> []i32 {
        r : []i32 = ---;
        r.ptr = @self.a[0];
        r.len = 3;
        r
    }
}

main :: () {
    c := C.{};
    v : *P = c;
    for v.items() (*x) { print("{}\n", x.*); }
}
```

Run: `sx run repro.sx` → the "cannot iterate" error at the
`v.items()` site (HEAD c8235e32, 2026-07-18). Expected: prints 1, 2, 3
— same as the owned-protocol form.

## Investigation prompt

Suspected area: `for`-iterable classification in the parser / lower —
the "call iterable" arm likely keys on the receiver's type being a
plain call or a method on an owned value/protocol and misses the
view-dispatch (`*P`) receiver category added by the E1-era work.

What the fix likely needs: extend the iterable classification to accept
method calls whose receiver is a `*P` view (dispatch result type drives
iterability the same as the owned case), for both the bare and
parenthesized spellings.

Verification: the repro prints 1, 2, 3; then m3te's frame loop can go
back to `for (g_plat.poll_events()) (*ev)` from the bind-first
workaround (marked with a comment in main.sx).
