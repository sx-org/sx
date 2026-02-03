# 0308 — `[*]T + n` pointer arithmetic reaches LLVM emission and fails verification instead of producing a diagnostic (or a GEP)

## Symptom

Adding an integer to a many-pointer (`[*]T`) is accepted by the front
end and crashes in LLVM emission:

```
LLVM verification failed: Integer arithmetic operators only work with integral types!
  %add = add ptr %load, inttoptr (i64 3 to ptr), !dbg !685
```

The lowering emits an integer `add` on a `ptr` value (with the integer
operand `inttoptr`-cast) instead of either a `getelementptr` (if pointer
arithmetic is meant to be supported) or a source-level error (if it is
not). specs.md §Pointer Types documents `[i]` indexing for `[*]T` but
says nothing about `+`/`-` arithmetic, so either resolution is
defensible — but an LLVM verifier abort is never the right answer.

Observed vs expected: a clean compile+run, or a proper
`error: no operator '+' for '[*]u8'` diagnostic pointing at the
supported idiom. The supported idiom today is address-of-element:
`q : [*]u8 = xx @p[3];` — verified working (m3te's Android WAV parser
uses it for chunk offsets).

## Reproduction

```sx
#import "modules/std.sx";

main :: () {
    a : [8]u8 = .[1, 2, 3, 4, 5, 6, 7, 8];
    p : [*]u8 = @a[0];
    q := p + 3;
    print("q[0] = {}\n", q[0]);
}
```

Run: `sx run repro.sx` → LLVM verification failure (HEAD 0096235b,
2026-07-18). Expected: `q[0] = 4`, or a clean compile error at the `+`.

## Investigation prompt

Suspected area: binary-operator lowering for pointer-typed operands —
`src/ir/lower/` arithmetic emission (the `+` arm lowers both operands
as integers without a pointer case, so the ptr value is `inttoptr`'d
into an integer add that LLVM rejects).

What the fix likely needs (pick per the language's intent):

1. **If `[*]T + n` is meant to work** (natural for a "buffer" pointer):
   lower it as `getelementptr T, ptr p, i64 n` (element-scaled), with
   `p - q` (same-element pointer difference) as the matching subtraction
   form. Document in specs.md §Pointer Types.
2. **If it is meant to be refused**: diagnose at the type-check /
   lowering stage with a message that names the alternative —
   e.g. `error: pointer arithmetic is not supported on '[*]u8'; use
   '@p[n]' (address-of-element) for an offset pointer`. The generic
   LLVM abort must not be reachable for any operand shape (also check
   `*T + n`, `ptr - int`, and the `+=` forms — they presumably share
   the same lowering path).

Verification: the repro above either prints `q[0] = 4` (option 1) or
fails with the new diagnostic at the `+` line (option 2); `zig build
test` stays green; m3te's `audio_android.sx` (`sx build --target
aarch64-linux-android26 main.sx` in /Users/agra/projects/m3te) still
compiles — it currently uses `@buf[i + 8]` and would simplify to
`buf + i + 8` under option 1.
