// Compile-check root: forces semantic analysis of the path layer's public
// decls against a linux target on every host. `zig build test` builds it as an
// object (see build.zig); nothing links or runs it.

const imports = @import("imports.zig");

comptime {
    _ = &imports.sameFileIdentity;
    _ = &imports.canonicalizeEntryPath;
    _ = &imports.resolveImportPath;
    _ = &imports.processCwd;
    _ = &imports.selfExePath;
}
