# vendors/kb_text_shape — OpenType text shaping for sx programs

- Version: **v2.10** (version history at the top of the header)
- Source: <https://github.com/JimmyLefevre/kb> (`kb_text_shape.h`)
- License: zlib-style permissive (see the header's license block)
- Files: `c/kb/kb_text_shape.h` (the full upstream single-header,
  ~30k lines), `c/kb_text_shape_impl.c` (defines
  `KB_TEXT_SHAPE_IMPLEMENTATION` and includes it), and
  `c/kbts_api.h` — a hand-curated MINIMAL declaration header carrying
  only the bound surface, so decl synthesis never parses the full
  upstream header.

`#import "vendors/kb_text_shape/kb_text_shape.sx"` resolves through
the stdlib search paths; the implementation compiles once per machine
through sx's object cache. Shape contexts, fonts, runs, and glyphs are
opaque pointers on the sx side (modules/ui/glyph_cache.sx is the
reference consumer; `examples/1627-vendor-kbts-shape-context.sx` pins
context + font creation in the sx suite).

To upgrade: replace `c/kb/kb_text_shape.h` with a newer upstream copy,
extend `c/kbts_api.h` if the bound surface grows, update this file,
and rebuild (the object cache keys on source bytes).
