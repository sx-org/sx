# vendors/stb_truetype — font parsing/rasterization for sx programs

- Version: **v1.26** (version comment at the top of the header)
- Source: <https://github.com/nothings/stb> (`stb_truetype.h`)
- License: public domain / MIT, dual (see the header's license block)
- Files: `c/stb_truetype.h` + `c/stb_truetype_impl.c` (the impl .c
  defines `STB_TRUETYPE_IMPLEMENTATION` and includes the header)

`#import "vendors/stb_truetype/stb_truetype.sx"` resolves through the
stdlib search paths; the decls (`stbtt_InitFont`,
`stbtt_ScaleForPixelHeight`, `stbtt_GetFontVMetrics`,
`stbtt_MakeGlyphBitmap`, …) are synthesized from the header, and the
implementation compiles once per machine through sx's object cache.
`stbtt_fontinfo` is opaque on the sx side: allocate a 256-byte blob
and pass its pointer (modules/ui/glyph_cache.sx is the reference
consumer; `examples/1626-vendor-stb-truetype-metrics.sx` pins font
init + metrics in the sx suite).

To upgrade: replace `c/stb_truetype.h` with a newer upstream copy,
update this file, and rebuild (the object cache keys on source bytes).
