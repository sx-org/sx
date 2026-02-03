# issue 0202 — UFCS method call on a global struct copies the receiver (mutation lost)

> ✅ **RESOLVED.** Root cause: `fixupMethodReceiver`
> ([src/ir/lower/expr.zig](../src/ir/lower/expr.zig)) only took the receiver's
> real address when the identifier was a local **alloca**; a module-global
> identifier fell through to the general "alloca + store the value" case, which
> copies the global onto the stack and passes the copy's address — so `self: *T`
> mutations landed on the throwaway copy. Fix: when the identifier receiver is
> not a local but resolves to a global (`resolveGlobalRef`), address its live
> storage via `lowerExprAsPtr` (`global_addr`), mirroring the compound-lvalue
> branch. The free-function-UFCS path shares `fixupMethodReceiver`, so it was
> fixed in the same change. Verified on host + real aarch64-linux (a global
> `thread.Mutex` accessed via UFCS now serializes: 400000/400000). Regression
> test: [examples/basic/0057-basic-ufcs-method-on-global.sx](../examples/basic/0057-basic-ufcs-method-on-global.sx).

## Symptom

A UFCS method call `g.method()` on a **global** struct value, where the method
takes `self: *T`, binds `self` to a **stack copy** of the global rather than the
global's address. Any mutation through `self` is silently lost.

- **Observed:** `g.bump(); g.bump(); g.bump()` leaves the global `g.n == 0`.
- **Expected:** `g.n == 3`.

A **local** receiver works (`loc.bump()` mutates `loc`), and an **explicit
pointer** to the global works (`pg : *T = @g; pg.bump()` mutates `g`). Only the
UFCS-on-global path is wrong.

## Reproduction

`issues/0202-ufcs-global-receiver-copy.sx` (standalone, no imports):

```sx
Counter :: struct {
    n: i64 = 0;
    bump :: (self: *Counter) { self.n += 1; }
}

g : Counter = .{};

main :: () -> i32 {
    g.bump();
    g.bump();
    g.bump();
    return xx g.n;   // expect 3; BUG: returns 0
}
```

Run: `./zig-out/bin/sx run issues/0202-ufcs-global-receiver-copy.sx` →
exit `0` (bug); expected exit `3`.

Direct evidence of the stack copy (the address `self` receives differs from the
global's real address under UFCS, but matches it under an explicit `@g`):

```sx
Probe :: struct {
    x: i64 = 0;
    addr :: (self: *Probe) { print("self={}\n", xx @self.x); }
}
g_p : Probe = .{};
main :: () -> i32 {
    print("&g_p.x={}\n", xx @g_p.x);   // e.g. 0x102c652f8  (global)
    g_p.addr();                        //     0x16dbb2658  (STACK copy — BUG)
    pp : *Probe = @g_p;
    pp.addr();                         //     0x102c652f8  (correct)
    return 0;
}
```

## Impact (how it was found)

Surfaced under HTTPZ C3b while validating `std/thread`. A **global**
`thread.Mutex` accessed via UFCS (`g_mu.setup()`, `g_mu.lock()`) provides no
mutual exclusion: `setup()` initializes a throwaway copy (the global mutex stays
uninitialized) and each `lock()` locks a different stack copy. A pointer-shared
mutex (`mu` local in `main`, `@mu` passed to threads) works flawlessly on both
darwin and aarch64-linux — which is why the bug masquerades as a thread/per-OS
problem but is neither. It affects ANY mutating method on a global struct,
single-threaded included.

## Investigation prompt (paste into a fresh session)

> In sx, a UFCS method call on a **global** struct value materializes a stack
> COPY of the receiver and passes its address as `self: *T`, instead of taking
> the global's address — so mutations through `self` don't reach the global.
> Locals and explicit `@global` are correct; only UFCS-on-global is wrong.
>
> Reproduce: `./zig-out/bin/sx run issues/0202-ufcs-global-receiver-copy.sx`
> returns exit 0; it must return 3 (the global `g.n` after three `g.bump()`).
>
> Suspected area: the UFCS / method-call auto-address-of lowering (likely
> `src/ir/lower.zig` — search the method-call / UFCS receiver handling and the
> auto-`@`/address-of-receiver path). When the receiver is an **addressable
> lvalue** (a global is), the lowering must emit the lvalue's address directly,
> the same path locals already take — not load the global into a temp and take
> the temp's address. Compare the receiver-lowering branch for a global-name
> lvalue vs a local-name lvalue; the global branch is almost certainly falling
> into an rvalue/by-value materialization before the auto-address-of.
>
> Verify: the repro returns exit 3; add the `Probe`/`addr` address-print check
> and confirm UFCS `g_p.addr()` prints the SAME address as `&g_p.x` (not a stack
> address). Then re-run the HTTPZ C3b thread probes (a global `thread.Mutex`
> accessed via UFCS should serialize). Once fixed, promote this repro into the
> regression corpus (`examples/…`) per CLAUDE.md "Resolving an open issue".
>
> Watch for: the fix must not regress the LOCAL receiver path (`loc.bump()`
> already works) nor the by-value-receiver case (a method taking `self: T`, not
> `*T`, legitimately copies).
