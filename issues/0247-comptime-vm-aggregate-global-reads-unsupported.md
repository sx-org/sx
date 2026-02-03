# 0247 — the comptime VM cannot read aggregate-initialized globals

> **RESOLVED (2026-07-10).** The comptime VM now allocates aggregate globals in its byte-addressable memory and recursively lays out struct, tuple, array, and optional constants before field reads.

## Symptom

One-line: `#run` code reading ANY aggregate-initialized module global —
a struct global (`gs : S = S.{ a = 7 };`) or, since the issue-0234 fix,
an optional global — bails with "global_get static init kind not yet
supported".

- Observed: comptime evaluation bails (loud, per the bailDetail
  convention — not silent), so `#run` consts depending on such globals
  fail to compile.
- Expected: the comptime VM materializes aggregate global initializers
  (the VM is arena-backed byte-addressable memory, so writing the
  aggregate bytes into VM memory and returning the address fits the
  existing model).

Pre-existing on master (struct-global repro verified there by the
issue-0234 fix worker, 2026-07-04); the 0234 fix extends the REACH
(optional globals now arrive here where they previously died in the
emitter) but not the cause.

## Reproduction

```sx
#import "modules/std.sx";

S :: struct { a: i64 = 0; }
gs : S = S.{ a = 7 };

get_a :: () -> i64 { return gs.a; }

K :: #run get_a();   // bails: "global_get static init kind not yet supported"

main :: () -> i32 {
    print("{}\n", K);   // expected 7
    0
}
```

## Investigation prompt

`constToReg` in `src/ir/comptime_vm.zig` materializes only scalar
ConstantValues into a Reg word; the `global_get` handler hits the
aggregate initializer kinds (aggregate/zeroinit/string?) and bails.
Extend the VM's global materialization: allocate the global's byte size
in VM memory (the arena-backed model — Addr is a real host pointer, per
the project's VM design), serialize the aggregate initializer into it
(mirror what emitGlobals/emitConstAggregate lay out, including the
issue-0234 optional {payload, i1} wrap), cache per-global (writes
through global_set must hit the same storage), and return the address
for global_get of aggregate type / the loaded scalar otherwise. Probe:
struct, array, optional, nested, string globals read AND written under
#run; interaction with compiler_hooks globals if any. Verification: the
repro prints 7; existing comptime corpus (examples/comptime/) green;
bail message remains for genuinely unsupported kinds per the
loud-unimplemented-arm rule.

Found by the issue-0234 fix worker (2026-07-04); pre-existing.
