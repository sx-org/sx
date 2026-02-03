# 0210 — failable-guard record poisons a sibling-scope re-declaration of the same name

> **RESOLVED.** Root cause: `FlowCtx.bindings` / `err_vars` in
> `src/ir/error_flow.zig` were flat, name-keyed, and monotonic ("never
> removed"), so a failable pair's taint record outlived its lexical scope,
> while the matching proof lived in a per-scope `loop_proven` clone that was
> correctly discarded — taint survived, proof didn't, and a later same-name
> `:=` inherited the dead obligation. (The "nested case works" observation
> held only when `we` was proven on the fall-through — the surviving proof,
> not scoping, made it pass; an unproven nested redecl failed too.)
> Fix: every declaration (`:=`/`::` var, const, destructure names, for-loop
> captures, match-arm captures — and, per follow-up review, the four
> remaining binding forms: if-let `if n := expr { … }`, while-let
> `while n := expr { … }`, `x catch (n) { … }` handler bindings, and
> `onfail (n) { … }` cleanup bindings) now clears the name's stale records
> (binding, err-var role, proven-absent fact) via `declareName`, with a
> shadow-undo stack unwound at lexical-scope exit (`scopeExit`) so an outer
> shadowed variable's taint/proof is restored — outer unguarded reads after
> a nested shadow still error, and a scope's own registrations no longer
> leak out. Also fires a previously-missed true positive: re-declaring the
> err name (`m, we := f()`) now invalidates the old `we` proof.
> Regression test: `issues/0210-failable-guard-poisons-sibling-scope-redecl.sx`
> (pinned via `issues/expected/`).
>
> **Intentional conservative reject** (documented decision, not a bug): a
> plain redecl of the ERR name after its proof was discharged —
> `n, we := f(); if we { return 9; } we := 0; if n != 1 { … }` — still
> rejects the read of `n`. The analysis is name-keyed: once `we` is rebound
> to an unrelated variable, a proven-absent fact keyed `we` can no longer be
> attributed to the failable's error variable without variable identity,
> which this walk deliberately does not track. Preserving the proof across
> "plain-looking" redecls would need a soundness carve-out keyed on binding
> form, and any mistake there yields a false NEGATIVE (a silently missed
> unguarded use) — the silent-wrongness class this project treats as
> worst-case — whereas the over-reject is loud and fixed in one line
> (re-guard, or don't reuse the err name). Conservative direction chosen on
> purpose.

## Symptom

One-line: a failable pair `n, we := f()` declared inside a loop/block body makes a
LATER, plain (non-failable) `n := g()` in a **disjoint sibling scope** fail the
failable-use guard.

Observed:

```
error: value `n` from a failable can be used only where its error `we` is proven
absent — guard the use with `if !we { … }`, or return early with `if we { return; }`
before reading `n`
```

on the `if n != 5` line below — but that `n` is a fresh declaration from a plain
`-> i64` function, in a scope where the earlier failable `n`/`we` are long dead.

Expected: the second `while` body's `n` is an unrelated variable; no guard applies.

Note: shadowing/nesting is NOT required — the two scopes are siblings. A failable
pair at FUNCTION scope followed by a nested plain redecl does NOT trigger the bug
(that case works). The trigger is the failable pair being declared inside a block
whose scope ends before the second declaration.

## Reproduction

`issues/0210-failable-guard-poisons-sibling-scope-redecl.sx` (expected: prints `ok`,
exit 0; currently: the compile error above, exit 1):

```sx
#import "modules/std.sx";

f :: () -> (i64, !) { return 1; }
g :: () -> i64 { return 5; }

main :: () -> i32 {
    t := 0;
    while t < 2 {
        n, we := f();           // failable pair inside loop A's body
        if !we { if n != 1 { return 3; } }
        t += 1;
    }
    t = 0;
    while t < 2 {
        n := g();               // sibling scope: plain, non-failable decl
        if n != 5 { return 4; }
        t += 1;
    }
    print("ok\n");
    return 0;
}
```

Hit in the wild writing `examples/http/1683-http-lingering-close.sx` (an earlier
loop's `n, we := socket.write_nb(...)` poisoned a later drain loop's
`n := socket.read(...)`); worked around there by renaming to `rn`.

## Investigation prompt

The failable-use guard diagnostic lives in `src/ir/error_flow.zig` ("proven
absent"). The guard analysis appears to key its "this value came from a failable
and needs its error proven absent" record on the variable NAME (or on a
declaration record that survives past the end of its lexical scope), so a fresh
`:=` declaration of the same name in a LATER sibling scope inherits the stale
guard obligation. Function-scope pair + nested redecl works, so scope ENTRY
probably clears/shadows correctly — the bug is likely that scope EXIT does not
remove (or a later same-name decl does not overwrite) the guard record.

Fix should make a plain re-declaration (any `:=` of the same name after the
failable pair's scope has ended — and arguably ANY new `:=` declaration, which
always introduces a new variable) clear the pending failable-guard obligation for
that name. Check both:
1. sibling-scope redecl after the failable's block closed (the repro), and
2. same-scope sequential redecl (`n, we := f(); ...; n := g();`) if sx allows it.

Verify: `./zig-out/bin/sx run issues/0210-failable-guard-poisons-sibling-scope-redecl.sx`
prints `ok`, exit 0. Then `zig build test` (full corpus) — the guard must still
FIRE for genuine unguarded uses (`examples/errors/*` cover the positive cases).
