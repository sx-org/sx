pub const types = @import("types.zig");
pub const inst = @import("inst.zig");
pub const module = @import("module.zig");
pub const print = @import("print.zig");
pub const comptime_value = @import("comptime_value.zig");
pub const lower = @import("lower.zig");
pub const program_index = @import("program_index.zig");
pub const resolver = @import("resolver.zig");
pub const type_resolver = @import("type_resolver.zig");
pub const packs = @import("packs.zig");
pub const expr_typer = @import("expr_typer.zig");
pub const calls = @import("calls.zig");
pub const generics = @import("generics.zig");
pub const protocols = @import("protocols.zig");
pub const conversions = @import("conversions.zig");
pub const error_analysis = @import("error_analysis.zig");
pub const error_flow = @import("error_flow.zig");
pub const ffi_objc = @import("ffi_objc.zig");
pub const semantic_diagnostics = @import("semantic_diagnostics.zig");

pub const TypeId = types.TypeId;
pub const TypeInfo = types.TypeInfo;
pub const TypeTable = types.TypeTable;
pub const StringId = types.StringId;
pub const StringPool = types.StringPool;

pub const Ref = inst.Ref;
pub const BlockId = inst.BlockId;
pub const FuncId = inst.FuncId;
pub const GlobalId = inst.GlobalId;
pub const Inst = inst.Inst;
pub const Op = inst.Op;
pub const Block = inst.Block;
pub const Function = inst.Function;
pub const Global = inst.Global;
pub const ConstantValue = inst.ConstantValue;

pub const Module = module.Module;
pub const Builder = module.Builder;
pub const ImplTable = module.ImplTable;

pub const printModule = print.printModule;
pub const Value = comptime_value.Value;
pub const Lowering = lower.Lowering;
pub const ProgramIndex = program_index.ProgramIndex;
pub const TypeResolver = type_resolver.TypeResolver;
pub const ResolveEnv = type_resolver.ResolveEnv;
pub const PackResolver = packs.PackResolver;
pub const ExprTyper = expr_typer.ExprTyper;
pub const CallResolver = calls.CallResolver;
pub const CallPlan = calls.CallPlan;
pub const GenericResolver = generics.GenericResolver;
pub const ProtocolResolver = protocols.ProtocolResolver;
pub const CoercionResolver = conversions.CoercionResolver;
pub const CoercionPlan = conversions.CoercionResolver.CoercionPlan;
pub const ErrorAnalysis = error_analysis.ErrorAnalysis;
pub const ErrorFlow = error_flow.ErrorFlow;
pub const ObjcLowering = ffi_objc.ObjcLowering;
pub const ErrorFacts = error_analysis.ErrorFacts;

pub const compiler_hooks = @import("compiler_hooks.zig");
pub const compiler_lib = @import("compiler_lib.zig");
pub const reachability = @import("reachability.zig");
pub const comptime_vm = @import("comptime_vm.zig");
pub const emit_llvm = @import("emit_llvm.zig");
pub const LLVMEmitter = emit_llvm.LLVMEmitter;

pub const type_bridge = @import("type_bridge.zig");
pub const resolveAstType = type_bridge.resolveAstType;

pub const jni_descriptor = @import("jni_descriptor.zig");
pub const jni_java_emit = @import("jni_java_emit.zig");

pub const types_tests = @import("types.test.zig");
pub const inst_tests = @import("inst.test.zig");
pub const module_tests = @import("module.test.zig");
pub const print_tests = @import("print.test.zig");
pub const lower_tests = @import("lower.test.zig");
pub const lower_nominal_tests = @import("lower/nominal.test.zig");
pub const program_index_tests = @import("program_index.test.zig");
pub const resolver_tests = @import("resolver.test.zig");
pub const type_resolver_tests = @import("type_resolver.test.zig");
pub const packs_tests = @import("packs.test.zig");
pub const expr_typer_tests = @import("expr_typer.test.zig");
pub const calls_tests = @import("calls.test.zig");
pub const generics_tests = @import("generics.test.zig");
pub const protocols_tests = @import("protocols.test.zig");
pub const conversions_tests = @import("conversions.test.zig");
pub const error_analysis_tests = @import("error_analysis.test.zig");
pub const type_bridge_tests = @import("type_bridge.test.zig");
pub const emit_llvm_tests = @import("emit_llvm.test.zig");
pub const jni_descriptor_tests = @import("jni_descriptor.test.zig");
pub const jni_java_emit_tests = @import("jni_java_emit.test.zig");
pub const comptime_vm_tests = @import("comptime_vm.test.zig");
pub const intrinsics_tests = @import("intrinsics.test.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
