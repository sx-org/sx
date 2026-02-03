// Error return-trace buffer (ERR step E3.1).
//
// Thread-local fixed-cap ring of trace frames. A `raise` pushes one frame at
// the raise site; a `try` pushes one on its failure path; absorbing sites
// (`catch` / `or value` / destructure) clear it. The frame is an opaque
// `uint64_t` — the formatter (E3.3) dispatches on build context: at runtime a
// frame is a return-address PC (resolved via DWARF), at comptime it is a packed
// `(func_id, ir_offset)` (resolved via the interpreter's IR tables). The buffer
// neither knows nor cares which; it just stores u64s.
//
// Lives in a separately-linked C helper (NOT an emitted `thread_local` IR
// global) for the same reason as `sx_jni_env_tl.c`: LLVM ORC JIT's default
// platform support doesn't initialise TLS for objects added via
// `LLVMOrcLLJITAddObjectFile`. The host (sx-the-compiler) links this .c so the
// JIT's process-symbol generator resolves these functions via dlsym; AOT
// targets pick up the same .c as an auto-injected `#source` (see core.zig,
// gated on `Lowering.needs_trace_runtime`).
//
// Overflow policy (Zig-style): the newest frames survive — once the ring is
// full, the oldest frame is overwritten and `truncated` latches true, so the
// formatter can note "N frames omitted" at the top.

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define SX_TRACE_CAP 32

// Ring storage. `count` is the logical length (saturating at CAP); `head` is
// the index of the next write. When count == CAP the ring has wrapped and
// `frame_at(0)` is the oldest *surviving* frame (at `head`), not slot 0.
static _Thread_local uint64_t sx_trace_frames[SX_TRACE_CAP];
static _Thread_local uint32_t sx_trace_count; // surviving frame count, ≤ CAP
static _Thread_local uint32_t sx_trace_head;  // next write slot (mod CAP)
static _Thread_local uint32_t sx_trace_truncated_flag; // 0/1: did any frame get overwritten

void sx_trace_push(uint64_t frame) {
    sx_trace_frames[sx_trace_head] = frame;
    sx_trace_head = (sx_trace_head + 1u) % SX_TRACE_CAP;
    if (sx_trace_count < SX_TRACE_CAP) {
        sx_trace_count += 1u;
    } else {
        // Ring full: the write above overwrote the oldest frame.
        sx_trace_truncated_flag = 1u;
    }
}

void sx_trace_clear(void) {
    sx_trace_count = 0u;
    sx_trace_head = 0u;
    sx_trace_truncated_flag = 0u;
}

uint32_t sx_trace_len(void) {
    return sx_trace_count;
}

uint32_t sx_trace_truncated(void) {
    return sx_trace_truncated_flag;
}

// Frame `i` in oldest-to-newest order, 0-based over the surviving frames.
// Out-of-range returns 0 (a frame value of 0 is never a valid PC / packed id).
uint64_t sx_trace_frame_at(uint32_t i) {
    if (i >= sx_trace_count) return 0u;
    // When wrapped (count == CAP), the oldest surviving frame is at `head`;
    // otherwise frames start at slot 0.
    uint32_t base = (sx_trace_count == SX_TRACE_CAP) ? sx_trace_head : 0u;
    return sx_trace_frames[(base + i) % SX_TRACE_CAP];
}

// A compiled trace frame (ERR E3.0 slice 3a) is a pointer to an interned
// `Frame { string file; i32 line; i32 col; string func; }`, where an sx
// `string` is `{ const char* ptr; int64_t len; }`. This mirror MUST stay in
// lockstep with `getFrameStructType` in emit_llvm.zig and `Frame` in trace.sx.
typedef struct { const char *ptr; int64_t len; } SxStr;
typedef struct { SxStr file; int32_t line; int32_t col; SxStr func; SxStr line_text; } SxFrame;

// The failable-`main` entry-point reporter (ERR step E4.2). Called by the
// emitted main wrapper when an error reaches the function boundary: prints the
// unhandled-error header (with the tag name passed in — the compiler resolves
// it from the always-linked tag-name table) followed by the surviving trace
// frames, all to stderr. `name` is borrowed (a `string` slice, not NUL-
// terminated), so `name_len` bounds the print. The frame format mirrors
// trace.sx's `to_string` — `func at file:line:col`.
void sx_trace_report_unhandled(uint32_t tag, const char *name, size_t name_len) {
    (void)tag;
    dprintf(2, "error: unhandled error reached main: error.%.*s\n",
            (int)name_len, name ? name : "");
    uint32_t n = sx_trace_len();
    if (n == 0u) return;
    dprintf(2, "error return trace (most recent call last):\n");
    if (sx_trace_truncated() != 0u) {
        dprintf(2, "  ... older frames omitted (buffer full)\n");
    }
    for (uint32_t i = 0u; i < n; i++) {
        const SxFrame *f = (const SxFrame *)(uintptr_t)sx_trace_frame_at(i);
        dprintf(2, "  %.*s at %.*s:%d:%d\n",
                (int)f->func.len, f->func.ptr,
                (int)f->file.len, f->file.ptr,
                f->line, f->col);
        if (f->line_text.len > 0) {
            dprintf(2, "    %.*s\n", (int)f->line_text.len, f->line_text.ptr);
            dprintf(2, "    %*s^\n", f->col > 0 ? f->col - 1 : 0, "");
        }
    }
}
