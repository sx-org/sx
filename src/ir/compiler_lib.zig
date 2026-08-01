//! The comptime `compiler` library's name registry — the curated set of the
//! compiler's own functions reachable from comptime sx via
//! `abi(.zig) extern compiler`. See `current/PLAN-COMPILER-VM.md`.
//!
//! **This registry IS the safety boundary.** Only the names registered here are
//! bindable from user comptime code; a name not on the export list is rejected
//! at declaration (`weldedCompilerFn`). The comptime VM
//! (`comptime_vm.callCompilerFn`) services every welded call by name — this file
//! only carries the list of recognized names.
//!
//! **Direction note (2026-06-17 pivot).** The byte-weld of TYPES (sx structs whose
//! layout was validated to mirror the compiler's Zig records) was stripped — it
//! bolted a parallel layout regime + hand-marshaling onto a comptime value model
//! that isn't bytes. The replacement is a comptime VM where values are
//! native bytes, so the compiler-API needs no weld/validation/marshaling.

const std = @import("std");

/// The name of the only compiler library. A `fn abi(.zig) extern <lib>` with a
/// different `<lib>` is rejected — `compiler` is the sole comptime bind source.
pub const lib_name = "compiler";

// `ir/intrinsics.zig` is the allow-list for compiler-lib exports; it binds by
// (module, name).
