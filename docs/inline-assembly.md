# Inline Assembly in sx

A guide to writing inline assembly in sx — emitting raw target
instructions, wiring values in and out, writing through memory, and
defining whole routines in assembly.

> Looking for the *why* behind the design (how it maps to LLVM, the
> Zig comparison, the emit algorithm)? That lives in
> [inline-asm-design.md](../design/inline-asm-design.md). This page is the
> user-facing how-to.

---

## The mental model

`asm` is an **expression**. It drops to the machine: you write a
template of real instructions, declare which sx values feed registers
going in and which come back out, and the block evaluates to the
output value (or a tuple of them).

```sx
add :: (a: i64, b: i64) -> i64 {
    return asm { "add %[out], %[a], %[b]", [out] "=r" -> i64, [a] "r" = a, [b] "r" = b };
}
```

Three things to know up front:

1. **The body is a brace block of comma-separated parts:** the template
   string first, then operands, then an optional `clobbers(.…)` clause.
2. **Each operand is tagged by role**, not by position: `-> Type` is a
   value output, `= expr` is an input, `-> @place` writes through to
   existing storage. The list is flat and order-independent — there are
   no positional `:` sections.
3. **The outputs decide the result.** Zero outputs → `void` (and the
   block must be `volatile`); one → that type; many → a tuple.

Templates are **AT&T syntax** (lowered through LLVM), **target-specific**,
and **never run at compile time** — see [When it runs](#when-it-runs).

---

## Operands

An operand is `[name]? "constraint" <role>`. The constraint string is
the LLVM/GCC-style constraint; the role marker says what the operand
does.

### Inputs — `= expr`

`= expr` feeds a value in. The constraint picks where it lands:

```sx
[a] "r"     = a      // any general register
"{rdi}"     = fd     // pinned to a specific register (x86_64 rdi)
```

### Symbol inputs — `"s" = fn`

A `"s"` input feeds a **function or global symbol** (not a runtime value).
In the template, `%[name]` expands to the symbol's **platform-mangled
name**, so you can branch or call straight to it:

```sx
cb :: (n: i64) -> i64 export "cb" { return n + 1; }

trampoline :: (n: i64) -> i64 {
    return asm volatile {
        #string ASM
        mov x0, %[arg]
        bl %[fn]            // DIRECT call — `bl _cb` on macOS, `bl cb` on Linux
        mov %[res], x0
ASM,
        [res] "=r" -> i64,
        [arg] "r" = n,
        [fn]  "s" = cb,     // symbol operand
        clobbers(.x0, .x30, .memory),
    };
}
```

The same `%[fn]` works on **x86_64** — just the branch mnemonic differs:

```sx
return asm volatile {
    "call %[fn]",              // x86_64 — same portable %[fn]
    [ret] "={rax}" -> i64,
    "{rdi}" = n,
    [fn]   "s" = cb,
    clobbers(.rcx, .rdx, .rsi, .r8, .r9, .r10, .r11, .memory),
};
```

Two reasons to prefer this over passing a function *pointer* in a plain
`"r"` register and using an indirect `blr`/`call *`:

- **One fewer indirection** — a direct PC-relative branch, no pointer
  load into a register, and a predictable (non-indirect) branch.
- **Portable** — `%[fn]` is the same on every target; the backend emits
  the correctly-mangled name, so you never hardcode the macOS leading
  underscore *or* a per-arch operand modifier.

**How the portability works.** A bare `%[fn]` would render differently
per target — on x86 the symbol prints as `$cb` (an immediate `$`-prefix
that `call` rejects), while aarch64 prints it bare. So for a symbol (`"s"`)
operand the compiler **auto-injects LLVM's `:c` operand modifier** (`%[fn]`
→ `${N:c}`, "print the constant with no punctuation"). `:c` prints the
plain symbol on every target — equivalent to the GCC `:P`/`%P0` call-target
idiom on x86 (both emit the same `R_X86_64_PLT32` relocation) and a no-op
on aarch64. You can still override it with an explicit `%[fn:X]` if you
ever need a different rendering, but for a call/branch you never should.

The callee needs a stable, externally-linked symbol — i.e. `export`
(which also gives it the C ABI). A plain or `callconv(.c)`-only function
is `internal` and gets dead-code-eliminated, so the symbol won't link.
(A global-scope `asm { … }` routine has no operand list, so it can't use
a symbol operand — it references the literal symbol in its text.)

### Value outputs — `-> Type`

`-> Type` produces a value that becomes (part of) the block's result:

```sx
[out] "=r"    -> i64    // result in any register
"={rax}"      -> i64    // result pinned to rax
```

### Naming and `%[name]`

Inside the template, `%[name]` refers to an operand by its **effective
name**. An operand pinned to a register is **auto-named after that
register** — `"{rdi}"` is reachable as `%[rdi]`, `"={rax}"` as `%[rax]`
— so an explicit `[name]` is only needed:

- for a register-**class** operand (`"=r"`, `"r"`), which has no register
  to name it; or
- to give a pinned operand a name *different* from its register.

Two labels are rejected so names stay unambiguous:

- the **echo form** `[rax] "={rax}"` — the label just repeats the pin, so
  drop it (the operand is already `%[rax]`); and
- **duplicate** operand names.

In the template, `%%` is a literal `%`, and `%=` expands to a unique id
(handy for a local label that must differ across inlinings).

### The result type

The number of **value** outputs (`-> Type`) decides the block's type:

| `-> Type` outputs | result | example |
|---|---|---|
| 0 | `void` — must be `volatile` | `asm volatile { "dmb ish" }` |
| 1 | that type `T` | `x := asm { …, "=r" -> i64 }` |
| N | a **tuple**, fields named by each operand's name | `lo, hi := asm { … }` |

With multiple outputs you get real multiple return values — a named
operand becomes a named tuple field:

```sx
// aarch64 — split a value into low/high bytes
split :: (x: u64) -> (lo: u64, hi: u64) {
    return asm {
        #string ASM
        and %[l], %[x], #0xff
        lsr %[h], %[x], #8
ASM,
        [l] "=r" -> u64,        // → .lo   (operand 0)
        [h] "=r" -> u64,        // → .hi   (operand 1)
        [x] "r" = x,
    };
}
lo, hi := split(0x1234);        // (0x34, 0x12) = (52, 18)
```

---

## `volatile`

`asm volatile { … }` marks the block as having side effects, so the
optimizer won't move or delete it. It is **required whenever there are
no value outputs** — a result-less, non-volatile asm would be dead code.

```sx
barrier :: () { asm volatile { "dmb ish" }; }   // aarch64 full barrier
```

A block with outputs may still be `volatile` when its effects matter
beyond the returned value (e.g. a syscall).

---

## `clobbers(.…)`

`clobbers(.…)` is a dot-name list of registers and flags the asm trashes
that aren't already operands — so the register allocator keeps clear of
them:

```sx
clobbers(.rcx, .r11, .memory)   // x86_64 syscall trashes rcx, r11, and memory
clobbers(.cc)                   // condition flags
```

`.memory` means "this asm reads or writes memory the compiler can't see,"
and `.cc` means "the condition flags are modified."

---

## Writing through memory — `-> @place`

Sometimes the asm should write into existing storage (a local, a struct
field) rather than *return* a value. `-> @place` does that: the place
output does **not** join the result tuple. There are three forms,
distinguished by the constraint.

### Write-through — `= …` constraint

The asm computes a value into a register; sx stores it through the
place's address afterward.

```sx
compute :: () -> i64 {
    other : i64 = 0;
    main_val := asm volatile {
        #string ASM
        mov %[m], #5
        mov %[o], #37
ASM,
        [m] "=r" -> i64,        // value output → returned into main_val
        [o] "=r" -> @other,     // place output → stored through @other
    };
    return main_val + other;    // 5 + 37 = 42
}
```

A value output and one or more place outputs can mix freely; only the
value outputs build the returned tuple.

### Read-write — `+` constraint

A `+` operand is read **and** written: the place's current value is fed
in, the asm updates it in place, and the result is stored back.

```sx
// increment-in-place: x is loaded, the asm adds 1, the result is stored back
bump :: () -> i64 {
    x : i64 = 41;
    asm volatile { "add %[v], %[v], #1", [v] "+r" -> @x };
    return x;   // 42
}
```

### Indirect memory — `=*m` constraint

An `=*m` operand passes the place's **address** to the asm, which writes
through it directly (no register round-trip, no return slot):

```sx
// store 42 straight into x's storage
poke :: () -> i64 {
    x : i64 = 0;
    asm volatile {
        #string ASM
        mov x9, #42
        str x9, %[out]
ASM,
        [out] "=*m" -> @x,
        clobbers(.x9),
    };
    return x;   // 42
}
```

**The place must be mutable storage.** Taking the address of a scalar
`::` constant has no meaning — a scalar constant folds to its value and
has no storage — so `-> @SOME_CONST` is a compile error:

```
cannot take the address of constant 'SOME_CONST' — a scalar '::'
constant has no storage (use a '=' variable or a local copy)
```

---

## Multi-instruction templates

A single `"…"` string is one fragment. For several instructions, use a
multi-line string literal or sx's **`#string` heredoc**, which is
delivered **verbatim** — no escape processing — so you write assembly
exactly as it should appear:

```sx
serialize :: () {
    asm volatile {
        #string ASM
        mfence
        lfence
ASM,
    };
}
```

---

## Global (module-scope) assembly

A top-level `asm { … }` block is **global assembly** — template only
(no operands, no `volatile`), emitted as module-level assembly. It is
the place to define a whole routine in assembly. Symbols it defines are
reached from sx with a **lib-less `extern`** declaration:

```sx
asm {
    #string ASM
.global _my_add
_my_add:
    add x0, x0, x1
    ret
ASM,
};

my_add :: (a: i64, b: i64) -> i64 extern;

main :: () -> i64 {
    return my_add(40, 2);   // 42 — computed by the global-asm routine
}
```

Multiple global blocks concatenate in source order. (Symbol naming
follows the platform convention — a leading underscore on macOS, none
on Linux.)

---

## When it runs

Inline assembly is emitted into the program and runs at **runtime**,
under both execution paths:

- **`sx run` (JIT)** — the module is compiled to an in-memory object
  (the integrated assembler assembles your asm, including global blocks),
  then run. Both inline and global asm work.
- **`sx build` (AOT)** — same, into a native binary.

It does **not** run at **compile time**. A `#run` (comptime) call into a
global-asm symbol fails loudly:

```sx
COMPUTED :: #run my_add(40, 2);   // error: the symbol isn't linked yet at comptime
```

```
comptime extern call: symbol not found via dlsym
```

The comptime interpreter resolves `extern` calls against the host
process; a module-asm symbol only exists once the program is
assembled and linked, so call it at runtime, not in a `#run`.

---

## Cookbook

**Read a register** (no inputs):

```sx
stack_ptr :: () -> u64 {
    return asm { "mov %[out], sp", [out] "=r" -> u64 };   // aarch64
}
```

**x86_64 syscall** — `write(2)`, with pinned registers and clobbers:

```sx
sys_write :: (fd: i64, buf: *u8, count: i64) -> i64 {
    return asm volatile {
        "syscall",
        [ret] "={rax}" -> i64,      // bytes written, in rax
        "{rax}" = 1,                // SYS_write
        "{rdi}" = fd,
        "{rsi}" = buf,
        "{rdx}" = count,
        clobbers(.rcx, .r11, .memory),
    };
}
```

**x86_64 divmod** — one instruction, two outputs, returned as a tuple:

```sx
divmod :: (n: u64, d: u64) -> (quot: u64, rem: u64) {
    return asm {
        "divq %[d]",
        [quot] "={rax}" -> u64,
        [rem]  "={rdx}" -> u64,
        "{rax}" = n,  "{rdx}" = 0,  [d] "r" = d,
        clobbers(.cc),
    };
}
q, r := divmod(17, 5);              // (3, 2)
```

---

## Rules of thumb

- **`asm` yields a value.** Bind it (`x := asm { … }`), `return` it, or
  destructure a multi-output tuple (`a, b := asm { … }`). A block with no
  value outputs must be `volatile`.
- **Pinned operands name themselves.** `"{rdi}"` is `%[rdi]`; only add
  `[name]` for register-class operands or to rename. Don't echo a pin
  (`[rax] "={rax}"`).
- **`%%` for a literal percent; `%[name]` for an operand.** Templates are
  AT&T.
- **List everything you trash** in `clobbers(.…)` — scratch registers,
  `.cc`, and `.memory` if the asm touches memory the compiler can't see.
- **`-> @place` writes storage; pick the form:** `=` (compute then
  store), `+` (read-modify-write), `=*m` (write through the address).
  The place must be mutable — not a scalar `::` constant.
- **Global `asm { … }`** defines symbols; import them with a lib-less
  `extern`. They run under JIT and AOT, but **not** in a `#run`.
- **It's target-specific.** Gate or pick instructions per architecture;
  there is no portable instruction set.

---

## See also

- [inline-asm-design.md](../design/inline-asm-design.md) — the design rationale and
  LLVM mapping.
- `examples/16xx-platform-asm-*` — the full, runnable example matrix
  (basic in/out, tuples, the three `-> @place` forms, global asm, the
  x86_64 syscall, and the comptime-boundary guard).
- The "Inline Assembly" section of [readme.md](../readme.md) for a
  one-screen overview.
```
