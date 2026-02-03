# 0223 — assignment to a QUALIFIED module global (`lib.g = 5`) fails "unresolved 'lib'"

> **RESOLVED** — `src/ir/lower/stmt.zig`. Root cause: the field-access store
> arms of `lowerAssignment` and `lowerMultiAssign` lowered the member BASE
> (`lib`) as a value expression via `lowerExprAsPtr`, but a namespace-import
> alias is not a value, so the base lookup failed "unresolved 'lib'". The READ
> path (expr.zig `lowerFieldAccess`) recognizes an alias base and re-resolves
> the member in the target module's context. Fix: a shared
> `tryLowerQualifiedGlobalStore` helper runs FIRST in both field-access store
> arms — when the base is an unshadowed namespace alias it resolves the member
> as a MUTABLE global of the target module (switching `current_source_file` to
> the target so visibility is judged as the target's own name) and emits
> `global_set` (plain) or `global_get`+op+`global_set` (compound). A qualified
> CONST or FUNCTION member is rejected with a clean diagnostic (never a silent
> drop); an unresolved member likewise. Classification runs under the switched
> source context but all assignment-site diagnostics are emitted AFTER
> restoring `current_source_file`, so the renderer resolves their span against
> the caller's file, not the imported module's. Regression tests:
> `examples/modules/1620-modules-qualified-global-store.sx` (positive: read →
> store → compound `+=`/`*=`) + `examples/diagnostics/1226-diagnostics-qualified-global-store-nonlvalue.sx`
> (const + fn member rejection). NOTE: qualified STRUCT-global members through
> an alias (`lib.gp.x`) remain a SEPARATE pre-existing bug in the READ path
> (expr.zig treats `alias.member.field` as `alias.Type.member`) — out of scope
> here; the 0223 repro is a scalar `i64` global.

## Symptom

One-line: with `lib :: #import "..."` and a mutable global `g` in lib,
the qualified READ `x := lib.g` works and calling `lib.fn()` works, but
the qualified STORE `lib.g = 5;` fails with `error: unresolved 'lib'`.

- Observed: `error: unresolved 'lib'` on the assignment line (loud, so no
  silent damage — but the form simply never worked).
- Expected: the store resolves like the read does and writes the global.

Verified pre-existing on master `e91df844` (byte-identical control flow
rebuilt with the parent's stmt.zig) — NOT a regression of the issue-0216
fix. Unqualified stores to flat-imported globals work; only the
`alias.global` member-LHS store path is missing.

## Reproduction

```sx
// lib file: .sx-tmp/q0223_lib.sx
lib_g : i64 = 0;
bump_here :: () { lib_g += 1; }
```

```sx
#import "modules/std.sx";
lib :: #import "q0223_lib.sx";   // file-relative import

main :: () -> i32 {
    print("{}\n", lib.lib_g);   // read works
    lib.bump_here();            // call works
    lib.lib_g = 5;              // error: unresolved 'lib'
    print("{}\n", lib.lib_g);   // expected 5
    0
}
```

## Investigation prompt

In `src/ir/lower/stmt.zig` the member-LHS assignment arm resolves the
BASE (`lib`) as a value expression — a module alias is not a value, so
the base lookup fails with "unresolved 'lib'". The READ path has a
member-access arm that recognizes a module-alias base and resolves
`alias.name` to the imported module's global (grep the member-access
lowering in src/ir/lower/expr.zig for the module-alias/namespace arm);
mirror that in the assignment path: when the member base is a module
alias/namespace, resolve the target as a global of that module (reuse
`resolveGlobalRef`-class machinery with the module qualifier) and emit
`global_set` — including compound ops (`lib.g += 1`). Reject with a
clean diagnostic when the qualified name is a CONST or a function.
Verification: the repro prints 0 then 5; compound `lib.g += 1` works;
`lib.some_fn = 3` and `lib.SOME_CONST = 3` diagnose cleanly; regression
example under examples/modules/; full corpus green.

Found by the adversarial review of the issue-0216 fix (2026-07-03).
