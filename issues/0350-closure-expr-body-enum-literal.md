# 0350 — expression-bodied closure return type does not reach the body expression (enum literals fail)

Status: OPEN (found writing per-point HitPolicy closures for the §6.9
router 2c slice, 2026-07-23)

## Symptom

A `closure((..) -> E => expr)` with a declared enum return type does
not propagate that type as the destination type of the `=>` body
expression, so enum literals in the body fail to resolve:

    error: enum literal '.a' has no destination type to resolve against

The equivalent block body with `return` statements types the same
literals fine, and a NAMED function with the identical
expression-shaped body (last-expression return) types them fine too —
only the lambda `=>` form loses the destination type.

## Repro

    #import "modules/std.sx";
    Pol :: enum { a; b; }
    main :: () {
        f := closure((x: f32) -> Pol => .a);                        // FAILS
        g := closure((x: f32) -> Pol => if x < 0.0 then .a else .b); // FAILS
        h := closure((x: f32) -> Pol {                               // works
            if x < 0.0 { return .a; }
            return .b;
        });
        process.assert(h(1.0) == .b, "h");
    }

Inside a nested call argument the message shifts to "cannot type
itself from non-enum destination 'closure'" — the lambda's OWN
destination (the closure type) leaks in as the literal's destination
instead of the declared return type.

## Expected

The declared return type types the `=>` body exactly as `return`
does: `.a` resolves against `Pol`.

## Actual

No destination type (or the wrong one — the closure type itself)
reaches the body expression; qualified `Pol.a` is required.

## Suspected area

Closure lambda checking: the expression-body path skips the
result-type push that both the named-function last-expression path
and the `return` statement path perform.
