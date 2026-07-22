# 0346 — `impl` for a protocol name not in the module's scope is silently dropped

Status: RESOLVED 2026-07-22

## Resolution

`ProtocolResolver.diagnoseUnregisteredImpls` (src/ir/protocols.zig),
called as the last pass of `lowerRoot`: any impl block still absent
from `registered_protocol_impls` after every registration opportunity
(scan, order retry, body lowering) is an error, with the failing part
named — unknown protocol head, unresolvable type argument/source, or
unresolvable target type. Walks exactly where registration walked
(top-level decls; namespace decls in full-program hosts).

Pins: examples/diagnostics/1278 (both impl-head shapes reject),
examples/modules/1621 (the cross-module production shape rejects at
the declaring module). The fix also EXPOSED a second production
instance: examples/modules/0709's common.sx (the issue-0056 diamond
pin) had no std import — its Into impl was dead the whole time and the
example passed only because the bit-identity convert matched the
reinterpret spill byte-for-byte. Repaired (std imported, convert made
non-identity: 7 + 35 = 42) so the pin now proves the impl RUNS exactly
once.

## Symptom

An `impl Into(T) for S` block declared in a module that has no import
making `Into` nameable (e.g. a file with zero `#import` lines) is
accepted without any diagnostic — and never registers in the
param-impl map. Every `xx` site that should route through the impl
falls through the builtin ladder to the aggregate↔scalar reinterpret
spill and silently produces garbage.

Production instance: `modules/ffi/objc.sx` declares
`impl Into(*NSString) for string` (the documented literal→NSString
bridge) but imports nothing, so the bridge is DEAD from every importer:
`NSLog(xx "...")` / `newLibraryWithSource: xx src` receive the string's
data pointer reinterpreted as an object and segfault inside libobjc
(fault address = isa-masked ASCII of the literal). The Metal MSL
create_shader path crashes exactly this way on macOS. objc_block.sx
declares its Into impls AFTER `#import "modules/std.sx"` — those work,
which is why the class of bug went unnoticed.

## Repro

lib3.sx (no imports):

    Box3 :: struct { v: i64; }
    g_box3 : Box3 = .{ v = 99 };
    impl Into(*Box3) for string {
        convert :: (self: string) -> *Box3 { return @g_box3; }
    }

main3.sx:

    #import "modules/std.sx";
    #import "lib3.sx";
    main :: () {
        b : *Box3 = xx "abc";
        print("b.v = {}\n", b.v);
    }

## Expected

Either (a) the impl registers (protocol heads resolve program-wide the
way `tryUserConversion`'s name-keyed lookup already assumes), or (b) a
diagnostic at the impl head: `Into` is not a nameable identifier in
this module. Silence is the bug; with the impl dead, `xx` degrades to
the reinterpret spill and b.v reads the string bytes.

## Actual

Compiles clean; prints garbage (string-header bytes as i64). With
pointer targets the garbage is then dereferenced (the objc.sx segfault).

## Suspected area

Impl registration into `param_impl_map` (program-index side): the impl
head's protocol name resolution against the declaring module's scope —
a resolution failure is swallowed instead of diagnosed. Note
`tryUserConversion` (src/ir/lower/coerce.zig) already looks protocols
up by bare name in `protocol_ast_map`; the visibility filter is on the
CONSUMER's imports, so registration is where the drop must happen.

## Disposition

The blocking production instance was fixed library-side first (objc.sx
imports modules/std.sx, activating the bridge — G6 Option B commit
`fcdc6468`); the compiler-side diagnostic landed after G6 (see
Resolution).
