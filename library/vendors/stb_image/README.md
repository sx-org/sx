# vendors/stb_image — image decode/encode for sx programs

- stb_image: **v2.30**; stb_image_write: **v1.16** (version comments at
  the top of each header)
- Source: <https://github.com/nothings/stb> (`stb_image.h`,
  `stb_image_write.h`)
- License: public domain / MIT, dual (see the headers' license blocks)
- Files: `c/stb_image.h` + `c/stb_image_impl.c`, `c/stb_image_write.h`
  + `c/stb_image_write_impl.c` (each impl .c defines the
  `*_IMPLEMENTATION` macro and includes its header)

`#import "vendors/stb_image/stb_image.sx"` resolves through the stdlib
search paths; the decls (`stbi_load`, `stbi_load_from_memory`,
`stbi_image_free`, `stbi_write_png`, …) are synthesized from the
headers, and the implementation compiles once per machine through sx's
object cache. `examples/1625-vendor-stb-image-decode.sx` pins an
in-memory BMP decode in the sx suite.

To upgrade: replace the headers under `c/` with newer upstream copies,
update this file, and rebuild (the object cache keys on source bytes).
