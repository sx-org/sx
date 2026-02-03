# Issue 0318 — WebAssembly bare function values are typed as `i64`

> **RESOLVED (2026-07-20).** Bare function references retain the legacy
> integer-shaped IR required by async/fiber consumers, but now use a target
> pointer-width word (`i64` on existing 64-bit targets, `isize` on wasm32).
> The regression is `examples/platform/1668-platform-wasm-function-values.sx`;
> `tests/wasm_function_values.sh` compiles it for wasm at opt 0 and opt 3.

## Symptom

Assigning a bare function to an exactly matching function-typed struct field
works on 64-bit targets, but fails for `--target wasm`: the function reference
is observed as `i64` instead of its function type. The same source should
cross-compile for both targets.

## Reproduction

```sx
#import "modules/std/core.sx";

Callback :: (ctx: *void, data: string) -> bool;
Holder :: struct { callback: Callback; }

accept :: (ctx: *void, data: string) -> bool { true }

main :: () -> i32 {
    holder := Holder.{ callback = accept };
    if holder.callback(null, "") then 0 else 1
}
```

Run:

```sh
./zig-out/bin/sx ir issues/0318-wasm-bare-function-value-is-i64.sx --opt 3
./zig-out/bin/sx ir issues/0318-wasm-bare-function-value-is-i64.sx --target wasm --opt 3
```

Observed: the host command succeeds, while WebAssembly reports
`cannot coerce a value of type 'i64' to 'function'` at the aggregate
initializer. Expected: both commands succeed and the callback remains callable.

## Investigation prompt

Fix issue 0318 in the SX compiler. A bare function identifier is currently
lowered in `src/ir/lower/expr.zig`'s identifier/function-value path as
`self.builder.emit(.{ .func_ref = fid }, .i64)`. On 64-bit targets the
same-width implicit-reinterpretation exemption masks that incorrect IR type;
on wasm32, `Lowering.diagnoseUnmodeledCoercion` in
`src/ir/lower/coerce.zig` correctly rejects the 8-byte `i64` to 4-byte function
slot. Make `func_ref` carry the actual declared/target function `TypeId` (while
preserving call-convention validation, closure promotion, explicit pointer
casts, imports, and overload-author selection). Audit other `.func_ref`
construction sites for the same hard-coded-word assumption. Add the repro as a
focused cross-target regression, run both commands above, then run
`zig build`, `zig build test`, and `./tests/run_all.sh --quick`; the wasm IR
command must succeed with no diagnostic.
