# issue 0205 — `return <concrete-errset failable>` from a bare-`!` fn → invalid IR

> **RESOLVED (2026-07-03).**
>
> **Decision: concrete → bare-`!` forwarding is LEGAL** (and lands coerced,
> not rejected). Evidence: error tags are GLOBAL ids in one shared u32 repr
> (`TypeTable.ErrorSetInfo` — "tags are GLOBAL tag ids … id 0 is reserved for
> 'no error'"; specs.md "Tag identity is the name, globally"), so a concrete
> set's tag value is directly meaningful to every consumer of the open `!`
> channel — no translation exists or is needed. The bare `!` is the open
> superset (specs.md: the inferred set "collects whatever … the body raises").
>
> **Root cause:** `lowerFailableSuccessReturn` (src/ir/lower/error.zig)
> detected "the returned expression already IS the full failable tuple" by
> EXACT TypeId equality (`val_ty == ret_ty`). A callee whose error SET differs
> (`(i64, !MyErr)` forwarded through `(i64, !)`) interns a different tuple
> TypeId, fell into the single-value path, and the whole callee aggregate was
> insertvalue'd as element 0 of the caller's own `{i64, i32}` — invalid IR.
>
> **Fix:** a new `lowerFailableForwardReturn` arm fires when the returned
> value is itself a failable tuple with a different TypeId: it re-packs the
> value slots (coerced per-slot) plus the raw error tag (re-typed to the
> caller's set — same u32 repr). Legality mirrors `raise`'s subset rule:
> bare-`!` caller absorbs any concrete set; concrete → concrete requires
> callee ⊆ caller (each escapee diagnosed via `checkErrorSetSubset`);
> bare-`!` CALLEE → named caller is rejected with a destructure-and-re-raise
> diagnostic (its inferred set is not statically known at the forward site);
> value-slot arity mismatch is diagnosed. Spec addition under "Error sets"
> (specs.md, "Forwarding a failable result").
>
> **Regression test:** `examples/errors/1066-errors-forward-concrete-to-bare-bang.sx`
> (success + error forwards, catch/try/or interop, matched-set, subset
> concrete→concrete, multi-value, pure-failable forms).
>
> The two SEPARATE front-end limitations noted below still reproduce and are
> NOT fixed here: `-> (i64, !socket.SockErr)` is a parse error (`expected ','`),
> and an aliased set (`SockErr :: socket.SockErr` then `!SockErr`) fails with
> "expected an error set after '!', found type 'SockErr'".
>
> **Review fold-in (same day):** the whole forward-mechanism family closed —
> (a) TIE-BREAK regression fixed: a returned VALUE tuple whose field count
> matches the caller's value arity AND whose per-slot error-set-ness fits is
> the value list, not a forward (`return v, e` into `(i64, MyErr, !)` works
> again); a non-fitting tuple takes the forward interpretation and its
> arity/set diagnostics — never invalid IR; (b) pure callee → value-carrying
> caller rejected (0-vs-n value-slot arity); (c) value-carrying callee →
> PURE caller rejected (n-vs-0 — the old coerce silently truncated the tuple
> into a garbage tag); (d) pure→pure forwards share the same set-compat rule
> (`checkForwardSetCompat`; issue 0227). Spec updated with the tie-break and
> the no-trace-frame note. Rejections pinned in
> `examples/diagnostics/1222-diagnostics-failable-forward-mixtures.sx`.

## Symptom

A function declared with a **bare anonymous error channel** (`-> (T, !)`) that
**tail-forwards** a call returning a **concrete error set** (`-> (T, !E)`) emits
invalid LLVM IR and fails module verification:

```
LLVM verification failed: Invalid InsertValueInst operands!
  %ti = insertvalue { i64, i32 } undef, { i64, i32 } %call, 0
```

- **Observed:** LLVM verification failure (the program never runs).
- **Expected:** exit 5 (the repro forwards `inner(5)` → 5).

Codegen builds the forwarding function's `{ value, error }` result by inserting
the **whole `{i64,i32}` callee result** as **element 0** of its own `{i64,i32}`
return aggregate — a nested-vs-flat type mismatch — instead of coercing the
concrete error set (`!MyErr`, error tag `i32`) into the open/anonymous one (`!`).

It is unclear whether the mix is meant to be *legal* (bare `!` is the open
superset of any concrete error set, so the forward should coerce) or *rejected*
(needs an explicit re-raise). Either way it is a compiler defect: the front end
should either coerce correctly OR emit a diagnostic — never hand invalid IR to
the verifier.

### What works (so this is form-specific)

- **Destructure + re-raise** (the idiomatic form, used by the workaround below):
  `nq, e := inner(x); if e { raise error.X; } return nq;` — fine. Returns the
  scalar value (element 0 = `i64`) and raises into the bare channel separately.
- Forwarding when the **error sets match** (callee and caller both `!MyErr`, or
  both bare `!`) is expected to be fine — only the *concrete → bare* forward
  via `return callee()` is broken.

## Reproduction

`issues/0205-return-forward-failable-bare-bang-invalid-ir.sx` (self-contained):

```sx
#import "modules/std.sx";

MyErr :: error { Boom }

inner :: (x: i64) -> (i64, !MyErr) {
    if x < 0 { raise error.Boom; }
    return x;
}

// Forward a concrete-error-set failable through a BARE `!` return.
fwd :: (x: i64) -> (i64, !) {
    return inner(x);          // invalid LLVM IR built here
}

main :: () -> i32 {
    v, e := fwd(5);
    if e { return 1; }
    return xx v;              // expect 5
}
```

Run: `./zig-out/bin/sx run issues/0205-return-forward-failable-bare-bang-invalid-ir.sx`
→ LLVM verification failure; expected exit 5.

## How it was found

Building the HTTPZ Phase T2 transport seam in
[library/modules/std/http.sx](../library/modules/std/http.sx). The seam fns
`conn_read`/`conn_write` return `(i64, !)` and wanted to forward the plaintext
path with `return socket.read_nb(c.fd, buf, cap)` — `socket.read_nb` returns
`(i64, !SockErr)`. That `return <call>` triggered the invalid IR. The seam was
written the working way instead (destructure `socket.read_nb`, then re-raise
`error.WouldBlock` / `error.Closed` into the bare channel), so T2 is **not**
blocked by this — this issue tracks the underlying codegen defect.

Naming the concrete error set in the seam signature to make the sets match — the
other obvious avoidance — is **also** not possible today: `-> (i64, !socket.SockErr)`
(module-qualified error type) is a parse error (`expected ','`), and aliasing
`SockErr :: socket.SockErr` then `!SockErr` fails with "expected an error set
after '!', found type 'SockErr'" (the alias is seen as a type, not an error
set). Those are separate front-end limitations worth their own issue if they
matter; the bare-`!` channel + destructure-and-re-raise is the working idiom.

## Investigation prompt (paste into a fresh session)

> In sx, a function declared `-> (T, !)` (bare/anonymous error channel) that
> tail-forwards a call returning a *concrete* error set — `return inner(x)`
> where `inner : (i64, !MyErr)` — emits invalid LLVM IR
> (`Invalid InsertValueInst operands! %ti = insertvalue { i64, i32 } undef,
> { i64, i32 } %call, 0`) and fails verification. The destructure-and-re-raise
> form (`v, e := inner(x); if e { raise error.Boom; } return v;`) works.
>
> Reproduce: `./zig-out/bin/sx run
> issues/0205-return-forward-failable-bare-bang-invalid-ir.sx` → LLVM verify
> failure; it must exit 5.
>
> Suspected area: the lowering of a `return <call>` whose callee result type is
> `(T, !E_concrete)` into a function whose result type is `(T, !)` (open). The
> emitter appears to treat the callee's whole `{value, errtag}` aggregate as the
> *value* element (insertvalue at index 0) instead of recognising it is already
> the full failable result and either (a) coercing the error tag from the
> concrete set's repr into the open channel's repr and forwarding both fields, or
> (b) rejecting the mismatch at type-check time with a diagnostic. Look at how
> `return` of a failable call is lowered when caller/callee error sets differ —
> grep the IR lowering for failable/`!` return handling and the InsertValue that
> packs the `(value, error)` result (likely `src/ir/lower/expr.zig` or the
> return-lowering path, plus the failable result repr in `src/ir/types.zig`).
> Compare the IR for: matching sets (`!MyErr` → `!MyErr`, expected OK), and the
> broken concrete→open forward. Decide whether concrete→open coercion is allowed;
> if yes, fix codegen to forward both fields (coercing the tag); if no, add a
> type-check diagnostic so it never reaches the verifier.
>
> Verify: the repro exits 5; add it to the corpus as a regression
> (`examples/errors/10xx-…`). Consider also whether the matching `return
> socket.read_nb(...)` forward (concrete `!SockErr` → bare `!`) now works, which
> would let `http.sx`'s `conn_read`/`conn_write` use the simpler forwarding form.
