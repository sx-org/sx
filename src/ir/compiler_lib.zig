//! The comptime `compiler` library's name registry — the curated set of the
//! compiler's own functions reachable from comptime sx via
//! `abi(.zig) extern compiler`.
//!
//! **This registry IS the safety boundary.** Only the names registered here are
//! bindable from user comptime code; a name not on the export list is rejected
//! at declaration (`weldedCompilerFn`). The comptime VM
//! (`comptime_vm.callCompilerFn`) services every welded call by name — this file
//! only carries the list of recognized names.
//!
//! Comptime values are native bytes in the VM, so the compiler API welds no
//! TYPES: no parallel layout regime, no layout validation, no hand-marshaling.
//! Only names cross the boundary.

const std = @import("std");

/// The name of the only compiler library. A `fn abi(.zig) extern <lib>` with a
/// different `<lib>` is rejected — `compiler` is the sole comptime bind source.
pub const lib_name = "compiler";

// `ir/intrinsics.zig` is the allow-list for compiler-lib exports; it binds by
// (module, name).
