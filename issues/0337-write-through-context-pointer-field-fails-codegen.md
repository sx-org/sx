# 0337 — writes through a `#context_extend` pointer field's pointee fail LLVM emission

> **RESOLVED (2026-07-21).** Root cause: `lowerExprAsPtr` had no arm for the
> `context` identifier, so a context-rooted store target fell back to the
> VALUE load of the whole Context — `fieldLvaluePtr` then built a
> `struct_gep` whose base is a struct value, and `emitStructGep` requires an
> LLVM pointer base (reads never noticed: they extract from the value).
> Fix (`src/ir/lower/stmt.zig`): `context` as an lvalue root now yields the
> hidden `*Context` (`current_ctx_ref`), so member chains GEP the live
> context like any named pointer local and pointer-hop chains store into
> pointee memory. Companion semantic pin: a chain that does NOT cross a
> pointer hop would write the Context storage itself — `diagContextRootWrite`
> (shared by single- and multi-assign) rejects it ("the context is immutable
> within its scope; override it with `push`"). Regression:
> `examples/memory/0892-memory-context-ptr-field-writes.sx` (1-/2-hop ×
> read / write / compound / method mutation, alias visibility) +
> `examples/diagnostics/1270-diagnostics-context-field-write.sx` (direct
> writes rejected, incl. inline nested / array-index / multi-assign).

> **Symptom.** Reading through a context-carried pointer field works
> (`x := context.s.n`), but any WRITE through it fails codegen with an
> internal error — no diagnostic, hard stop:
> `error: LLVM emission failed for struct_gep in '<fn>': cannot resolve
> aggregate type for base ref %N; IR must provide base_type or
> recoverable aggregate pointer metadata`. Compound assigns (`+=`),
> plain assigns, and method calls that mutate through the chain
> (`context.sink.target.children.append(v)`) all hit it.

## Reproduction

```sx
#import "modules/std.sx";

S :: struct { n: i64; }

#context_extend s: *S = null;

read_hop  :: () -> i64 { context.s.n }   // OK
write_hop :: () { context.s.n = 5; }     // LLVM emission failed (struct_gep)

main :: () {
    v := S.{ n = 3 };
    push .{ s = @v } {
        print("{}\n", read_hop());
        write_hop();
    }
}
```

Longer chains fail identically (`context.sink.target.n += 1` with
`Sink :: struct { target: *S; }`).

## Expected

Writes through a context pointer field lower like writes through any
local pointer — `k := context.s; k.n = 5;` (the local-rebind spelling)
compiles and runs correctly today, so the store path itself is fine;
only the direct `context.<field>.<...> = ` chain loses the aggregate
base type.

## Actual

Internal LLVM-emission error, per-function, at compile time.

## Suspected area

Assignment-target lowering for member chains rooted at the `context`
builtin: the base ref for `struct_gep` lacks `base_type` metadata when
the chain starts at a context field load rather than a named local.
Adjacent to the gep-aggregate-control work pinned by
`examples/memory/0891-memory-gep-aggregate-control.sx`.

## Impact

Blocks any ambient-sink pattern over context (`#context_extend
sink: *Sink` + mutation through `context.sink`) — the Compose/imgui-style
emit model being explored for the UI direction (experiment/ui). The
corpus never writes through a context pointer field today, which is why
this went unnoticed (0887/0888 only read).
