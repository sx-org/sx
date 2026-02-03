# 0283 — warnings are never shown unless compilation fails

## Symptom

`.warn` diagnostics are only rendered when compilation **fails**. Every
`renderErrors()` call site in `src/main.zig` sits inside a `catch { ... }`:

```zig
comp.parse()          catch { comp.renderErrors(); std.process.exit(1); };
comp.resolveImports() catch { comp.renderErrors(); std.process.exit(1); };
comp.generateCode()   catch { comp.renderErrors(); std.process.exit(1); };
```

There is no call on the success path, so a program that compiles cleanly
discards its warnings. Both `.warn` sites in the compiler are therefore dead in
the common case — a warning can only appear alongside an error, which is
precisely when it is least useful.

The two sites:

- `src/ir/error_analysis.zig:222` — "function '{s}' is declared `!` but never
  errors — drop the `!`"
- `src/ir/protocols.zig:239` — protocol declares type-arg and method with the
  same name

## Reproduction

```sx
#import "modules/std.sx";

alpha :: () -> ! { return; }   // declared `!`, never errors → should warn

main :: () -> ! {
    try alpha();
    print("done\n");
}
```

`sx run` prints `done` and exits 0. No warning, though `convergeInferredErrorSets`
did add one to the DiagnosticList.

## Diagnosis

`DiagnosticList` collects the warning correctly; nothing ever renders it.
Confirmed by temporarily adding `self.diagnostics.renderStderr()` after the
`hasErrors()` gate in `core.zig::generateCode` — the warning then appears.

## Blast radius of a fix

**Zero snapshot churn.** With rendering temporarily enabled, the full corpus
still passed and emitted *zero* warning lines. Neither `.warn` site
fires on any example, which also means both paths have **no test coverage at
all** — nothing in the corpus would notice if they broke.

## Fix sketch

Render on the success path (in `core.zig` after the `hasErrors()` gate, or in
each `main.zig` pipeline site), so warnings surface on a clean compile.

**This is safe to fix on its own.** [[0284]] — which made emission order depend on
hashmap iteration, and would have turned this fix into scrambled diagnostic output
— is RESOLVED. Warnings now emit in source order, so rendering them is the only
change this issue needs. Add corpus coverage for both `.warn` sites while you are
here; today neither fires on any of the 998 corpus tests.

## Status

OPEN — filed during the pre-port stress sweep. Deliberately not fixed: it is a
user-visible output change, and the port ([[../PORT_PLAN.md]]) reproduces the
current behaviour faithfully either way. Worth fixing before the warn paths are
transliterated, since they port with zero oracle coverage.
