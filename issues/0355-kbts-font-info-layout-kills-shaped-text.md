# 0355 — every non-ASCII string measures NaN and renders nothing

Status: FIXED 2026-07-25 — the `kbts_font_info2` binding declares its
string arrays at the upstream COUNT (13, was 7). Regression:
examples/ui/1932-ui-kbts-font-info-layout.sx.

## Symptom

Any text containing a byte ≥ 0x80 measured as NaN and drew nothing at
all — not a notdef box, not a partial run: the whole string vanished.
ASCII was unaffected, so the failure only appeared once real copy
reached the UI.

    probe("A B")    // w = 26.868442
    probe("A · B")  // w = NaN      — and nothing on screen
    probe("é")      // w = NaN
    probe("A—B")    // w = NaN

Reported by Agra from the sudoku game: the win screen's summary line
`"Medium · 7:51 · 0 mistakes"` was simply absent from the rendered
frame while the lines above and below it drew correctly.

## Cause

`glyph_cache.sx` bound `kbts_font_info2` with

    strings: [7]*void;
    string_lengths: [7]u16;

against an upstream `KBTS_FONT_INFO_STRING_ID_COUNT` of 13
(c/kb/kb_text_shape.h — NONE plus twelve named ids). The struct
therefore measured 112 bytes instead of 168.

`kbts_GetFontInfo2` dispatches on the caller-supplied `Size` field to
decide which version of the struct it may fill. 112 matches no version,
so it filled nothing and left the zeroed buffer alone — `units_per_em`
read back 0 for EVERY font, system or bundled.

`shape_with_kb` then computes

    scale : f32 = font_size / xx self.units_per_em;   // → +inf

and every glyph advance becomes `inf * 0` = NaN. `measure_text` sums
them to NaN, and a NaN-width text frame emits no geometry. ASCII never
reached this: `shape_text` routes it to `shape_ascii`, which scales
through stbtt and does not consult `units_per_em`.

## Fix

One named constant tied to the upstream enum, used for both arrays:

    KBTS_FONT_INFO_STRING_ID_COUNT :: 13;   // c/kb/kb_text_shape.h

`units_per_em` now reads 2048 for Inter and Arial alike, and shaped
runs measure and draw.

## Note

The version-dispatched-on-Size shape means a WRONG binding fails
silently by construction — the call succeeds, the buffer stays zeroed,
and the damage surfaces far away as a division. The regression pins the
two struct sizes rather than a shaping run, so it stays in the
byte-exact corpus (shaping needs a font and a GPU-backed atlas); any
future field edit that changes the layout trips it immediately.

Not addressed here: printing a NaN `f32` renders as
`00000000000000000000000000` rather than `nan`, which is what made the
measurement output hard to read while diagnosing this.
