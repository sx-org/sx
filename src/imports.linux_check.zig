const imports = @import("imports.zig");

// Taking these addresses forces semantic analysis of the target-specific path declarations.
comptime {
    _ = &imports.sameFileIdentity;
    _ = &imports.canonicalizeEntryPath;
    _ = &imports.resolveImportPath;
    _ = &imports.processCwd;
    _ = &imports.selfExePath;
}
