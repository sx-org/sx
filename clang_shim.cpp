#include "clang_shim.h"

// clang C++ API
#include <clang/AST/ASTConsumer.h>
#include <clang/AST/ASTContext.h>
#include <clang/AST/Decl.h>
#include <clang/Basic/DiagnosticOptions.h>
#include <clang/CodeGen/CodeGenAction.h>
#include <clang/Driver/Compilation.h>
#include <clang/Driver/Driver.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/CompilerInvocation.h>
#include <clang/Frontend/FrontendAction.h>

#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/LegacyPassManager.h>
#include <llvm/IR/Module.h>
#include <llvm/MC/TargetRegistry.h>
#include <llvm/Support/TargetSelect.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm/Target/TargetOptions.h>
#include <llvm/TargetParser/Host.h>

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

/* ------------------------------------------------------------------ */
/* Header parsing via clang C++ AST                                    */
/* ------------------------------------------------------------------ */

/// AST consumer that collects top-level function declarations.
class FunctionCollector : public clang::ASTConsumer {
public:
    std::vector<SxCFunctionInfo> &functions;
    clang::SourceManager *SM = nullptr;
    clang::FileID mainFileID;

    FunctionCollector(std::vector<SxCFunctionInfo> &funcs) : functions(funcs) {}

    void Initialize(clang::ASTContext &ctx) override {
        SM = &ctx.getSourceManager();
        mainFileID = SM->getMainFileID();
    }

    bool HandleTopLevelDecl(clang::DeclGroupRef DG) override {
        for (auto *D : DG) {
            auto *FD = llvm::dyn_cast<clang::FunctionDecl>(D);
            if (!FD) continue;

            // Only include functions from the main file
            clang::SourceLocation loc = FD->getLocation();
            if (!SM->isInFileID(SM->getExpansionLoc(loc), mainFileID))
                continue;

            // Skip anonymous/internal functions
            std::string name = FD->getNameAsString();
            if (name.empty() || name[0] == '_') continue;

            // Return type (canonical to resolve typedefs)
            std::string ret_type = FD->getReturnType().getCanonicalType().getAsString();

            // Parameters
            unsigned num_params = FD->getNumParams();
            auto *params = num_params > 0
                ? static_cast<SxCParamInfo *>(calloc(num_params, sizeof(SxCParamInfo)))
                : nullptr;

            for (unsigned i = 0; i < num_params; i++) {
                const clang::ParmVarDecl *P = FD->getParamDecl(i);
                std::string pname = P->getNameAsString();
                std::string ptype = P->getType().getCanonicalType().getAsString();
                params[i].name = strdup(pname.c_str());
                params[i].type_spelling = strdup(ptype.c_str());
            }

            // Source location
            clang::PresumedLoc PLoc = SM->getPresumedLoc(loc);

            SxCFunctionInfo fi;
            fi.name = strdup(name.c_str());
            fi.return_type = strdup(ret_type.c_str());
            fi.params = params;
            fi.num_params = static_cast<int>(num_params);
            fi.source_file = PLoc.isValid() ? strdup(PLoc.getFilename()) : nullptr;
            fi.source_line = PLoc.isValid() ? PLoc.getLine() : 0;
            functions.push_back(fi);
        }
        return true;
    }
};

/// Frontend action that creates a FunctionCollector consumer.
class CollectFunctionsAction : public clang::ASTFrontendAction {
public:
    std::vector<SxCFunctionInfo> &functions;

    CollectFunctionsAction(std::vector<SxCFunctionInfo> &funcs) : functions(funcs) {}

    std::unique_ptr<clang::ASTConsumer>
    CreateASTConsumer(clang::CompilerInstance &, llvm::StringRef) override {
        return std::make_unique<FunctionCollector>(functions);
    }
};

/// Helper: build a CompilerInstance from user args + filename using the Driver.
/// Returns nullptr on failure (sets out_error).
static std::unique_ptr<clang::CompilerInstance>
buildCompilerInstance(const char *filename,
                      const char **args, int num_args,
                      const llvm::SmallVectorImpl<const char *> &extra_flags,
                      char **out_error)
{
    // LLVM 21+: DiagnosticOptions is a plain value passed by reference (no
    // longer an IntrusiveRefCntPtr). It must outlive `diags` — both are locals
    // in this scope, declared opts-before-engine, so destruction order is safe.
    clang::DiagnosticOptions diagOpts;
    auto diagIDs = new clang::DiagnosticIDs();
    clang::DiagnosticsEngine diags(diagIDs, diagOpts,
                                    new clang::IgnoringDiagConsumer());

    clang::driver::Driver drv("clang",
                               llvm::sys::getDefaultTargetTriple(), diags);
    drv.setCheckInputsExist(false);

    llvm::SmallVector<const char *, 32> driver_args;
    driver_args.push_back("clang");
    driver_args.push_back("-c");
    driver_args.push_back("-w");

#ifdef SX_LLVM_PREFIX
    static std::string resource_dir = std::string(SX_LLVM_PREFIX) + "/lib/clang/22";
    driver_args.push_back("-resource-dir");
    driver_args.push_back(resource_dir.c_str());

    // On macOS, ensure system SDK headers are found
#ifdef __APPLE__
    driver_args.push_back("-isysroot");
    driver_args.push_back("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk");
#endif
#endif

    for (const auto *f : extra_flags)
        driver_args.push_back(f);
    for (int i = 0; i < num_args; i++)
        driver_args.push_back(args[i]);
    driver_args.push_back(filename);

    std::unique_ptr<clang::driver::Compilation> comp(
        drv.BuildCompilation(driver_args));
    if (!comp || comp->getJobs().empty()) {
        if (out_error) *out_error = strdup("failed to build compilation");
        return nullptr;
    }

    const auto &cmd = llvm::cast<clang::driver::Command>(
        *comp->getJobs().begin());
    const auto &cc1_args = cmd.getArguments();

    auto invocation = std::make_shared<clang::CompilerInvocation>();
    bool ok = clang::CompilerInvocation::CreateFromArgs(
        *invocation, cc1_args, diags);
    if (!ok) {
        if (out_error) *out_error = strdup("failed to create compiler invocation");
        return nullptr;
    }

    // LLVM 21+: setInvocation() was removed — the invocation is constructor-
    // injected instead. createDiagnostics(DiagnosticConsumer*) still exists as
    // the convenience overload (it builds a default VFS internally).
    auto CI = std::make_unique<clang::CompilerInstance>(std::move(invocation));
    CI->createDiagnostics(new clang::IgnoringDiagConsumer());
    return CI;
}

extern "C" SxCHeaderInfo *sx_clang_parse_header(
    const char *filename,
    const char **args, int num_args,
    char **out_error)
{
    // Parse with -fsyntax-only (no codegen needed)
    llvm::SmallVector<const char *, 4> extra;
    extra.push_back("-fsyntax-only");

    auto CI = buildCompilerInstance(filename, args, num_args, extra, out_error);
    if (!CI) return nullptr;

    std::vector<SxCFunctionInfo> functions;
    CollectFunctionsAction action(functions);
    if (!CI->ExecuteAction(action)) {
        if (out_error) *out_error = strdup("failed to parse header");
        return nullptr;
    }

    // Convert to C struct
    auto *info = static_cast<SxCHeaderInfo *>(malloc(sizeof(SxCHeaderInfo)));
    info->num_functions = static_cast<int>(functions.size());
    info->functions = static_cast<SxCFunctionInfo *>(
        calloc(info->num_functions, sizeof(SxCFunctionInfo)));
    for (int i = 0; i < info->num_functions; i++) {
        info->functions[i] = functions[i];
    }
    return info;
}

extern "C" void sx_clang_free_header_info(SxCHeaderInfo *info) {
    if (!info) return;
    for (int i = 0; i < info->num_functions; i++) {
        auto &f = info->functions[i];
        free(const_cast<char *>(f.name));
        free(const_cast<char *>(f.return_type));
        if (f.source_file) free(const_cast<char *>(f.source_file));
        for (int j = 0; j < f.num_params; j++) {
            free(const_cast<char *>(f.params[j].name));
            free(const_cast<char *>(f.params[j].type_spelling));
        }
        free(f.params);
    }
    free(info->functions);
    free(info);
}

/* ------------------------------------------------------------------ */
/* C source compilation to LLVM module                                 */
/* ------------------------------------------------------------------ */

extern "C" LLVMModuleRef sx_clang_compile_to_module(
    LLVMContextRef ctx_ref,
    const char *filename,
    const char **args, int num_args,
    char **out_error)
{
    llvm::LLVMContext &ctx = *llvm::unwrap(ctx_ref);

    llvm::SmallVector<const char *, 4> extra;
    auto CI = buildCompilerInstance(filename, args, num_args, extra, out_error);
    if (!CI) return nullptr;

    clang::EmitLLVMOnlyAction action(&ctx);
    if (!CI->ExecuteAction(action)) {
        if (out_error) *out_error = strdup("clang compilation failed");
        return nullptr;
    }

    std::unique_ptr<llvm::Module> mod = action.takeModule();
    if (!mod) {
        if (out_error) *out_error = strdup("no module produced");
        return nullptr;
    }

    return llvm::wrap(mod.release());
}

/* ------------------------------------------------------------------ */
/* C source compilation to native object code                          */
/* ------------------------------------------------------------------ */

extern "C" LLVMMemoryBufferRef sx_clang_compile_to_object(
    const char *filename,
    const char **args, int num_args,
    char **out_error)
{
    // Initialize LLVM targets (idempotent)
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmPrinters();
    llvm::InitializeAllAsmParsers();

    // Use a local context — the module is temporary, only .o bytes are kept
    llvm::LLVMContext ctx;

    llvm::SmallVector<const char *, 4> extra;
    extra.push_back("-fPIC");
    auto CI = buildCompilerInstance(filename, args, num_args, extra, out_error);
    if (!CI) return nullptr;

    clang::EmitLLVMOnlyAction action(&ctx);
    if (!CI->ExecuteAction(action)) {
        if (out_error) *out_error = strdup("clang compilation failed");
        return nullptr;
    }

    std::unique_ptr<llvm::Module> mod = action.takeModule();
    if (!mod) {
        if (out_error) *out_error = strdup("no module produced");
        return nullptr;
    }

    // Compile LLVM module to native object code.
    // LLVM 21+: getTargetTriple() returns a const Triple& (was std::string).
    const llvm::Triple &triple = mod->getTargetTriple();
    std::string err_str;
    const llvm::Target *target = llvm::TargetRegistry::lookupTarget(triple, err_str);
    if (!target) {
        if (out_error) *out_error = strdup(("target lookup failed: " + err_str).c_str());
        return nullptr;
    }

    llvm::TargetOptions opts;
    auto TM = std::unique_ptr<llvm::TargetMachine>(
        target->createTargetMachine(triple, "generic", "", opts,
                                     llvm::Reloc::PIC_));
    if (!TM) {
        if (out_error) *out_error = strdup("failed to create target machine");
        return nullptr;
    }

    mod->setDataLayout(TM->createDataLayout());

    llvm::SmallVector<char, 0> obj_buf;
    llvm::raw_svector_ostream OS(obj_buf);

    llvm::legacy::PassManager PM;
    if (TM->addPassesToEmitFile(PM, OS, nullptr,
                                 llvm::CodeGenFileType::ObjectFile)) {
        if (out_error) *out_error = strdup("target cannot emit object file");
        return nullptr;
    }
    PM.run(*mod);

    // Return as LLVMMemoryBufferRef
    auto buf = llvm::MemoryBuffer::getMemBufferCopy(
        llvm::StringRef(obj_buf.data(), obj_buf.size()), "c_import.o");
    return llvm::wrap(buf.release());
}

/* ------------------------------------------------------------------ */
/* Exported-symbol scan over a compiled object buffer                  */
/* ------------------------------------------------------------------ */

#include <llvm/Object/ObjectFile.h>

extern "C" SxCSymbolList *sx_clang_object_exported_symbols(
    LLVMMemoryBufferRef obj,
    char **out_error)
{
    using namespace llvm;
    MemoryBufferRef ref(
        StringRef(LLVMGetBufferStart(obj), LLVMGetBufferSize(obj)),
        "sx-c-import-object");
    auto objOrErr = object::ObjectFile::createObjectFile(ref);
    if (!objOrErr) {
        if (out_error)
            *out_error = strdup(toString(objOrErr.takeError()).c_str());
        return nullptr;
    }

    std::vector<std::string> names;
    for (const object::SymbolRef &sym : (*objOrErr)->symbols()) {
        auto flagsOrErr = sym.getFlags();
        if (!flagsOrErr) { consumeError(flagsOrErr.takeError()); continue; }
        uint32_t flags = *flagsOrErr;
        if (flags & object::SymbolRef::SF_Undefined) continue;
        if (!(flags & object::SymbolRef::SF_Global)) continue;
        if (flags & object::SymbolRef::SF_FormatSpecific) continue;
        auto nameOrErr = sym.getName();
        if (!nameOrErr) { consumeError(nameOrErr.takeError()); continue; }
        names.push_back(nameOrErr->str());
    }

    SxCSymbolList *list = (SxCSymbolList *)malloc(sizeof(SxCSymbolList));
    list->num_names = (int)names.size();
    list->names = (const char **)malloc(sizeof(char *) * (names.empty() ? 1 : names.size()));
    for (size_t i = 0; i < names.size(); i++)
        list->names[i] = strdup(names[i].c_str());
    return list;
}

extern "C" void sx_clang_free_symbol_list(SxCSymbolList *list)
{
    if (!list) return;
    for (int i = 0; i < list->num_names; i++)
        free((void *)list->names[i]);
    free(list->names);
    free(list);
}
