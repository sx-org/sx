> **RESOLVED** (2026-06-27). Root cause exactly as hypothesized: the generic
> monomorph path `monomorphizeFunction` (`src/ir/lower/generic.zig`) bound params
> and lowered the body via `lowerValueBody`, but NEVER called
> `bindNamedReturnSlots` — so `named_return_names` stayed null and the
> implicit-return synthesis (`lowerValueBody`, stmt.zig) didn't fire. (The
> non-generic decl path `lowerFunctionBodyInto` already called it.) Fix: call
> `bindNamedReturnSlots(fd, ret_ty, &scope)` in `monomorphizeFunction` after
> param-binding, with the same `named_return_names`/`named_return_defaults`
> save/restore. Covers generic free functions AND generic struct methods (the
> instance-method path shares the monomorph), with defaults and the failable
> error channel. Regression test: `examples/types/0218-types-multi-return-generic-named.sx`.

# 0200 — named-return locals don't synthesize the implicit return in a GENERIC multi-return function

**Symptom** — A generic function with a NAMED multi-return (`-> (first: $T, second: $U)`)
that relies on the implicit return (assigns the named slot locals, no explicit
`return`) fails to compile: the named-return-locals synthesis does not fire for
the monomorphized instance, so it reports "body produces no value".

- Observed: `pair :: (a: $T, b: $U) -> (first: T, second: U) { first = a; second = b; }`
  → `error: function returns '(first: i64, second: bool)' but its body produces
  no value — end it with a trailing expression (no ';') or an explicit 'return'`.
- Expected: the named slot locals (`first`, `second`) are bound and the implicit
  return is synthesized from them, exactly as for a NON-generic named
  multi-return.

Note the diagnostic shows the return type RESOLVED to concrete types
(`(first: i64, second: bool)`) — so binding/return-type resolution ran; only the
named-return-LOCALS path (`bindNamedReturnSlots` → `self.named_return_names`) did
not take effect for the generic instance.

WORKS (so this is narrow): the POSITIONAL generic multi-return with an explicit
return is fine — `(a: $T, b: $U) -> (T, U) { return a, b; }` and explicit-type
`pair(i32, bool, 7, true)` both run correctly. Only the named-slot IMPLICIT-return
form × generic monomorph is broken. Workaround: use an explicit `return a, b`.

## Reproduction

```sx
#import "modules/std.sx";

pair :: (a: $T, b: $U) -> (first: T, second: U) {
    first = a;
    second = b;          // implicit return from named slots — never synthesized
}

main :: () -> i64 {
    x, y := pair(7, true);
    print("{} {}\n", x, y);
    return 0;
}
```

`./zig-out/bin/sx run repro.sx` → the "produces no value" error, exit 1.

## Investigation prompt

The implicit-return-from-named-slots synthesis (`lowerValueBody` in
`src/ir/lower/stmt.zig` ~line 172: `if (self.named_return_names) |names| { … }`)
only fires when `self.named_return_names` is set by `bindNamedReturnSlots`
(`src/ir/lower/stmt.zig` ~258). That binder is called from `lowerFunctionBodyInto`
(`src/ir/lower/decl.zig:2729`). `bindNamedReturnSlots` early-returns unless
`fd.return_type.?.data == .return_type_expr`.

The likely cause: the generic-FREE-function monomorph lowers the instance with a
SUBSTITUTED return-type node (the `$T`/`$U` resolved into a concrete
`tuple_type_expr` or a resolved TypeId), so `fd.return_type.data` is no longer
`.return_type_expr` → `bindNamedReturnSlots` early-returns → `named_return_names`
stays null → the implicit return isn't synthesized. Confirm by checking the
generic free-function instantiation path (search `instantiateGeneric` /
`lazyLowerFunction` / the monomorph that rewrites `fd` for free functions): does
it preserve the original `ReturnTypeExpr` AST node (binding via `type_bindings`),
or rewrite it? The fix likely keys `bindNamedReturnSlots` off the ORIGINAL
template `fd.return_type` (which carries `field_names`), or threads the
field-names through the monomorph. Generic STRUCT methods may have the same gap —
test `Box(T)` with a named multi-return method.

Verify: the repro prints `7 true`, exit 0. Add a positive generics example.
