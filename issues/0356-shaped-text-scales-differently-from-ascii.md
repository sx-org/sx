# 0356 — one font_size, two sizes: shaped text scales differently from ASCII

Status: FIXED 2026-07-25 — `shape_with_kb` scales through
`scale_for_size`, the same font-unit scale the ASCII path and the
rasterizer use. Regression:
examples/ui/1933-ui-shaped-ascii-scale-parity.sx.

## Symptom

Adding one non-ASCII character resized the entire string. The same
glyphs, at the same `font_size`, measured 1.21× wider once the run went
through the shaper (Inter, 20pt):

    measure_text("AB",  20.0).width          = 22.219532   // stbtt path
    measure_text("AB·", 20.0).width - dot    = 26.884765   // kbts path
                                               ratio 1.2100

On screen a line like `"Medium · 7:51 · 0 mistakes"` rendered visibly
larger and looser than its neighbours set at the same size — reported
by Agra from the sudoku game's win screen, where it sat directly above
a pure-ASCII line and the mismatch was obvious.

## Cause

The two paths disagreed on what `font_size` scales:

- `shape_ascii` — `stbtt_ScaleForPixelHeight(font, font_size)`, i.e.
  font_size is the ASCENT-TO-DESCENT height;
- `shape_with_kb` — `font_size / units_per_em`, i.e. font_size is the EM.

kbts and stbtt both report advances in font design units, so the two
are the same quantity scaled two different ways. For Inter the hhea
span is ~2478 units against an em of 2048 — exactly the 1.21 observed.
The rasterizer uses the stbtt scale, so shaped runs were also
positioned against advances that did not match the bitmaps being drawn.

Which path a string takes is decided per RUN, not per glyph
(`shape_text` tests `is_ascii` on the whole string), so the resize was
all-or-nothing and looked like a styling mistake rather than a metrics
bug.

## Fix

`shape_with_kb` takes `self.scale_for_size(font_size)` — the single
font-unit scale. Identical glyphs now measure identically through
either path (parity to < 0.01px).

`units_per_em` stays on GlyphCache as font metadata; it is no longer on
the measurement path. It is still filled from the kbts info struct
whose layout issue 0353's sibling — issue 0355 — repaired, and the
layout pin there still guards that struct.

## Note

The em-vs-hhea distinction is exactly the kind of thing two independent
scale sites will keep drifting on. `scale_for_size` is now the only
font-unit scale in the module; a future third shaper should route
through it rather than recompute.
