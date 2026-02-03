# Context extension — `#context_extend` (design)

Status: **DESIGN SETTLED + STRESS REVIEW PASSED 2026-07-19** (rulings
by Agra; review findings below — no design changes required, all
findings are implementation guidance). Execution slots into the LANG
stream as its own unit chain; PLAN-UI Wave 1 (the ui state store's
`context.ui` carriage) sequences behind it.
LANDED — ALL FOUR UNITS (chain COMPLETE 2026-07-19):
context-parser-collection; context-assembly-defaults (assembly,
`__sx_default_context` from evaluated defaults, L9 `data` removal, O3
registered-field diagnostic, positional-access audit fixed by-name);
context-lsp (definition/hover/completion/references via sema's member-ref
index; whole-context hover); context-stdlib-retrofit (L8 — allocator/io as
ordinary declarations in mem.sx/io.sx, EMPTY Context struct = pure mode
marker, full L6 no-prefix assembly). Two rulings landed with L8 (Agra,
2026-07-19): erasure defaults are spelled WITHOUT `xx` (bare identifier at
the protocol-typed position; the declared type states the conversion), and
the folded constant ALWAYS borrows the instance global — no stateless
null-receiver special case (null ctx is exclusively the `?Protocol` absent
sentinel).

## Motivation

The Context is sx's dynamically-scoped capability bag
(`{allocator, data, io}` today, threaded as the hidden `__sx_ctx`
pointer param, spread+patched by `push`). Three pressures want it
extensible:

- the ui library's state store (`context.ui` — PLAN-UI D1 ruling:
  Option B state, ambient carriage),
- cross-cutting std concerns already squatting the untyped `data` slot
  (the spec's own `push .{ data = xx @logger }` example),
- **user libraries** with their own ambient concerns (frame stats, a
  tracer, a job system) — no stdlib gatekeeping.

Explored options (conversation, 2026-07-19): X1 module-declared
assembly (CHOSEN) · X2 app-declared struct + `#context` directive ·
X3 typed runtime chain (rejected: can't reach field spelling without
compiler work; O(depth) walks; reserves `data`; depends on open 0298).

## Locked decisions (binding)

- **L1 — mechanism**: `#context_extend` top-level declarations (X1,
  Jai-precedent). Any module — stdlib or user — declares the field it
  carries:
  ```sx
  #context_extend ui: ?*Ui = null;
  #context_extend frame_stats: FrameStats = .{};
  ```
  The compiler assembles the program's `Context` struct from every
  declaration in the compilation — nothing else (no builtin prefix;
  see L6/L8/L9).
- **L2 — push semantics unchanged**: `push .{ field = v } { … }` stays
  spread+patch (seed from ambient, overwrite named fields) — added
  fields patch exactly like builtin ones. No new push syntax.
- **L3 — access is global and unconditional**: after assembly the
  Context is ONE ordinary struct type; `context.field` works in any
  module of the program with **no import requirement**. Imports gate
  existence only (an uncompiled module contributes nothing — its
  field is an ordinary "no such field" error), never visibility.
  There is NO per-source scoping of context fields.
- **L4 — one flat namespace, loud collisions**: two `#context_extend`
  declarations with the same field name (including colliding with the
  builtin prefix names) are a hard compile error naming BOTH
  declaration sites. No merging, no own-wins, no per-source
  resolution — context fields are program-global infrastructure.
- **L5 — defaults are mandatory and comptime-evaluable**: a
  declaration without a default is a compile error ("the default
  context must be constructible before `main` runs"). Defaults fold
  into the emitted `__sx_default_context` constant — the stdlib's own
  fields (allocator/io, post-L8) carry theirs as spellable sx
  constants like everyone else. `?T = null` is the expected idiom for handle
  fields; the root `push` in `main` is the documented wiring idiom for
  real values.
- **L6 — deterministic layout**: there is NO primordial prefix — the
  Context is 100% assembled from `#context_extend` declarations
  (allocator and io included, per L8; `data` is REMOVED, per L9),
  sorted by (declaring module path, field name). Reproducible builds;
  offsets stable within a program. No field has a guaranteed
  cross-program offset — every access, compiler-internal ones
  included, compiles against the assembled layout by name.
- **L7 — grammar**: `#context_extend <name> : <type> = <default> ;` at
  top level only. Directive space to be confirmed free in the stress
  review.

- **L8 — the stdlib retrofit (RULED 2026-07-19)**: `allocator` AND
  `io` move to `#context_extend` declarations in their owning modules
  (`#context_extend allocator: Allocator = …` beside the Allocator
  machinery in core/mem; `#context_extend io: Io = …` in std/io.sx) —
  the stdlib eats its own mechanism (and `data` is gone per L9 —
  no primordial fields remain). Zero consumer churn (spelling stays
  `context.allocator` / `push .{ allocator = … }`). Riders for the
  stress review: (a) the default values — the CAllocator/CBlockingIo
  thunk tables the compiler emits today — must become SPELLABLE sx
  comptime constants (an identity erasure of a global impl value),
  which the L5 rule must cover; (b) audit the compiler for any
  hardcoded context field INDEX (e.g. closure-env allocation reaching
  allocator positionally) — every internal access must go through the
  assembled layout by name.
- **L9 — `data` is REMOVED (RULED 2026-07-19)**: the untyped `*void`
  slot does not survive the cutover — typed `#context_extend` fields
  are the only mechanism. Lands ATOMICALLY with the feature (the slot
  is in use today; the replacement must exist in the same landing).
  Migration surface (measured): library consumers
  `ui/pipeline.sx` (`data = context.data` pass-through — simply
  deletes), `ui/glyph_cache.sx` and `std/sched.sx` (each moves its
  payload to an own typed field); examples 0803 / 1602 / 1804 / 1822 /
  1827 (each migrates to a `#context_extend` field, which makes them
  the feature's first pins); specs §push / §context passages rewrite
  (the `data = xx @logger` example becomes the logger field it always
  wanted to be).
- **L10 — `#context_default` PARKED (ruled 2026-07-19, final)**: after
  full exploration (patch literal → comptime builder function
  `(base: Context) -> Context` — see the conversation record), the
  directive is NOT built. Rationale: a program-wide default override
  only beats the root `push` in `main` for code running BEFORE main
  (early JNI callbacks, pre-push threads, comptime) — a corner not
  worth a second mechanism; a runtime builder was rejected outright
  (life-before-main). The defaults story is TWO layers:
  per-declaration defaults (L5) → the root `push` in `main` for the
  app's real values. If the pre-main corner ever bites, the comptime
  builder shape (base-in/context-out, VM-run, folded into the
  constant) is the recorded revival path.


- **~~O3 — no-context builds~~ RULED (2026-07-19)**: no-context
  builds stay supported. An `#context_extend` DECLARATION is inert
  there (a library carrying one stays importable from freestanding
  code); USING the context (`push`, `context.field`) keeps erroring —
  and the diagnostic now **enumerates the full registered field list
  with each field's declaring module**, so the user sees exactly what
  the program's context would have been and what is demanding it:
  ```
  error: `context.ui` requires the implicit context, which this build disables
    registered context fields:
      allocator: Allocator   — modules/std/mem.sx
      io:        Io          — modules/std/io.sx
      ui:        ?*Ui        — modules/ui/pipeline.sx
  ```

## Stress review (2026-07-19) — PASSED, findings recorded

Probes in `.sx-tmp/sr-p*.sx`; all against master at the review date.

1. **Grammar space FREE.** The spelling errors loudly today
   ("expected identifier at top level"); the lexer is an exact-string
   hash-token table (lexer.zig ~92) and top-level directives dispatch
   in parser.zig ~90–130 — one new token + one parser arm, no prefix
   conflicts, no ambiguity. (`#context_default` was probed free too,
   then PARKED per L10.)
2. **Positional-access audit (L8 rider b) — REAL, 4 sites + the
   builder.** `allocViaContext` reads allocator at `fields[0]` /
   `structGet(ctx, 0)` (call.zig:1884–86); same pattern at
   objc_class.zig:896 and :1178 and ffi_objc.zig:312. All four must
   resolve the field BY NAME against the assembled layout. The
   positional default-constant builder (protocol.zig:253–306,
   `ctx_fields[0/1/2] = {allocator, data, io}`) is REPLACED wholesale
   by the assembly emission.
3. **Spellable defaults (L8 rider a) — real gap, probe-confirmed.**
   `g_alloc : Allocator = xx g_gpa;` at global scope errors today
   ("must be initialized by a compile-time constant"). The retrofit
   needs the comptime evaluator to fold an identity erasure of a
   global into a constant `{ctx = &global, type_id, thunk ptrs}` —
   exactly the constant the bespoke builder already emits. Scoped to
   the retrofit unit; the BASE mechanism is unaffected (ordinary value
   defaults — `?*T = null`, small structs — need nothing new).
4. **No-context builds: mode is DETECTED, not flagged.**
   `implicit_ctx_enabled = detectContextDecl(decls)` — freestanding =
   no `Context` struct declared. Consequence: the collection pass runs
   UNCONDITIONALLY (it powers the O3 registered-field diagnostic);
   assembly runs only when the Context decl exists. `#context_extend`
   declarations stay inert without it, per O3.
5. **Comptime-VM parity is free.** `materializeDefaultContext`
   (comptime_vm.zig:461) lays the emitted `__sx_default_context`
   constant into comptime memory — one source of truth; the VM follows
   the assembly automatically.
6. **Fiber/thread inheritance size-agnostic.** `f.dctx = context` is a
   typed whole-value snapshot (sched.sx:203); threads document their
   own discipline. Zero work.
7. **Reflection passes.** `type_info(Context)` reports the 3 fields
   today (probe sr-p7c); added fields ride free — assembly precedes
   table reads.
8. **LSP: literal-field navigation is NEW work.** Nothing indexes
   struct-literal field names today (push handling in server.zig is
   inlay-hint recursion only; `resolveStructMemberDef` serves
   namespace members, not literal fields). The LSP unit builds
   struct-literal field go-to-definition GENERALLY (a win for every
   struct literal), then threads Context per-field provenance on top.
9. **Unknown-field baseline is loud** ("field 'nope' not found on type
   'Context'"); the extension adds the registered-field list to it —
   one shared enumeration helper also serves the O3 diagnostic and
   `#context_default`'s unknown-field error.
10. **L9 migration surface re-confirmed** (3 library consumers, 5
   examples, the specs passages) and the fiber `.ir` golden shift
   stays the known reviewed regen class.

## Semantics notes (for the specs section)

- The hidden `__sx_ctx` param is a POINTER — assembly changes no call
  ABI. Costs: push copies a larger struct; `__sx_default_context`
  grows; field offsets are program-specific.
- **Cost model + field-size guideline (RULED 2026-07-19: guideline
  only, NO restriction or diagnostic).** Reads are a constant-offset
  load (size-independent); calls share the pusher's slot (zero copy);
  the ONLY growth cost is the spread-copy at `push` (~1.7 ns measured
  for today's 112-byte Context; ~+0.5 ns per +80 bytes) and the
  per-fiber context copy. Therefore the documented guideline: prefer
  one POINTER per concern (`?*Ui`, `?*Logger`) over fat inline values —
  a 2 KB inline field makes every push a 2 KB memcpy. Inline values
  stay fully legal (a small value type like a FrameStats or a theme
  handle is fine); the guideline ships in the specs section and the
  directive's doc comment, and the compiler never polices field size.
- Threads/fibers: unchanged — they already inherit by copying the
  spawner's whole context value (sched.sx `dctx`); added fields ride
  along.
- Comptime/`#run`: the VM executes under a context too; L5's
  comptime-const defaults keep one definition serving both the LLVM
  constant and the interpreter.
- Reflection: `type_info(Context)` naturally reports added fields —
  no special casing.

## LSP requirements (first-class, land WITH the implementation units)

The assembled Context must carry **per-field provenance**: each field
records the span + file of its declaring site (the `#context_extend`
statement; for the builtin prefix, the field decl in core.sx's
`Context` struct). The editor analyzer builds the same assembled
struct the compiler does (shared collection pass — never a second
implementation), then:

- **Go-to-definition** on a field name in a push literal —
  `push .{ ui = new_value }`, cursor on `ui` — navigates to the
  `#context_extend ui: …` declaration in its module. Same for
  `context.ui` member reads, and for builtin fields
  (`push .{ allocator = … }` → core.sx). Rides the existing
  struct-member resolution path (`resolveStructMemberDef`,
  server.zig) once provenance is threaded.
- **Hover** on a field: type + declaring module + the default value
  (`ui: ?*Ui = null — declared by modules/ui/pipeline.sx`).
- **Completion**: after `context.` and inside `push .{ ` — the full
  assembled field set with types.
- **References**: find-all-references on an `#context_extend` declaration
  lists every push-site and read of that field program-wide.
- The corpus **LSP sweep** (`src/lsp/corpus_sweep.test.zig`) stays
  green over the new examples; LSP unit tests for
  definition/hover/completion on added fields are part of the unit's
  acceptance, not a follow-up.
- Tooling recovery of X2's one advantage (the whole context visible in
  one place): an `sx ctx`-style dump / LSP hover enumerating the
  assembled struct with each field's declaring module.

## Implementation sketch (compiler areas)

1. Parser: the `#context_extend` directive → an ast decl node.
2. Program-index collection pass (the scanDecls/pass-0a family):
   gather all declarations, sort per L6, detect collisions per L4.
3. Context struct finalization: extend the registered `Context` struct
   BEFORE any lowering resolves it (`findByName("Context")` already
   the single authority — stmt.zig lowerPush, field access, hidden
   param typing all follow it).
4. `__sx_default_context` emission: builtin defaults + evaluated
   declaration defaults (comptime evaluator).
5. Diagnostics: collision (both sites), missing default, non-comptime
   default, O3's no-context error.
6. Riders: comptime VM parity, LSP (completion/hover), goldens — the
   fiber `.ir` snapshots print `__sx_default_context` and will shift
   once per layout change (known, reviewed regen class).

## Verification matrix (pins to land with the units)

- basic: declare in module A, read in module B **without importing A**
  (L3 pin), push-patch the field (L2), default visible pre-push (L5).
- collision: two modules same name → diagnostic pins (both-sites
  span); collision with builtin name.
- missing/non-comptime default → diagnostic pins.
- comptime: `#run` reads an added field's default.
- concurrency: fiber/thread spawn inherits a pushed added field.
- ir: one representative golden showing the assembled
  `__sx_default_context`.
- LSP: corpus sweep green + unit tests — definition from a push-literal
  field name AND from a `context.field` read to the `#context_extend`
  site (cross-file, declaring module NOT imported by the reader — the
  L3 pin's LSP twin); hover shows type/module/default; completion
  lists added fields.

## Consumers queued on this

- PLAN-UI Wave 1: `#context_extend ui: ?*Ui = null` in ui/pipeline.sx;
  the D1-B state store reads `context.ui` (B2 spelling, typed).
- std/log.sx: `#context_extend logger: ?*Logger = null` — retires the
  spec's `data = xx @logger` example.
- PLAN-TELEGRAM: theming (U13) becomes a context field with subtree
  overrides via ordinary `push` around child builds — D2 resolved by
  this mechanism, no separate environment store needed.


## Vault anchors (PM sync — see CLAUDE.md "Plans ↔ vault tasks")

| Unit | Vault task (id) |
|---|---|
| Design (this doc) | custom-context · `kyhuy12imrri9f92` |
| Stress review | context-stress-review · `sc5u9jermrrk2ull` |
| Parser + collection pass | context-parser-collection · `salhgeuzmrrk2ulm` |
| Assembly, defaults, data removal (L9) | context-assembly-defaults · `j3o2nfa7mrrk2uln` |
| LSP support | context-lsp · `nx7iwnammrrk2ulo` |
| allocator/io retrofit (L8) | context-stdlib-retrofit · `07kw2rvumrrk2ulp` |
