# 0347 — `#objc_class` method with a struct-byval argument aborts the LLVM verifier

Status: OPEN (found during the G6 metal.sx DSL-port assessment, 2026-07-22)

## Symptom

Declaring an `#objc_class` method whose parameter is a struct passed
by value and dispatching it produces an LLVM verifier abort instead of
a working call (or a diagnostic):

    LLVM verification failed: Call parameter type does not match function signature!
      %objc.msg = call i64 @objc_msgSend(ptr %recv, ptr %sel, { i64, i64, i64, i64, i64, i64 } %load)

Scalar and pointer arguments dispatch fine (examples ffi-objc/1345–1349
pin those shapes). The manual idiom works because the `abi(.c)`
fn-pointer cast applies the C-ABI coercion (`ptr byval(<T>)` for large
aggregates, register-class assignment for HFAs):

    msg : (*void, *void, MTLScissorRect) -> void abi(.c) = xx objc_msgSend;

`lowerObjcMethodCall` / `lowerObjcStaticCall` pass the raw aggregate to
`objc_msgSend`'s declared signature with no coercion.

## Repro

    #import "modules/std.sx";
    #import "modules/ffi/objc.sx";

    ProbeRegion :: struct { a: u64; b: u64; c: u64; d: u64; e: u64; f: u64; }

    SxStructProbe :: #objc_class("SxStructProbe") extern {
        take_region :: (self: *Self, r: ProbeRegion) -> u64 #selector("takeRegion:");
    }

    region_imp :: (self: *void, _cmd: *void, r: ProbeRegion) -> u64 abi(.c) {
        r.a + r.b + r.c + r.d + r.e + r.f
    }

    main :: () -> i32 {
        ns_object := objc_getClass("NSObject".ptr);
        cls := objc_allocateClassPair(ns_object, "SxStructProbe".ptr, 0);
        class_addMethod(cls, sel_registerName("takeRegion:".ptr), xx region_imp,
            "Q@:{ProbeRegion=QQQQQQ}".ptr);
        objc_registerClassPair(cls);
        inst : *SxStructProbe = xx class_createInstance(cls, 0);
        r := ProbeRegion.{ a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 };
        print("sum: {}\n", inst.take_region(r));   // expect 21
        0
    }

Same class of failure for the 2×f64 HFA shape (CGSize-like).

## Expected

The DSL call applies the same C-ABI argument coercion the `abi(.c)`
fn-pointer cast path applies, so struct-taking selectors
(`setClearColor:`, `setDrawableSize:`, `setScissorRect:`,
`replaceRegion:mipmapLevel:withBytes:bytesPerRow:`,
`getBytes:bytesPerRow:fromRegion:mipmapLevel:`) are declarable.

## Actual

Verifier abort at compile time (exit 1).

## Suspected area

`lowerObjcMethodCall` / `lowerObjcStaticCall` argument marshaling
(src/ir/lower/objc_class.zig) — build the dispatch through the same
coerced fn-type machinery the typed-fn-pointer cast uses instead of the
raw `objc_msgSend` declaration.

## Impact / follow-up

Blocks porting gpu/metal.sx (and platform/uikit.sx) off the manual
msgSend-cast idiom — Metal's hottest selectors take MTLRegion /
MTLScissorRect / MTLClearColor / CGSize by value (Agra-decided
2026-07-22: keep metal.sx uniform on the manual idiom until this is
fixed, then port the platform layer wholesale). Fix ships with a
regression example covering the byval + HFA shapes.
