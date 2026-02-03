# Inline Assembly for sx — Design Doc & Proposal

**Status:** proposal / not yet scheduled into a workstream
**Author:** research pass over the Zig compiler (`~/projects/zig`, 0.16-dev) + the sx compiler
**Scope:** how Zig implements inline assembly end-to-end, and a minimal-deviation proposal to bring the same model to sx.

> Guiding constraint for this doc: **mirror Zig's design; deviate only where sx's
> grammar or stdlib makes a 1:1 copy impossible, and call every deviation out
> explicitly with its justification.** Every deviation below is tagged
> **[DEVIATION]** with a reason.

---

## 0. TL;DR + feasibility

* **Feasible today, no new infrastructure.** sx already links LLVM (`build.zig:10`
  → `/opt/homebrew/opt/llvm@22`) and `@cImport`s `llvm-c/Core.h`
  (`src/llvm_api.zig:1-17`). That header exposes everything inline asm needs,
  reachable right now through `llvm_api.c.*`:
  * `LLVMGetInlineAsm(Ty, AsmString, AsmStringSize, Constraints, ConstraintsSize, HasSideEffects, IsAlignStack, Dialect, CanThrow)` — builds the asm callee (LLVM 19–22 share this 9-arg signature).
  * `LLVMInlineAsmDialectATT` / `LLVMInlineAsmDialectIntel`.
  * `LLVMBuildCall2(...)` — already used pervasively in `src/ir/emit_llvm.zig` (e.g. the Obj-C msgSend path) — calls the asm value like a function.
  * `LLVMAppendModuleInlineAsm(M, Asm, Len)` — module-level (global) asm.
* **The hard part is not codegen.** Codegen is ~80 lines of well-trodden LLVM-C.
  The real work is (a) the parser grammar, (b) a faithful port of Zig's
  *LLVM constraint-string assembly* and *`%[name]`→`$N` template rewrite*, and
  (c) Sema validation rules. All three are fully specified below.
* **Surface form (decided, §II.2):** `asm volatile { "tmpl", "=r" -> T, "r" = x, clobbers(.cc, .memory) }`
  — a brace block; `->` marks outputs / `=` marks inputs (no positional `:`
  sections); enum-literal `clobbers(.…)`; and N `-> Type` outputs return a
  **tuple** (sx has tuples — Zig caps at one output).
* **Inline asm is never comptime-evaluable.** The interpreter must bail loudly
  (`bailDetail`), per CLAUDE.md's "no silent unimplemented arms" rule.
* **One naming note:** sx already has a `sx asm <file>` *CLI subcommand*
  (`src/main.zig:203,386`) that emits a `.s` file. That is a compiler output
  mode, a different namespace from a language token. No conflict, but worth
  knowing so nobody confuses the two.

---

# PART I — How Zig implements inline assembly

All file references in Part I are under `~/projects/zig` (0.16-dev,
commit `3deb86bafd`). Parser/AST/AstGen live in `lib/std/zig/`; Sema/AIR/codegen
in `src/`.

## I.1 Surface syntax

The canonical example (`doc/langref/inline_assembly.zig`), a Linux x86_64 syscall:

```zig
pub fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : .{ .rcx = true, .r11 = true });
}
```

Grammar shape:

```
asm volatile? ( <template-string>
    : <output-item> , <output-item> , ...      # outputs   (optional section)
    : <input-item>  , <input-item>  , ...      # inputs    (optional section)
    : <clobbers> )                              # clobbers  (optional section)

output-item :  [name] "constraint" (-> Type)    # asm result becomes the value
            |  [name] "constraint" (lvalue)      # asm writes through the pointer
input-item  :  [name] "constraint" (expr)
clobbers    :  .{ .reg0 = true, .reg1 = true }   # struct literal (0.16-dev)
```

Key semantics (from `doc/langref.html.in:4217-4300`):

* **`volatile`** marks side effects. Without it, an asm expression whose result
  is unused may be deleted. An asm expression with **no outputs must be
  `volatile`** (else compile error).
* **x86/x86_64 use AT&T syntax** (LLVM provides the parser; Intel support is
  "buggy and not well tested").
* **`%[name]`** in the template refers to a named operand's register; **`%%`** is
  a literal `%`.
* **Clobbers** are registers the asm trashes that are *not* inputs/outputs.
  `"memory"` (the `.memory = true` field) means "writes to arbitrary memory."
  Failing to declare a clobber is unchecked illegal behavior.
* **Global assembly** = an `asm(...)` in a namespace-level `comptime` block. It
  has *different rules*: `volatile` is forbidden, there are **no inputs/outputs/
  clobbers**, no `%` substitution, and all global asm is concatenated verbatim:

  ```zig
  // doc/langref/test_global_assembly.zig
  comptime {
      asm (
          \\.global my_func;
          \\.type my_func, @function;
          \\my_func:
          \\  lea (%rdi,%rsi,1),%eax
          \\  retq
      );
  }
  extern fn my_func(a: i32, b: i32) i32;   // call into the global-asm symbol
  ```

## I.2 Pipeline, stage by stage

### Tokenizer — `lib/std/zig/tokenizer.zig`

Two keywords in the `StaticStringMap`: `.{ "asm", .keyword_asm }` and
`.{ "volatile", .keyword_volatile }`.

### AST — `lib/std/zig/Ast.zig`

Four node tags (`Ast.zig:3789-3817`):

* `asm_simple` — `asm(template)` only, no operands.
* `@"asm"` — full form; `data` is `node_and_extra` → (template node, `ExtraIndex` to an `Asm`).
* `asm_output` — `[a] "b" (-> Type)` or `[a] "b" (ident)`.
* `asm_input` — `[a] "b" (expr)`.

The "full" view the rest of the compiler consumes (`Ast.zig:2797-2809`):

```zig
pub const Asm = struct {
    ast: Components,
    volatile_token: ?TokenIndex,
    outputs: []const Node.Index,
    inputs: []const Node.Index,
    pub const Components = struct {
        asm_token: TokenIndex,
        template: Node.Index,
        items: []const Node.Index,       // outputs ++ inputs, interleaved order preserved
        clobbers: Node.OptionalIndex,    // a comptime expression (the struct literal)
        rparen: TokenIndex,
    };
};
```

The on-disk extra record (`Ast.zig:3969-3975`) stores `items_start/items_end`
(a span into the node list), `clobbers` (optional node), and `rparen`.

### Parser — `lib/std/zig/Parse.zig`

`expectAsmExpr` (`Parse.zig:2771-2838`) implements the grammar:

```zig
fn expectAsmExpr(p: *Parse) !Node.Index {
    const asm_token = p.assertToken(.keyword_asm);
    _ = p.eatToken(.keyword_volatile);
    _ = try p.expectToken(.l_paren);
    const template = try p.expectExpr();
    if (p.eatToken(.r_paren)) |rparen| { /* asm_simple */ }
    _ = try p.expectToken(.colon);
    // ... parse output items until a `:`/`)` ...
    const clobbers: Node.OptionalIndex = if (p.eatToken(.colon)) |_| clobbers: {
        // ... parse input items until a `:`/`)` ...
        _ = p.eatToken(.colon) orelse break :clobbers .none;
        break :clobbers (try p.expectExpr()).toOptional();   // clobbers = an expression
    } else .none;
    // ...
}
```

* `parseAsmOutputItem` (`Parse.zig:2840-2864`):
  `LBRACKET IDENT RBRACKET STRINGLITERAL LPAREN (MINUSRARROW TypeExpr | IDENT) RPAREN`.
* `parseAsmInputItem` (`Parse.zig:2866-2883`):
  `LBRACKET IDENT RBRACKET STRINGLITERAL LPAREN Expr RPAREN`.
* **Clobbers parse as a generic expression** (`(try p.expectExpr())`), not a
  string list — this is the 0.16-dev change. It is later coerced to a
  `std.lang.assembly.Clobbers` struct at Sema time.

### AST → ZIR — `lib/std/zig/AstGen.zig`

`asmExpr` (`AstGen.zig:8553-8669`) + `addAsm` (`12257-12310`). The ZIR payload
(`lib/std/zig/Zir.zig:2531-2564`):

```zig
pub const Asm = struct {
    src_node: Ast.Node.Offset,
    asm_source: NullTerminatedString,   // template (string-literal case)
    output_type_bits: u32,              // bit i = output i uses `-> T` (vs ptr)
    clobbers: Ref,                      // comptime ref → assembly.Clobbers value
    pub const Small = packed struct(u16) { is_volatile: bool, outputs_len: u7, inputs_len: u8 };
    pub const Output = struct { name: NullTerminatedString, constraint: NullTerminatedString, operand: Ref };
    pub const Input  = struct { name: NullTerminatedString, constraint: NullTerminatedString, operand: Ref };
};
```

AstGen already enforces the structural rules:

* Global (container-level) asm: rejects `volatile`, rejects any
  outputs/inputs/clobbers (`AstGen.zig:8583-8587`).
* Local asm: **"assembly expression with no output must be marked volatile."**
* `outputs.len < 16`, `inputs.len < 32` (fit `Small.outputs_len`/`inputs_len`).
* At most one output may use the `-> T` form ("inline assembly allows up to one
  output value"); `output_type_bits` records which.
* Two ZIR tags: `.@"asm"` (string-literal template) vs `.asm_expr` (comptime
  expression template).

### ZIR → AIR (Sema) — `src/Sema.zig`

`zirAsm` (`Sema.zig:15044-15231`, dispatched at `1396-1397`). This is where all
*semantic* validation happens. It:

* Resolves the template to a comptime string (`resolveConstString`).
* **Global asm** (`func_index == .none`): asserts no operands, then
  `zcu.addGlobalAssembly(owner, asm_source)` and returns `.void_value`.
* `requireRuntimeBlock` — local asm can't run at comptime.
* Per output: if `-> T`, resolve the type, `ensureLayoutResolved`, set the
  expression's result type; else resolve the operand pointer. Validates:
  * **output type has a well-defined in-memory layout** (else error);
  * **cannot output to a `const` pointer** (`"asm cannot output to const '{s}'"`);
  * output must be a runtime value (no reference to a comptime var).
* Per input: resolve operand, reject comptime-only refs, **coerce
  `comptime_int`→`usize`, `comptime_float`→`f64`**.
* Clobbers: coerce the expression to `std.lang.assembly.Clobbers`, resolve to a
  comptime value.

The AIR payload (`src/Air.zig:1485-1497`):

```zig
pub const Asm = struct {
    source_len: u32,
    inputs_len: u32,
    clobbers: InternPool.Index,         // comptime assembly.Clobbers value
    flags: packed struct(u32) { outputs_len: u31, is_volatile: bool },
};
// trailing: out operand refs, in operand refs, then the template bytes and
// (constraint\0 name\0) pairs packed into air_extra.
```

### AIR → LLVM — `src/codegen/llvm/FuncGen.zig`

`airAssembly` (`FuncGen.zig:2473-2852`) is the crux. **This is the algorithm sx
must port.** Three sub-tasks:

**(a) Assemble the LLVM constraint string.** Comma-separated. For each output:
emit `=` (write-only) or `+` (read-write, recorded in `llvm_rw_vals`); a `*`
prefix marks an *indirect* (memory) output passed as a pointer parameter; a
non-indirect output contributes to the return type. The user's leading `=`/`+`
in `constraint[0]` is consumed and re-emitted; the rest is copied with Zig
commas rewritten to LLVM `|` (alternative constraints). Inputs are copied
similarly (no `=`). Clobbers: iterate the `Clobbers` struct's bool fields as a
bigint; for each `true` field emit `~{fieldname}` (via `appendConstraints`,
which also expands target-specific aliases).

**(b) Rewrite the template** `%[name]` → LLVM positional `${N}` (state machine,
`FuncGen.zig:2735-2802`):

| input | output | note |
|---|---|---|
| `$` | `$$` | escape LLVM's `$` |
| `%%` | `%` | literal percent |
| `%=` | `${:uid}` | unique id |
| `%[name]` | `${N}` | `N` = position in `name_map` |
| `%[name:mod]` | `${N:mod}` | with modifier |

`name_map` maps each operand's `[name]` to its positional index across all
outputs+inputs.

**(c) Build & call.** Pick the LLVM function type:
`return_count == 0` → `void`; `== 1` → the single return type; `> 1` → an
anonymous struct of the return types. Then:

```zig
const call = try self.wip.callAsm(
    attributes, llvm_fn_ty,
    .{ .sideeffect = is_volatile },        // Assembly.Info: sideeffect/alignstack/inteldialect/unwind
    rendered_template, llvm_constraints, llvm_param_values, "");
```

`callAsm` (`lib/std/zig/llvm/Builder.zig:6131-6143`) is a thin wrapper that
builds the asm constant (`asmValue`) and emits a normal `call`. In LLVM-C terms
this is exactly `LLVMGetInlineAsm(...)` + `LLVMBuildCall2(...)`. Finally,
non-indirect outputs are read back: with one return it's the call result; with
several it's `extractvalue i` per output; indirect outputs were already written
by the asm via their pointer parameter.

### C backend — `src/codegen/c.zig`

No `airAssembly` for *inline* asm in the C backend in this tree; only global asm
flows out (as `module asm`). For sx this is irrelevant — sx only has an LLVM
backend.

### Global asm & naked functions

* **Global asm** bypasses everything above: `Sema.addGlobalAssembly` accumulates
  the verbatim source; the LLVM object emits it via the module-level asm string
  (LLVM-C: `LLVMAppendModuleInlineAsm`). Symbols it defines are reached with
  `extern fn`.
* **Naked functions** (`callconv(.naked)`) drop the prologue/epilogue; the body
  is entirely inline asm. This is an orthogonal calling-convention feature, not
  part of the asm expression itself.

---

# PART II — Proposal for sx

## II.1 Design principles

1. **Copy Zig's *semantic* model exactly**: a template + register/memory operands
   + clobbers + a `volatile` flag; AT&T syntax via LLVM; "no-output asm must be
   volatile"; `%[name]` substitution; AT&T-by-default.
2. **Copy the LLVM lowering exactly** (the constraint-string assembler + template
   rewriter from `FuncGen.zig` are reproduced verbatim in §II.6 — these are the
   parts where "inventing our own" would silently miscompile).
3. **Diverge from Zig's *surface* syntax where sx has a better-fitting idiom**, and
   only there. The deviations (§II.2) are deliberate: a brace block instead of
   `( … )`; `->`/`=` operand markers instead of positional `:` sections; an
   enum-literal `clobbers(.…)` list; and — because sx has tuples and Zig does not —
   **true multiple return values** instead of Zig's one-output cap.

## II.2 sx surface syntax

`asm` is an **expression** (it yields the output value/tuple), introduced by a new
`asm` keyword. The body is a **brace block** of comma-separated parts: a template
string first, then operands, then an optional `clobbers(.…)` clause. Each operand
is `[name]? "constraint" <role>`, where the role marker is:

* **`-> Type`** — an **output** that produces a value (joins the result).
* **`-> @place`** — an output that writes through to existing storage (Phase 2).
* **`= expr`** — an **input** (the value fed in).

`->` reuses sx's "produces" arrow (as in `(a: i32) -> i32`); `=` reuses sx's
"is set to" binding. There are no positional `:` sections.

```sx
// x86_64-linux — write(2) via syscall
sys_write :: (fd: i64, buf: [*]u8, len: u64) -> i64 {
    return asm volatile {
        "syscall",
        "={rax}" -> i64,              // output → the expression's value
        "{rax}"  = 1,                 // SYS_write
        "{rdi}"  = fd,
        "{rsi}"  = buf,
        "{rdx}"  = len,
        clobbers(.rcx, .r11, .memory),
    };
}

// read a register, no inputs, named operand for %[out]
sp :: () -> u64 {
    return asm { "mov %%rsp, %[out]", [out] "=r" -> u64 };
}
```

Multi-instruction templates use sx's existing **`#string` heredoc**
(`src/lexer.zig:402`) or a multi-line `"..."` literal — no new lexer feature:

```sx
serialize :: () {
    asm volatile {
        #string ATT
        mfence
        lfence
ATT,
    };
}
```

**Outputs and the result type.** A `-> Type` output contributes one value to the
asm expression's result; the count decides the shape:

| `-> Type` outputs | result | spelling |
|---|---|---|
| 0 | `void` (must be `volatile`) | `asm volatile { … }` |
| 1 | that type `T` | `x := asm { …, "=r" -> T };` |
| N | a **tuple** `(T1,…,Tn)` (declaration order) | `a, b := asm { … };` |

A `[name]` on an output becomes a **named tuple field** — the same name you'd use
for `%[name]` does double duty:

```sx
// sx has tuples, so asm gets real multiple return values (Zig caps you at one).
divmod :: (n: u64, d: u64) -> (quot: u64, rem: u64) {
    return asm {
        "divq %[d]",
        [quot] "={rax}" -> u64,       // → .quot   (operand 0)
        [rem]  "={rdx}" -> u64,       // → .rem    (operand 1)
        "{rax}" = n,
        "{rdx}" = 0,
        [d] "r" = d,
        clobbers(.cc),
    };
}
q, r := divmod(17, 5);                // q = 3, r = 2
```

### Deviations from Zig (each deliberate; semantics unchanged)

* **[DEVIATION 1 — brace block, not `( … )`.]** The asm body is `asm { … }`, a
  comma-separated brace block (trailing comma allowed, per `specs.md:226,501`),
  not Zig's parenthesised form. Braces read as "a block of code," which is what an
  asm template is; `#string` heredoc templates especially benefit. `asm` is a
  keyword, so `asm {` / `asm volatile {` is unambiguous.

* **[DEVIATION 2 — `->`/`=` operand markers, not `:` sections.]** Zig groups
  operands into positional `: outputs : inputs : clobbers` sections (count the
  colons; `: :` for an empty one). sx tags each operand by role instead — `-> Type`
  / `-> @place` (output) and `= expr` (input) — so the list is flat,
  order-independent, with no positional colons. *(`<-` for inputs was considered
  and rejected: it can't be a global token without mis-lexing `a < -b`; `=` reuses
  an existing token and the existing "binding" meaning.)*

* **[DEVIATION 3 — clobbers are an enum-literal list `clobbers(.cc, .memory)`.]**
  Zig 0.16 uses a struct literal `: .{ .rcx = true }` coerced to a per-arch
  `std.lang.assembly.Clobbers`; older Zig used a string list. sx uses a dot-literal
  list, cleaner than both. **v1:** each `.name` is a dot-name lowered straight to
  `~{name}` (`.memory`/`.cc` are recognized specials; register names pass through
  verbatim; LLVM validates). **Phase 4:** upgrade `.name` to members of a
  compile-time-checked per-arch `Clobber` enum — *same syntax*, gains typo-checking.
  Note the call-looking `clobbers(…)` is a declarative clause, **not** a call —
  nothing executes; it only feeds the register allocator.

* **[DEVIATION 4 — `volatile` is a *contextual* keyword.]** sx's keyword set
  (`specs.md:168`) has neither `asm` nor `volatile`. `asm` becomes a real keyword;
  `volatile` appears *only* right after `asm`, so it can be recognized contextually
  (a plain identifier everywhere else), avoiding reserving it globally. The surface
  is byte-identical to Zig. (Alternative: reserve globally — simpler lexer, small
  source-compat risk. Recommend contextual.)

* **[DEVIATION 5 — multiple value-outputs return a tuple (sx ⊃ Zig).]** Zig allows
  at most one `-> T` output; the rest must be pointer/lvalue outputs. sx has
  tuples, so N `-> Type` outputs return `(T1,…,Tn)` (named when operands are
  named), destructured with `a, b := …`. A deliberate *improvement* over Zig,
  enabled by a feature Zig lacks, and maps onto LLVM's existing multi-output
  struct return (§II.6). The other output flavor — `-> @place` write-through, plus
  read-write (`"+r" -> @place`) and indirect-memory (`"=*m"`) outputs — is
  **Phase 2** (needs indirect-constraint handling); the value-tuple form does not.

* **[DEVIATION 6 — global asm is a top-level `asm { … }` declaration.]** sx has no
  namespace-level `comptime {}` block (it has `#run`, `specs.md:2598`), so global
  asm is a top-level statement:

  ```sx
  asm {
      #string ATT
      .global my_func
      .type my_func, @function
      my_func:
        lea (%rdi,%rsi,1), %eax
        retq
ATT,
  };

  my_func :: (a: i32, b: i32) -> i32 extern;   // extern, no library — valid sx today
  ```

  Only the `comptime {}` wrapper is dropped; lowers to `LLVMAppendModuleInlineAsm`.

  **Calling the asm symbol reuses the C-FFI *import* path** (no new mechanism for
  v1). A lib-less `extern` fn declaration (its library is optional; used in 50+
  stdlib sites, e.g. `chdir :: (path: [*]u8) -> i32 extern;`) emits exactly the
  artifact needed to *call into* the asm symbol — an external-linkage,
  **C-calling-convention**, raw-named, link-time-resolved declaration — the same
  thing Zig's `extern fn` produces (also C-callconv). The reverse direction (asm
  calling *back into* an sx function) is handled by `export`, the define-and-expose
  dual of `extern`.

Everything *semantic* — comptime-known template, register/memory constraints
verbatim to LLVM, clobber meaning, "no-output ⇒ must be volatile," AT&T default,
`%[name]`/`%%` substitution — is **identical to Zig**. Only the surface (block,
`->`/`=`, `clobbers(.…)`, tuple returns) differs.

## II.3 sx AST

sx's AST is a pointer-based tagged union (`Data = union(enum)` at
`src/ast.zig:13`, nodes built via `Parser.createNode`), much simpler than Zig's
SoA `extra_data` scheme — so we can store slices directly. Add one arm to the
`Node.Data` union (`src/ast.zig:13`):

```zig
// in Node.Data union(enum):
asm_expr: AsmExpr,

// new node struct, alongside the other expression node defs:
pub const AsmExpr = struct {
    template: *Node,                  // string-literal / #string node (comptime string)
    is_volatile: bool = false,
    operands: []const AsmOperand,     // declaration order preserved (= %N indexing)
    clobbers: []const []const u8,     // dot-names from clobbers(.…): "rcx","cc","memory"
};

pub const AsmOperand = struct {
    name:       ?[]const u8 = null,   // optional [name]; only needed for %[name]
    constraint: []const u8,           // verbatim, e.g. "={rax}", "=r", "+r", "{rdi}", "r"
    role:       Role,
    payload:    *Node,                // out_value → Type node; out_place/input → expr node

    pub const Role = enum {
        out_value,   // `-> Type`     value output; N of these → a tuple result
        out_place,   // `-> @place`   write-through to existing storage (Phase 2)
        input,       // `= expr`
    };
};
```

A single flat `operands` list (not split into outputs/inputs) preserves source
order — what the `%0`/`%[name]` indices and the LLVM constraint order key off. The
result type is derived in Sema from the `out_value` operands (§II.5).

## II.4 sx parser

`asm` is parsed in expression position. sx dispatches primary expressions in
`Parser.parsePrimary` (`src/parser.zig`); add a `.kw_asm` case (mirroring how
existing keyword/`#`-directive expressions like `#run` are handled):

1. consume `asm`; contextually consume `volatile` if the next token is the word
   `volatile` (Deviation 4).
2. `expect(.l_brace)`; parse the first element as the **template** expression.
3. then a comma-separated list until `}`. Each element is either:
   * an **operand** — `[name]?` (a bracketed identifier), a string-literal
     constraint, then a role: `->` `Type` (out_value) · `->` `@`-place
     (out_place, Phase 2) · `=` `expr` (input); or
   * the **clobbers clause** — `clobbers` `(` `.`ident (`,` `.`ident)* `)`.
4. allow a trailing comma; `expect(.r_brace)`;
   `createNode(start, .{ .asm_expr = … })`.

The first element is unambiguously the template (a string not followed by a role
marker). `->` vs `=` after the constraint disambiguates output vs input; inside a
`->` target, a leading `@` marks a write-through place vs a type.

Top-level/global asm (Deviation 6): recognize `asm {` at declaration scope and
build a dedicated `asm_global` decl (template only — reject operands/`volatile`).

Lexer/token: add `kw_asm` to the `Token.Tag` enum + keyword `StaticStringMap` in
`src/token.zig`; `volatile` and `clobbers` stay out of the global table
(contextual). **No new operator tokens** — `->` (`arrow`), `=` (`equal`), `.`
(`dot`) and `{}` already exist.

## II.5 sx Sema / typing

* **Result type** from the `out_value` operands (`-> Type`), in declaration order:
  0 → `void` (and the asm **must** be `volatile`); 1 → that operand's type `T`;
  N → a tuple `(T1,…,Tn)`, **named** when the operands carry `[name]`s
  (`(name1: T1, …)`), positional otherwise. Implement in the expression typer
  (`src/ir/expr_typer.zig` / wherever `inferExprType` lives), returning the resolved
  `TypeId` (a tuple `TypeId` for N>1). **Do not** fall back to a silent default — an
  unresolvable output type is a real error (CLAUDE.md silent-default rule): emit a
  diagnostic and return the project's `.unresolved` sentinel.
* Port Zig's validation checklist (these are the user-facing error messages):
  1. no output operand ⇒ the asm **must** be `volatile`;
  2. each `out_value` result type must have a well-defined in-memory layout;
  3. inputs must be runtime values; coerce comptime int→`i64`, float→`f64`;
  4. template must be a comptime-known string;
  5. (Phase 2) `out_place` cannot write a `const`; indirect-memory rules.
* Every `%[name]` referenced in the template must name an operand (best surfaced as
  a Sema diagnostic; also caught at codegen during the rewrite — §II.6).

### Operand naming rule (auto-name from a `{reg}` pin) — DECIDED

The `[name]` label on an operand is purely an sx-surface convenience: it provides
the `%[name]` template alias and (for `out_value`) the result tuple's field name.
LLVM never sees it (it sees positional `${N}` + the constraint). To kill the
common redundancy where a label just echoes its pinned register
(`[eax] "={eax}"`), the **operand name is derived as follows**, uniformly across
every operand kind (`out_value` / `out_place` / read-write / `input`):

1. **Explicit `[name]` wins** — use it verbatim (the `%[name]` alias / field name).
2. **Else, if the constraint pins a single register** — `"={eax}"`, `"{rdi}"`,
   `"+{rax}"`, i.e. a `{reg}` body (optionally with a `=`/`+` prefix) — the operand
   is **auto-named after that register** (`eax`, `rdi`, `rax`). Usable as
   `%[eax]` and as the tuple field name.
3. **Else (register-class `=r`/`+r`/`r`, or memory `=m`, …)** — the operand has
   **no implicit name**. A `[name]` is then **required** if the template
   references it (`%[name]`) or, for `out_value`, if a named result field is
   wanted; otherwise it is anonymous (positional tuple field).

Corollaries:

* **Reject the echo form.** An explicit `[name]` that is identical to the
  register its own constraint pins (`[eax] "={eax}"`) carries no information —
  emit a diagnostic ("redundant operand name `eax` — it already names the pinned
  register; drop the `[eax]`"). The useful form is a label that *differs* from the
  register (`[quot] "={rax}"` → field `quot` over register `rax`).
* **Result field names** (the §II.5 result-type rule above) come from each
  `out_value`'s *effective* name — explicit `[name]`, else the auto-derived
  register name; positional only when neither exists (a class-constrained output
  with no `[name]`).
* This is a **typing-stage** rule: the parser still stores `name: ?[]const u8`
  (null when no `[name]` was written); Sema computes the effective name. No
  parser change.

Note: there is **no** "≤1 output" rule (that was Zig's limit; sx's tuples lift it).

## II.6 sx IR + LLVM codegen (the part that must match Zig bit-for-bit)

### IR op — `src/ir/inst.zig`

Add to `Op = union(enum)` (`src/ir/inst.zig:80`), next to `objc_msg_send`
(`:219`). Strings are interned (`StringId`, as `const_string` at `:85`); operands
are SSA `Ref`s:

```zig
inline_asm: InlineAsm,

pub const InlineAsm = struct {
    template:    StringId,                  // interned, RAW (rewritten at emit)
    operands:    []const AsmOperand,        // declaration order (= %N indexing)
    clobbers:    []const StringId,          // interned dot-names: "rcx","cc","memory"
    has_side_effects: bool,
    // result rides on Inst.ty: void / a scalar TypeId / a tuple TypeId (N outputs)
};

pub const AsmOperand = struct {
    role:       enum { out_value, out_place, input },
    name:       StringId,                   // .none when unnamed
    constraint: StringId,                   // verbatim "={rax}" / "=r" / "+r" / "{rdi}"
    operand:    Ref,                        // out_value → .none; out_place/input → the Ref
};
```

### Lowering — `src/ir/lower/expr.zig`

Add `.asm_expr => self.lowerAsmExpr(...)` to the `lowerExpr` dispatch. It interns
the template + constraint strings + clobber names, lowers each input operand to a
`Ref`, computes the result `TypeId` (§II.5), and emits the `inline_asm` op. (Same
shape as the existing `objc_msg_send` lowering.)

### Emit — `src/ir/emit_llvm.zig`

Add `.inline_asm => self.emitInlineAsm(...)` to the `emitInst` dispatch. This is a
**direct port of `FuncGen.airAssembly`**. Using the already-imported
`llvm_api.c`:

```zig
fn emitInlineAsm(self: *Emitter, inst: *const Inst, a: InlineAsm) void {
    // 1) result LLVM type + param types/values from constraints
    const ret_ty = self.lowerType(inst.ty);                 // void if no typed output
    var param_tys: ...; var args: ...;                       // one per `input` constraint
    // 2) assemble the LLVM constraint string  (see algorithm below)
    //    outputs first ("=..."/"+..."), then inputs, then "~{reg}" clobbers, comma-joined
    // 3) rewrite the template  %[name]->${N}, %%->%, %=->${:uid}, $->$$   (state machine below)
    const fn_ty = c.LLVMFunctionType(ret_ty, param_tys.ptr, n_params, 0);
    const asm_val = c.LLVMGetInlineAsm(
        fn_ty,
        rendered_template.ptr, rendered_template.len,
        constraint_str.ptr,    constraint_str.len,
        @intFromBool(a.has_side_effects),   // HasSideEffects (volatile)
        0,                                  // IsAlignStack
        c.LLVMInlineAsmDialectATT,          // AT&T (Deviation: none — matches Zig default)
        0,                                  // CanThrow
    );
    const result = c.LLVMBuildCall2(self.builder, fn_ty, asm_val, args.ptr, n_params, "");
    self.mapRef(inst, result);              // 1 output: the value; N: extractvalue i per out_value → tuple
}
```

(Optionally cache the asm value keyed by `(template, constraints, fn_ty)` the way
`emit_llvm.zig:167` caches `objc_msg_send_value` — but per-site construction is
fine; LLVM uniques inline-asm constants internally.)

**Constraint-string assembler (port of `FuncGen.airAssembly`):**

```
parts = []
for op in operands where role == out_value or out_place:    # outputs first
    parts.append( op.constraint with ',' replaced by '|' )   # "={rax}", "=r", "+r" …
for op in operands where role == input:
    parts.append( op.constraint with ',' replaced by '|' )   # "{rdi}", "r" …
for name in clobbers:                                        # from clobbers(.name,…)
    parts.append( "~{" + name + "}" )                        # "~{rcx}", "~{cc}", "~{memory}"
constraint_str = ",".join(parts)
```

LLVM return type follows the `out_value` count: **0** → `void`; **1** → that type;
**N** → an anonymous struct `{T1,…,Tn}` — after the call, `extractvalue i` per
`out_value` builds the sx tuple (the multi-return path, §II.2 Dev 5). `out_place`
outputs are `store`d through their `Ref` afterward instead.

For `sys_write` (one output): constraint
`={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}`, `fn_ty = i64 (i64,ptr,i64)`,
`args = [1, fd, buf, len]`, `sideeffect = true`. For `divmod` (two outputs):
`={rax},={rdx},{rax},{rdx},r,~{cc}`, `fn_ty = {i64,i64} (i64,i64,i64)`, and the two
`extractvalue`s become the `(quot, rem)` tuple.

**Template rewriter (port verbatim from `FuncGen.zig:2735-2802`):** state machine
over the template bytes with a `name_map: [name] -> positional index` built from
`outputs ++ inputs`:

```
state start:   '%' -> percent ;  '$' -> emit "$$" ;  else emit byte
state percent: '%' -> emit '%', start
               '[' -> emit "${", state input
               '=' -> emit "${:uid}", start
               else -> emit '%', emit byte, start
state input:   ']' -> emit name_map[name], emit '}', start
               ':' -> emit name_map[name], emit ':', state modifier
               else accumulate name
state modifier:']' -> emit accumulated modifier, emit '}', start
               else accumulate
```

An unknown `%[name]` is a hard error (mirror Zig's `todo`/diagnostic — **not** a
silent pass-through; CLAUDE.md no-silent-arms rule).

### Interpreter — `src/ir/interp.zig`

Inline asm cannot be comptime-evaluated. In the interpreter's op switch:

```zig
.inline_asm => return bailDetail("inline asm requires native execution; not available at comptime"),
```

(Same `bailDetail` pattern as the Obj-C/JNI ops — surfaces `op=inline_asm: ...`
rather than a silent default.)

### Global asm (Deviation 6)

Lower the top-level `asm_global` decl to a one-shot emit:
`c.LLVMAppendModuleInlineAsm(module, src.ptr, src.len)` (present in the linked
LLVM — `@19/include/llvm-c/Core.h:971`). No operands, no rewrite, no volatile;
multiple blocks concatenate in source order (as Zig does).

**Calling into an asm-defined symbol needs no new machinery** — declare it with a
lib-less `extern` (Deviation 6, §II.2): `my_func :: (sig) -> R extern;` emits
an external-linkage, raw-named, C-ABI extern that the linker resolves against the
`.global` the asm block defines.

**Guard (CLAUDE.md no-silent-arms):** a global-asm symbol exists only in the final
linked binary, not in the `#run`/JIT host process. The interpreter resolves
externs via `dlsym(RTLD_DEFAULT)` (`host_ffi.zig`), which won't find it — calling
such a symbol at comptime must fail **loudly** (it should already, via the
dlsym-miss diagnostic; pin it with a test). Edge case: a symbol referenced *only*
by other asm/external code may need `llvm.used` / `.no_dead_strip` to survive
dead-stripping; the common "sx references it" case is safe.

## II.7 Stage-to-file map (implementation checklist)

| Stage | Zig reference | sx file + insertion point | New code |
|---|---|---|---|
| Keyword | `tokenizer.zig` keywords | `src/token.zig` — `Token.Tag` + keyword `StaticStringMap` | `kw_asm` (+ contextual `volatile`) |
| AST node | `Ast.zig:2797,3789` | `src/ast.zig:13,85,721` — `Node.Data` + new `AsmExpr`/`AsmOperand` | ~25 lines |
| Parser | `Parse.zig:2771-2883` | `src/parser.zig` — `parsePrimary` `.kw_asm` case + global-asm at decl scope | ~120 lines |
| Sema/typing | `Sema.zig:15044` | `src/ir/expr_typer.zig` (`inferExprType`) + validation | ~80 lines |
| IR op | `Air.zig:1485`, `Zir.zig:2531` | `src/ir/inst.zig:80` — `inline_asm: InlineAsm` | ~25 lines |
| Lowering | `AstGen.zig:8553` | `src/ir/lower/expr.zig` — `lowerExpr` `.asm_expr` case | ~60 lines |
| LLVM emit | `FuncGen.zig:2473-2852` | `src/ir/emit_llvm.zig` — `emitInst` `.inline_asm` case | ~120 lines (constraint asm + template rewrite + `LLVMGetInlineAsm`/`BuildCall2`) |
| Global asm | `Sema.addGlobalAssembly` + `module asm` | decl lowering → `c.LLVMAppendModuleInlineAsm` | ~15 lines |
| Interp bail | n/a | `src/ir/interp.zig` op switch | 1 line |

No change to `src/codegen.zig` is needed (the IR/LLVM path owns this).

## II.8 Phasing

* **Phase 1 (MVP).** `asm { … }` block; `asm volatile`; string-literal/`#string`
  template; `= expr` inputs; `-> Type` outputs **including N→tuple multi-return**;
  `clobbers(.…)` dot-name list; `%[name]`/`%%` substitution; "no-output ⇒ volatile"
  check; AT&T. Target: Linux/macOS `x86_64` + `aarch64` syscalls, intrinsics, and
  multi-value ops (`divmod`, `cpuid`, `add_carry`).
* **Phase 2.** `-> @place` write-through outputs, read-write (`"+r" -> @place`) and
  indirect-memory (`"=*m"`) constraints, `%=` unique-id, output-to-const rejection.
* **Phase 3.** Global/module asm decl (`LLVMAppendModuleInlineAsm`) + the
  comptime-call guard, plus Intel-dialect opt-in. Small: the extern-call path
  already exists (lib-less `extern`).
* **Phase 4 (optional).** Upgrade `clobbers(.name)` from dot-name sugar to a
  compile-time-checked per-architecture `Clobber` enum (typo-checking; same syntax).
* **Phase 5 (optional).** Naked functions (`callconv`-equivalent) for full
  freestanding entry points.

## II.9 Testing

asm output is target-specific, so tests must pin a target and assert on
emitted IR/exit, not run host-natively unless the host matches. Use the existing
corpus harness and the **`16xx` platform block** (the closest fit in the
`XXXX-category` scheme; `specs.md`/CLAUDE.md test-layout). Mirror Zig's own
matrix:

* `examples/16xx-platform-asm-syscall-write.sx` — x86_64-linux write(2), assert exit/stdout.
* `examples/16xx-platform-asm-register-read.sx` — `mov %%rsp,%[out]`, no-input output.
* `examples/16xx-platform-asm-no-output-volatile.sx` — bare `asm volatile { "nop" }`.
* `examples/16xx-platform-asm-missing-volatile.sx` — **expected compile error**
  (no output, no volatile) — pins the diagnostic.
* `examples/16xx-platform-asm-template-subst.sx` — `%[a]`/`%%` rewriting, assert
  on the `sx ir`/`.s` snapshot.
* `examples/16xx-platform-asm-multi-return.sx` — `divmod` → `(quot, rem)` tuple, destructured.
* `examples/16xx-platform-asm-global.sx` (Phase 3) — global asm + extern call.

Add an IR/`.s` snapshot (`expected/*.ir`) for the substitution test so the
constraint-string + template-rewrite output is locked. Seed markers and
regenerate with `zig build test -Dupdate-goldens`, then review the diff
(CLAUDE.md snapshot-integrity rule).

## II.10 Open decisions for the user

Largely settled through design review; what remains:

1. **Dialect:** AT&T only (Zig's default) for v1, or expose an Intel opt-in
   (`LLVMInlineAsmDialectIntel`) from the start? **Recommend AT&T-only v1.**
2. **`volatile` keyword (Deviation 4):** contextual *(recommended, no
   source-compat risk)* vs globally reserved *(simpler lexer)*.
3. **Brace separator:** comma *(recommended — trailing-comma-friendly,
   literal-style)* vs `;` *(matches sx statement blocks)*.
4. **Asm-symbol extern spelling (Deviation 6): RESOLVED** — use the lib-less `extern`
   keyword to call *into* an asm symbol (import), and `export` for the reverse
   direction (an sx function asm can call *back into*). The dedicated linkage
   keywords landed (FFI-linkage stream), so no new surface is needed and both
   directions are covered.

*Decided:* brace block `{ … }` (Dev 1) · `->`/`=` markers, `:` sections dropped,
`<-` rejected (Dev 2) · `clobbers(.…)` enum-literal list, dot-name sugar now →
checked enum later (Dev 3) · multiple value-outputs return a tuple (Dev 5). For
global asm (Dev 6) the call-*into*-asm direction reuses lib-less `extern` (Decision
4, resolved).

## II.11 Risks

* **Constraint/template correctness is silent if wrong** — a bad constraint
  string miscompiles with no diagnostic. Mitigation: port Zig's assembler/rewrite
  verbatim (don't paraphrase) and lock IR snapshots in tests.
* **Register-name validity is unchecked** in v1's `clobbers(.name)` dot-name form —
  a typo'd register (`.raxx`) surfaces only as an LLVM error. This is exactly the
  gap the Phase-4 checked `Clobber` enum closes; acceptable for v1 (LLVM validates
  the emitted `~{…}`).
* **`#string` heredoc + AT&T `%`/`$`** interplay: ensure the heredoc delivers the
  template bytes literally (no sx-level escape processing of `%`/`$`) before the
  rewrite stage.
* **Target gating:** asm examples must declare their target or they break the
  corpus on other hosts; the test plan pins targets.

---

## Appendix A — exact LLVM-C calls (already reachable via `llvm_api.c`)

```c
// src/llvm_api.zig @cInclude("llvm-c/Core.h") exposes all of these:
LLVMValueRef LLVMGetInlineAsm(LLVMTypeRef Ty,
    const char *AsmString,   size_t AsmStringSize,
    const char *Constraints, size_t ConstraintsSize,
    LLVMBool HasSideEffects, LLVMBool IsAlignStack,
    LLVMInlineAsmDialect Dialect, LLVMBool CanThrow);   // LLVM 19 & 21: identical
LLVMValueRef LLVMBuildCall2(LLVMBuilderRef, LLVMTypeRef, LLVMValueRef Fn,
    LLVMValueRef *Args, unsigned NumArgs, const char *Name);
void LLVMAppendModuleInlineAsm(LLVMModuleRef M, const char *Asm, size_t Len);  // global asm
// enum: LLVMInlineAsmDialectATT, LLVMInlineAsmDialectIntel
```

## Appendix B — file index

**Zig (reference, `~/projects/zig`):** `lib/std/zig/tokenizer.zig` (keywords) ·
`lib/std/zig/Ast.zig:2797,3789,3969` (nodes) · `lib/std/zig/Parse.zig:2771-2883`
(grammar) · `lib/std/zig/AstGen.zig:8553-8669,12257` + `lib/std/zig/Zir.zig:2531`
(ZIR) · `src/Sema.zig:15044-15231` (validation) · `src/Air.zig:1485` (AIR) ·
`src/codegen/llvm/FuncGen.zig:2473-2852` + `lib/std/zig/llvm/Builder.zig:6131`
(LLVM) · `doc/langref/inline_assembly.zig`, `doc/langref/test_global_assembly.zig`
(syntax) · `doc/langref.html.in:4217-4300` (spec).

**sx (target, `~/projects/sx`):** `src/token.zig` · `src/lexer.zig:402` (#string) ·
`src/ast.zig:13` · `src/parser.zig` (`parsePrimary`), the optional `extern`
library tail · `src/ir/expr_typer.zig` · `src/ir/inst.zig:80,219,260` ·
`src/ir/lower/expr.zig` · `src/ir/module.zig:300` (`declareExtern`) ·
`src/ir/emit_llvm.zig:167` (msgSend cache), `:1244` (extern⇒C-ABI), `:1279`
(raw symbol name) · `src/ir/interp.zig` (`bailDetail`) · `src/llvm_api.zig:1-17` ·
`build.zig:10` (LLVM@19).

## Appendix C — Cookbook (final form: `asm { … }`, `->`/`=`, `clobbers(.…)`, pure AT&T)

```sx
// ── v1 ────────────────────────────────────────────────────────────────────

asm volatile { "nop" };                          // bare side-effecting

// write(2) syscall — register-pinned inputs, one value-output
sys_write :: (fd: i64, buf: [*]u8, len: u64) -> i64 {
    return asm volatile {
        "syscall",
        "={rax}" -> i64,
        "{rax}" = 1,  "{rdi}" = fd,  "{rsi}" = buf,  "{rdx}" = len,
        clobbers(.rcx, .r11, .memory),
    };
}

// mmap — full 6-arg syscall ABI (arg4 in r10, not rcx)
mmap :: (addr: *void, len: u64, prot: i32, flags: i32, fd: i32, off: i64) -> *void {
    return asm volatile {
        "syscall",
        "={rax}" -> *void,
        "{rax}" = 9, "{rdi}" = addr, "{rsi}" = len, "{rdx}" = prot,
        "{r10}" = flags, "{r8}" = fd, "{r9}" = off,
        clobbers(.rcx, .r11, .memory),
    };
}

// AT&T scaled-index addressing — arr[i]
load_idx :: (arr: *i64, i: u64) -> i64 {
    return asm {
        "movq (%[arr],%[i],8), %[out]",
        [out] "=r" -> i64,  [arr] "r" = arr,  [i] "r" = i,
    };
}

// CPUID AVX probe — immediates, heavy clobber set, single value-result
has_avx :: () -> bool {
    return asm volatile {
        #string ATT
        movl    $1, %%eax
        cpuid
        andl    $0x10000000, %%ecx
        setne   %[ok]
ATT,
        [ok] "=r" -> bool,
        clobbers(.rax, .rbx, .rcx, .rdx, .cc),
    };
}

// SSE packed add — xmm regs, no outputs ⇒ volatile
vadd4 :: (a: *f32, b: *f32, out: *f32) {
    asm volatile {
        #string ATT
        movups  (%[a]), %%xmm0
        movups  (%[b]), %%xmm1
        addps   %%xmm1, %%xmm0
        movups  %%xmm0, (%[out])
ATT,
        [a] "r" = a,  [b] "r" = b,  [out] "r" = out,
        clobbers(.xmm0, .xmm1, .memory),
    };
}

// ── multi-return (v1; sx has tuples, Zig caps at one output) ────────────────

// 64-bit divide → (quotient, remainder)
divmod :: (n: u64, d: u64) -> (quot: u64, rem: u64) {
    return asm {
        "divq %[d]",
        [quot] "={rax}" -> u64,
        [rem]  "={rdx}" -> u64,
        "{rax}" = n,  "{rdx}" = 0,  [d] "r" = d,
        clobbers(.cc),
    };
}

// rdtsc → two 32-bit halves, destructured straight out of the asm
rdtsc :: () -> u64 {
    lo, hi := asm volatile {
        "rdtsc",
        [lo] "={eax}" -> u32,
        [hi] "={edx}" -> u32,
    };
    return (xx hi << 32) | xx lo;
}

// cpuid → a clean 4-tuple
cpuid :: (leaf: u32, subleaf: u32) -> (eax: u32, ebx: u32, ecx: u32, edx: u32) {
    return asm volatile {
        "cpuid",
        [eax] "={eax}" -> u32,  [ebx] "={ebx}" -> u32,
        [ecx] "={ecx}" -> u32,  [edx] "={edx}" -> u32,
        "{eax}" = leaf,  "{ecx}" = subleaf,
    };
}

// add-with-carry → (sum, carry): value-output + tied input + flag capture
add_carry :: (a: u64, b: u64) -> (sum: u64, carry: u8) {
    return asm {
        #string ATT
        addq    %[b], %[sum]
        setc    %[carry]
ATT,
        [sum]   "=r" -> u64,
        [carry] "=r" -> u8,
        [a] "0" = a,  [b] "r" = b,
        clobbers(.cc),
    };
}

// ── Phase 2 (write-through / read-write / indirect) ─────────────────────────

// byte memcpy — labels, loop, read-write operands
memcpy_bytes :: (dst: [*]u8, src: [*]u8, n: u64) {
    d := dst;  s := src;  c := n;
    asm volatile {
        #string ATT
        testq   %[c], %[c]
        jz      2f
    1:  movb    (%[s]), %%al
        movb    %%al, (%[d])
        incq    %[s]
        incq    %[d]
        decq    %[c]
        jnz     1b
    2:
ATT,
        [d] "+r" -> @d,  [s] "+r" -> @s,  [c] "+r" -> @c,
        clobbers(.rax, .cc, .memory),
    };
}

// lock cmpxchg CAS — lock prefix, pinned read-write rax, two outputs
cas :: (ptr: *i64, expected: i64, desired: i64) -> bool {
    old := expected;  ok: bool = ---;
    asm volatile {
        #string ATT
        lock cmpxchgq %[desired], (%[ptr])
        sete    %[ok]
ATT,
        [ok]      "=r"     -> @ok,
        [old]     "+{rax}" -> @old,
        [ptr]     "r"      = ptr,
        [desired] "r"      = desired,
        clobbers(.cc, .memory),
    };
    return ok;
}

// fill an existing struct (write-through, no tuple)
cpuid_into :: (out: *CpuId, leaf: u32) {
    asm volatile {
        "cpuid",
        "={eax}" -> @out.eax,  "={ebx}" -> @out.ebx,
        "={ecx}" -> @out.ecx,  "={edx}" -> @out.edx,
        "{eax}" = leaf,
    };
}
```

Global asm + extern (Phase 3):

```sx
asm {
    #string ATT
    .global my_add
    my_add:
      lea (%rdi,%rsi,1), %eax
      retq
ATT,
};
my_add :: (a: i32, b: i32) -> i32 extern;       // lib-less extern = Zig's `extern fn`
```
