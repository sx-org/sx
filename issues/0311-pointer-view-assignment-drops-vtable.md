# 0311 — pointer → `*P` view in ASSIGNMENT position drops the vtable word; dispatch segfaults

> **RESOLVED (2026-07-18).** Fix: coerceMode materializes the borrowed view for pointer-to-concrete (and storage-provable struct) sources at *P targets — the node-less layer now agrees with the decl/arg arms; rvalue sources are refused.
> Regression test: `examples/protocols/0881-protocols-view-assignment.sx`.

## Symptom

Building a protocol view from a pointer-to-concrete works in
decl position but miscompiles in assignment position: only the ctx
word is stored, the vtable word is never written, and the first
dispatch through the view jumps into the wild.

```sx
p : *C = xx context.allocator.alloc_bytes(size_of(C));
v2 : *P = p;                    // decl position: OK — both words stored
g = p;                          // ASSIGNMENT to an existing *P: ctx
                                // stored, vtable word DROPPED
g.n();                          // EXC_BAD_ACCESS / Bus error
```

Observed (ARM64, m3te macOS binary): the assignment emits a single
`str ctx, [g_plat]` with no second store; the dispatch then reads the
"vtable" from `ctx + 0x10` (a random field of the concrete struct) and
`blr`s into garbage:

```
+144: str  x8, [x21, #0x518]   ; g_plat.ctx = s        (only store)
+148: ldr  x1, [x8]            ; arg = *(s)
+152: ldr  x8, [x9, #0x18]     ; x9 = *(s + 0x10)  ← NOT a vtable → boom
+156: blr  x8
```

Expected: assignment to a `*P` slot from a pointer-to-concrete stores
the same `{ctx, vtable}` pair the decl-position form produces — or, if
assignment-position view construction is meant to be refused (the spec
lists "parameters, annotated locals" as the implicit positions), a
compile error at the assignment. Accept-and-miscompile is the worst of
the three worlds.

Real-world shape: every m3te/chess platform global —
`g_plat : *Platform = ---;` then `g_plat = s;` in `main()` (`s:
*SdlPlatform`, `*UIKitPlatform`, `*AndroidPlatform`). The macOS binary
segfaults at `main+152` on the first `g_plat.begin_frame()`.

## Reproduction

```sx
#import "modules/std.sx";

P :: protocol {
    n :: (self: *Self) -> i32;
}

C :: struct { v: i32 = 42; }
impl P for C { n :: (self: *C) -> i32 { self.v } }

g : *P = null;

main :: () {
    c := C.{};
    v1 : *P = c;                       // lvalue decl: OK
    print("lvalue view   = {}\n", v1.n());

    p : *C = xx context.allocator.alloc_bytes(size_of(C));
    p.v = 7;
    v2 : *P = p;                       // pointer decl: OK
    print("ptr view      = {}\n", v2.n());

    g = p;                             // pointer ASSIGNMENT: miscompile
    print("global assign = {}\n", g.n());
}
```

Run: `sx run repro.sx` (HEAD c8235e32, 2026-07-18):

```
lvalue view   = 42
ptr view      = 7
Bus error at address 0x1f33cc308
```

## Investigation prompt

Suspected area: view construction lowering in assignment statements —
`src/ir/lower/stmt.zig` (assignment path) vs `decl.zig` (annotated-decl
path). The decl path builds the full `{ctx, vtable}` view; the
assignment path appears to take the plain pointer-assignment arm
(single word store) when the slot type is `*P`, never materializing
the vtable half.

What the fix likely needs:

1. In the assignment lowering, route pointer-to-concrete → `*P` slots
   through the same view-materialization the annotated-decl path uses
   (or reject the form with the demand diagnostic if assignment is
   deliberately out of the implicit set).
2. Regression coverage for the three shapes side by side: lvalue decl,
   pointer decl, pointer assignment — plus a global-slot variant (the
   m3te `g_plat` shape: module-level `g : *P` assigned inside a fn).

Verification: the repro prints 42 / 7 / 7 with no crash; then
`cd /Users/agra/projects/m3te && sx build main.sx && ./sx-out/macos/M3te`
reaches the frame loop instead of segfaulting at startup.
