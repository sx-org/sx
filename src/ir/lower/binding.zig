const std = @import("std");
const imports = @import("../../imports.zig");
const contracts = @import("../../contracts.zig");
const runtime_bindings = @import("../runtime_bindings.zig");
const inst_mod = @import("../inst.zig");
const types = @import("../types.zig");
const lower = @import("../lower.zig");
const lower_decl = @import("decl.zig");
const Lowering = lower.Lowering;
const FuncId = inst_mod.FuncId;
const TypeId = types.TypeId;

/// The function a runtime binding calls: `name`'s declaration in its owner
/// module, lowered and resolved to its id. Null when the owner module is not
/// in the program.
pub fn runtimeBinding(self: *Lowering, name: []const u8) ?FuncId {
    if (self.runtime_binding_fids.get(name)) |fid| return fid;
    const b = runtime_bindings.find(name) orelse return null;
    const fid = resolveBinding(self, b) orelse return null;
    self.runtime_binding_fids.put(name, fid) catch {};
    return fid;
}

fn resolveBinding(self: *Lowering, b: runtime_bindings.Binding) ?FuncId {
    if (self.program_index.lookup(.function, b.name)) |fd| {
        if (ownerAuthored(self, b.module, fd.body.source_file orelse self.main_file)) {
            self.lazyLowerFunction(b.name);
            return self.resolveFuncByName(b.name);
        }
    }
    // The bare name is another module's; the owner's declaration gets its own slot.
    const module_decls = self.program_index.decl_table orelse return null;
    for (module_decls.environments.items) |env| {
        const path = env.source;
        if (!ownerAuthored(self, b.module, path)) continue;
        const id = env.names.get(b.name) orelse return null;
        const raw = module_decls.get(id).ref orelse return null;
        const fd = lower_decl.fnDeclOfRaw(raw) orelse return null;
        return self.bareAuthorFuncId(fd, b.name, path);
    }
    return null;
}

/// The `Frame` declared in trace.sx's `trace` scope, the type
/// `__trace_resolve_frame` yields. Null when trace.sx is not in the program.
pub fn traceFrameType(self: *Lowering) ?TypeId {
    const module_decls = self.program_index.decl_table orelse return null;
    for (module_decls.environments.items) |env| {
        if (env.scope_path.len != 1 or !std.mem.eql(u8, env.scope_path[0], "trace")) continue;
        if (!ownerAuthored(self, "modules/std/trace.sx", env.source)) continue;
        const raw = module_decls.get(env.names.get("Frame") orelse return null).ref orelse return null;
        const ref = imports.innerDeclRef(raw) orelse raw;
        if (ref != .struct_decl) return null;
        return self.module.types.type_decl_tids.get(@ptrCast(ref.struct_decl));
    }
    return null;
}

/// Whether `file` IS the owner module, resolved from a library root and
/// compared by identity on disk.
fn ownerAuthored(self: *Lowering, module: []const u8, file: ?[]const u8) bool {
    const f = file orelse return false;
    for (self.stdlib_paths) |root| {
        const candidate = contracts.candidatePath(self.alloc, root, module) catch continue;
        if (imports.sameFileIdentity(self.alloc, f, candidate)) return true;
    }
    return false;
}
