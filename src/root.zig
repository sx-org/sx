pub const llvm_api = @import("llvm_api.zig");
pub const token = @import("token.zig");
pub const lexer = @import("lexer.zig");
pub const lexer_tests = @import("lexer.test.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const parser_tests = @import("parser.test.zig");
pub const print = @import("print.zig");
pub const types = @import("types.zig");
pub const target = @import("target.zig");
pub const target_tests = @import("target.test.zig");
pub const builtins = @import("builtins.zig");
pub const errors = @import("errors.zig");
pub const errors_tests = @import("errors.test.zig");
pub const trace_runtime_tests = @import("runtime_trace.test.zig");
pub const sema = @import("sema.zig");
pub const sema_tests = @import("sema.test.zig");
pub const imports = @import("imports.zig");
pub const imports_tests = @import("imports.test.zig");
pub const core = @import("core.zig");
pub const c_import = @import("c_import.zig");
pub const c_import_tests = @import("c_import.test.zig");
pub const corpus_run_tests = @import("corpus_run.test.zig");
pub const ir = @import("ir/ir.zig");

pub const lsp = struct {
    pub const server = @import("lsp/server.zig");
    pub const transport = @import("lsp/transport.zig");
    pub const types = @import("lsp/types.zig");
    pub const document = @import("lsp/document.zig");
    pub const document_tests = @import("lsp/document.test.zig");
    pub const corpus_sweep_tests = @import("lsp/corpus_sweep.test.zig");
};

test {
    // Discover every test in the module graph so `zig build test` actually
    // runs them. Without this, the test binary finds no `test` blocks at the
    // root and trivially "passes" while exercising nothing. Nested barrels
    // (e.g. ir/ir.zig) carry their own `test { refAllDecls }`, so this chains
    // into them.
    @import("std").testing.refAllDecls(@This());
    // refAllDecls only reaches the top-level decls; the `lsp` files live one
    // struct deeper, so reference them directly to pull in their tests.
    _ = lsp.server;
    _ = lsp.document;
    _ = lsp.document_tests;
    _ = lsp.corpus_sweep_tests;
    _ = lsp.types;
    _ = lsp.transport;
}
