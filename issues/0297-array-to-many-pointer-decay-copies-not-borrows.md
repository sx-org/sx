# 0297 — `[N]T` → `[*]T` call-site decay passes a spilled copy (writes lost), and is refused outright at abi(.c) fn-pointer sites

## Symptom

specs.md §Pointer Types promises the implicit call-site decay
"`[N]T` → `[*]T` at call sites (array decays to many-pointer)" (line ~1266).
Decay semantics mean BORROWING the array's storage (like `[N]T` → `[]T`
slice coercion). Two defects against that contract:

1. **Silent miscompile — copy, not borrow.** Where the decay is accepted
   (default-conv direct calls; any call via `xx arr`), the callee receives a
   pointer to a SPILLED TEMPORARY copy of the array. Reads coincidentally
   work (the copy is faithful); **writes through the param land in the
   discarded copy** and never reach the caller's array. No diagnostic.
2. **Inconsistent refusal.** At an `abi(.c)` fn-pointer call site the same
   implicit decay is refused: `cannot coerce a value of type '[512]u8' to
   '[*]u8': no implicit conversion applies` — contradicting the spec line
   above and diverging from the (mis-lowered but accepted) default-conv path.

The probe matrix (all verified 2026-07-17):

| spelling | compiles? | callee's write lands? |
|---|---|---|
| `f(arr)` — default-conv direct call | yes | **no — lost** |
| `f(xx arr)` — direct or fn-pointer | yes | **no — lost** |
| `f(arr)` — abi(.c) fn pointer | **error** | — |
| `f(@arr[0])` (`*T` → `[*]T`, specs ~1259) | yes | yes ✓ |

Found while dispositioning local library edits: an application session hit
refusal (2) at the OpenGL fn-pointer globals and patched
`library/modules/ffi/opengl.sx` / `ui/renderer.sx` with `xx` — importing
silent-miscompile (1): `glGetProgramInfoLog(prog, 512, null, xx log_buf)`
writes the info log into a discarded temporary. Those sites are now spelled
`@buf[0]` (spec-idiomatic, borrows real storage, correct today and after the
fix); once this issue is fixed they can be simplified back to the bare
spelling the spec promises.

## Reproduction

```sx
#import "modules/std.sx";

sink : (u32, i32, *i32, [*]u8) -> void abi(.c) = ---;
take :: (n: u32, m: i32, p: *i32, buf: [*]u8) -> void abi(.c) { buf[0] = 65; }
take_d :: (buf: [*]u8) -> void { buf[0] = 66; }

main :: () {
    sink = take;
    log_buf : [512]u8 = ---;
    log_buf[0] = 1;

    // (2) refusal — spec says this decays implicitly:
    // sink(1, 512, null, log_buf);   // error: cannot coerce '[512]u8' to '[*]u8'

    // (1) accepted but write lost — prints 1, expected 66:
    take_d(log_buf);
    print("{}\n", log_buf[0]);

    // (1) same through xx — prints 1, expected 65:
    sink(1, 512, null, xx log_buf);
    print("{}\n", log_buf[0]);

    // control — the *T → [*]T spelling borrows correctly, prints 65:
    sink(1, 512, null, @log_buf[0]);
    print("{}\n", log_buf[0]);
}
```

Expected after the fix: bare `log_buf` compiles at EVERY call-site kind and
behaves exactly like `@log_buf[0]` (borrow, writes land); `xx arr` should
either mean the same borrow or be rejected — never a silent copy.

## Investigation prompt

Two coordinated fixes:

1. **Borrow, don't spill.** Wherever an `[N]T` value meets a `[*]T` param,
   the lowered arg must be the ARRAY's address (for an lvalue arg), not a
   copy's. The `[N]T` → `[]T` slice coercion already takes the storage
   address — mirror its lvalue discipline (likely in the coercion planner:
   src/ir/conversions.zig / coerceToType, and the `xx` cast path in
   src/ir/lower/expr.zig `cast()`). An RVALUE array arg (call result) has no
   caller-visible storage; passing a spill's address is then acceptable
   (writes are into a dead temporary by construction — same stance as slice
   coercion of temporaries, see issue 1230's diagnostic for the slice case;
   decide whether to mirror that refusal).
2. **Accept the decay at C-conv sites.** The `abi(.c)` fn-pointer arg path
   (src/ir/lower/call.zig resolveCallParamTypes / the coercion classify for
   `.many_pointer` targets) must classify `[N]T` → `[*]T` the same way the
   default-conv path does — one rule, every call-site kind (direct,
   fn-pointer, default- and C-conv).

Library restore list (sites bent while this was open — simplify to bare
array names after the fix): `library/modules/ffi/opengl.sx` create_program +
compile_shader (`@log_buf[0]`), `library/modules/ui/renderer.sx`
begin (`@proj.data[0]`). Same class, pre-existing on master and safe today
(read-only through the copy): `ui/renderer.sx` begin's Metal branch
`set_vertex_constants(1, xx proj.data, 64)` — reads 64 B through a spilled
copy's address; convert alongside the others when the fix lands.

Verification: the repro prints 66/65/65 with the refusal line uncommented
compiling too; add a regression example (memory or ffi block) covering the
four-row matrix incl. a WRITE through the decayed param on every call-site
kind; `zig build test` green.
