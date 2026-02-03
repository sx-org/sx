// Minimal API declarations for SX import.
// Only the functions/types we actually use — avoids parsing the full 30k-line header.

typedef struct kbts_shape_context kbts_shape_context;
typedef struct kbts_font kbts_font;

kbts_shape_context *kbts_CreateShapeContext(void *Allocator, void *AllocatorData);
void kbts_DestroyShapeContext(kbts_shape_context *Context);
kbts_font *kbts_ShapePushFontFromMemory(kbts_shape_context *Context, void *Memory, int Size, int FontIndex);
void kbts_GetFontInfo2(kbts_font *Font, void *Info);
void kbts_ShapeBegin(kbts_shape_context *Context, unsigned int ParagraphDirection, unsigned int Language);
void kbts_ShapeUtf8(kbts_shape_context *Context, const char *Utf8, int Length, unsigned int UserIdGenerationMode);
void kbts_ShapeEnd(kbts_shape_context *Context);
int kbts_ShapeRun(kbts_shape_context *Context, void *Run);
int kbts_GlyphIteratorNext(void *It, void **Glyph);
