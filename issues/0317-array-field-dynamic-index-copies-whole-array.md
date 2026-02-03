# 0317 — dynamic indexing of an array struct field copies the whole array per read

> **RESOLVED.** Root cause: `lowerIndexExpr`'s addressable-array read path
> gated on `getExprAlloca`, which accepts simple identifiers only — a field
> expression like `table.fast` fell through to the value path (`struct_get`
> array VALUE + `index_get`), which the LLVM backend realizes as a
> whole-array spill per read. Fix: `exprHasAddressableStorage`
> (src/ir/lower.zig) classifies lvalue chains rooted in an alloca or module
> global (through fields, indexing, derefs; rvalue/by-value-binding roots
> and pack indices excluded), and the read path recovers their storage via
> `lowerExprAsPtr` and emits `index_gep` + element load — object and index
> each evaluated exactly once. `sx_issue_0317_lookup` at `--opt 3` is now
> `ldr w0, [x0, x1, lsl #2]` with a 16-byte frame. Regression test:
> `examples/memory/0890-memory-array-field-index-in-place.sx`.

## Symptom

A dynamic read through an addressable fixed-array field —
`table.fast[index]` where `table: *Table` and `fast: [1024]i32` — produces
correct output but lowers through an array VALUE. The LLVM backend consequently
spills that value before indexing it. At `--opt 3`, the generated function
allocates 4096 bytes of stack and copies all 4096 field bytes with hundreds of
`ldr`/`str` instructions before performing the one requested `i32` load.

This was found while profiling the dependency-free miniz port in
`~/projects/sx-zip`. Its DEFLATE decoder uses a 1024-entry Huffman fast table.
Sampling attributed about 65% of the decode samples to `decode_direct`; its
assembly showed the same 4 KiB copy for every decoded Huffman symbol. A level-1
stream performs roughly 65,000 such lookups, so this compiler behavior dominates
SX decode time and explains the large throughput gap to miniz C.

The operation should compile to address arithmetic plus one load (on arm64,
essentially `ldr w0, [x0, x1, lsl #2]`) with no aggregate copy or 4 KiB stack
frame.

## Reproduction

Standalone, no std or project dependency:

```sx
Table :: struct {
    fast: [1024]i32;
}

lookup :: (table: *Table, index: i64) -> i32 export "sx_issue_0317_lookup" {
    table.fast[index]
}

main :: () -> i32 abi(.c) {
    table : Table = ---;
    i := 0;
    while i < 1024 {
        table.fast[i] = i.(i32);
        i += 1;
    }
    lookup(@table, 17) - 17
}
```

Verify correctness and inspect optimized assembly:

```sh
./zig-out/bin/sx run --opt 3 issues/0317-array-field-dynamic-index-copies-whole-array.sx
./zig-out/bin/sx asm --opt 3 -o /tmp/sx-0317.s issues/0317-array-field-dynamic-index-copies-whole-array.sx
```

The run exits 0. In `/tmp/sx-0317.s`, `sx_issue_0317_lookup` currently starts
with a 4096-byte stack allocation, copies the complete `fast` array from `x0`
to that stack area, then ends with the actual indexed load from the stack.

## Investigation prompt

In `~/projects/sx`, start in `src/ir/lower/expr.zig`'s fixed-array read path
around the comment "Array with addressable storage". It deliberately emits
`index_gep` + `load` to avoid a whole-array spill, but only calls
`getExprAlloca(ie.object)`. `getExprAlloca` intentionally accepts simple local
identifiers only, so an addressable field expression such as `table.fast`
misses that path. Lowering then evaluates `table.fast` as a `struct_get` array
VALUE and emits `index_get`. `src/backend/llvm/ops.zig:emitIndexGet` must spill
an array value to `ig.tmp`, producing the observed copy.

Fix the lowering at the source: for an addressable array expression, recover
its storage using the established lvalue machinery (`lowerExprAsPtr` /
`struct_gep`) and emit `index_gep` + `load`, without re-evaluating an object or
index expression with side effects. Do not add a backend peephole for this one
syntax shape; the IR should preserve the fact that the array already has
addressable storage.

Acceptance:

1. The standalone repro still exits 0 at `--opt 0` and `--opt 3`.
2. `sx_issue_0317_lookup` at `--opt 3` contains no 4096-byte stack frame and no
   whole-field copy; it is address arithmetic plus the requested element load.
3. Add a focused lowering/IR regression covering dynamic indexing through an
   array field on a pointer receiver. Include a side-effecting index/object
   control if the chosen storage recovery could evaluate either twice.
4. Run the normal unit and corpus suites, then resolve the issue using the
   repository's standard issue procedure.
