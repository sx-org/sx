# 0030 — `extern G : T;` cross-file sx global declarations (feature request)

> A feature request, not a defect. `issues/0030-extern-global-declarations.sx`
> holds the source the form would have to parse; the compiler rejects it because
> the form does not exist.

## Symptom / request

Support an `extern G : T;` top-level form so a global **defined** in one sx
source file can be **referenced** from another without threading it through
parameters — mirroring how `extern` function declarations work (declared in one
place, defined elsewhere, resolved at link time).

```sx
// game/main.sx
g_metal_gpu : *MetalGPU = null;

// game/chess/pieces.sx
extern g_metal_gpu : *MetalGPU;          // ← the compiler rejects this form

load :: (self: *ChessPieces, path: [:0]u8) {
    inline if @host.os == .ios {
        tex := g_metal_gpu.createTexture(w, h, .rgba8, xx pixels);
    }
}
```

`pieces.load` takes `has_gpu: bool, gpu: GPU` params and `main.sx` threads them
through; cross-file `extern` globals would drop that ceremony. Distinct from the
`name : T extern;` form (an *external C* data symbol from libsystem etc. — see
`examples/ffi/1205-ffi-extern-global.sx`); this request is for sx-defined globals
shared across sx modules.

## Reproduction

`issues/0030-extern-global-declarations.sx`:

```sx
@import "modules/std.sx";
extern g_x : *void;          // want: a reference to a global defined elsewhere
main :: () -> i32 { 0; }
```

`./zig-out/bin/sx run …` → `error: expected '::', ':=', or ':' after identifier`
(the `extern` keyword/form is unparsed).

## Implementation sketch

- **parser** — surface syntax for `extern G : T;`. Must not clash with `G :: T;`
  (type alias), `G : T = ---;` (uninitialized global), `G : T;` (typed global).
  Reject `extern G : T = expr;` (an extern can't carry an initializer).
- **src/ir/lower.zig** — record an extern-global stub that resolves at
  module-link time.
- **src/ir/emit_llvm.zig** — emit an `external` LLVM global (no storage, just a
  reference). Globals already have first-class IR addresses; this adds an
  "extern" flag meaning "emit a reference, not storage."

## Caveat

Encourages process-global state. Steer callers toward explicit parameter passing
where reasonable; reserve for genuine process singletons (active GPU, active
platform) where threading through every call site is more noise than signal.
