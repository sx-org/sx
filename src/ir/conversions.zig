const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const lower = @import("lower.zig");
const lower_error = @import("lower/error.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const Lowering = lower.Lowering;

/// Coercion planning: classify HOW a value of one
/// type converts to another, before `Lowering` emits the IR for it. The
/// classifier is pure (reads the type table + protocol/impl registries); all
/// actual IR emission — `unbox_any`/`optional_wrap`/`int_to_float`/protocol
/// erasure/the `Into` call — stays in `Lowering`.
///
/// A `*Lowering` facade (like `CallResolver`/`GenericResolver`/
/// `ProtocolResolver`). Two entry points:
///   - `classify(src, dst)` — the built-in coercion ladder consumed by
///     `coerceToType` (the shared, recursive value-conversion path).
///   - `classifyXX(src, dst)` — the `xx`-operator head consumed by `lowerXX`
///     (Any unbox, no-op, protocol erasure, protocol→pointer, else the ladder
///     + the user-`Into` fallback).
pub const CoercionResolver = struct {
    l: *Lowering,

    /// The built-in coercion the `coerceToType` ladder will emit for `src → dst`.
    /// `.none` means no built-in applies; explicit conversion tries user `Into`.
    pub const CoercionPlan = enum {
        no_op,
        unbox_any, // any → concrete
        box_any, // concrete → any
        closure_to_fn_reject, // closure value → bare fn-ptr (diagnostic, returns operand)
        closure_signature_reject,
        function_signature_reject,
        unique_to_closure, // empty-env unique lambda → Closure ({fn, null})
        unique_to_closure_reject, // capturing unique lambda → Closure (diagnostic; the env has no home)
        lambda_ptr_to_closure, // *F, F a unique lambda → Closure borrowing the env the pointer names
        lambda_ptr_to_closure_reject, // *F → Closure of another signature (diagnostic)
        struct_elementwise, // anon struct → anon struct, same arity, element-wise
        optional_unwrap, // ?T → concrete (narrowing)
        optional_to_bool_reject, // ?T → bool (no presence-test coercion; diagnostic)
        void_to_optional, // void (null literal) → ?T
        optional_to_optional, // ?A → ?B (presence-preserving payload coercion)
        optional_wrap, // concrete → ?T
        borrow_protocol,
        erase_protocol, // concrete → protocol value
        member_to_open_set, // a member VALUE → its open set's inline slot
        int_to_float,
        float_to_int,
        int_to_enum, // int → payload-less enum (through the enum's backing type)
        enum_to_int, // payload-less enum → int (through the enum's backing type)
        integer_retype,
        error_to_int,
        ptr_to_void, // *T / [*]T → *void
        void_to_ptr,
        many_to_single,
        single_to_many,
        array_ptr_to_many_ptr,
        many_drop_terminator,
        objc_upcast,
        void_to_c_function,
        widen, // same kind, dst wider
        narrow, // same kind, dst narrower
        array_to_slice, // [N]T → []T (materialize backing storage + header)
        array_drop_terminator, // [N:X]T → [N]T (the N elements, terminator dropped)
        array_to_many_ptr, // [N:X]T → [*:X]T (the array's storage, as a pointer)
        slice_to_many_ptr, // [:X]T → [*:X]T (the fat pointer's data word)
        slice_len_convert, // @Slice(T,A) → @Slice(T,B) (rebuild the header on B's length word)
        many_to_slice_reject, // [*]T → []T (no length — needs ptr[0..len]; diagnostic)
        adds_terminator_reject, // an unterminated view → a terminated shape (diagnostic)
        error_set_retype, // error set → error set, tags legal in the destination
        failable_retype,
        none, // no built-in conversion

        /// A plan that REFUSES the conversion. The value does not reach the
        /// destination; the emitter reports the refusal and passes the operand
        /// through so lowering can continue.
        pub fn refuses(self: CoercionPlan) bool {
            return switch (self) {
                .closure_to_fn_reject,
                .closure_signature_reject,
                .function_signature_reject,
                .unique_to_closure_reject,
                .lambda_ptr_to_closure_reject,
                .optional_to_bool_reject,
                .many_to_slice_reject,
                .adds_terminator_reject,
                => true,
                else => false,
            };
        }

        pub fn implicitPointer(self: CoercionPlan) bool {
            return switch (self) {
                .ptr_to_void, .void_to_ptr, .many_to_single, .array_ptr_to_many_ptr, .many_drop_terminator, .objc_upcast => true,
                else => false,
            };
        }
    };

    /// The element a thin element pointer destination names.
    pub fn pointerDestElement(self: CoercionResolver, dst_ty: TypeId) ?TypeId {
        if (dst_ty.isBuiltin()) return null;
        const di = self.l.module.types.get(dst_ty);
        return if (di == .many_pointer) di.many_pointer.element else null;
    }

    /// The terminator a thin element pointer destination guarantees, or null
    /// for the unterminated `[*]T`.
    pub fn pointerDestSentinel(self: CoercionResolver, dst_ty: TypeId) ?i64 {
        if (dst_ty.isBuiltin()) return null;
        const di = self.l.module.types.get(dst_ty);
        return if (di == .many_pointer) di.many_pointer.sentinel else null;
    }

    /// The terminator `dst_ty` guarantees, over every shape that names one.
    pub fn destSentinel(self: CoercionResolver, dst_ty: TypeId) ?i64 {
        if (self.l.module.types.sliceInfoOf(dst_ty)) |s| return s.sentinel;
        if (!dst_ty.isBuiltin()) {
            const di = self.l.module.types.get(dst_ty);
            if (di == .array) return di.array.sentinel;
        }
        return self.pointerDestSentinel(dst_ty);
    }

    fn byteSized(elem: TypeId) bool {
        return elem == .u8 or elem == .i8;
    }

    /// Whether a terminated container of `src_elem` ending in `src_sentinel`
    /// satisfies the pointer `dst_ty` names. Dropping the guarantee (`[*]T`)
    /// is free; keeping it demands the same terminator.
    fn terminatorReaches(self: CoercionResolver, src_elem: TypeId, src_sentinel: ?i64, dst_ty: TypeId, dst_elem: TypeId) bool {
        const term = src_sentinel orelse return false;
        if (!self.l.module.types.sameType(src_elem, dst_elem) and !(byteSized(src_elem) and byteSized(dst_elem))) return false;
        const want = self.pointerDestSentinel(dst_ty) orelse return true;
        return want == term;
    }

    pub fn classify(self: CoercionResolver, src_ty: TypeId, dst_ty: TypeId) CoercionPlan {
        if (self.l.module.types.sameType(src_ty, dst_ty)) return .no_op;
        if (self.classifyPointer(src_ty, dst_ty)) |plan| return plan;
        if (!dst_ty.isBuiltin() and !src_ty.isBuiltin()) {
            const dst = self.l.module.types.get(dst_ty);
            const src = self.l.module.types.get(src_ty);
            if (dst == .pointer and self.l.getProtocolInfo(dst.pointer.pointee) != null and
                self.l.getProtocolInfo(src_ty) == null and
                self.l.resolveConcreteTypeName(if (src == .pointer) src.pointer.pointee else src_ty) != null and
                (src == .@"struct" or (src == .pointer and self.l.getProtocolInfo(src.pointer.pointee) == null))) return .borrow_protocol;
        }
        // A terminated value reaches a pointer that names the same terminator
        // or names none.
        if (self.pointerDestElement(dst_ty)) |dst_elem| {
            switch (self.l.module.types.get(src_ty)) {
                .array => |a| if (self.terminatorReaches(a.element, a.sentinel, dst_ty, dst_elem)) return .array_to_many_ptr,
                .slice => |sl| if (self.terminatorReaches(sl.element, sl.sentinel, dst_ty, dst_elem)) return .slice_to_many_ptr,
                else => {},
            }
        }
        // A member of an open set, where the set is expected: the value goes INTO
        // the slot — its tag in the tag word, its bytes in the payload. Classified
        // before the generic aggregate arms, since a set and its member are two
        // unrelated aggregates as far as those are concerned.
        if (!dst_ty.isBuiltin() and self.l.isOpenSet(dst_ty)) {
            if (self.l.openSetOf(dst_ty)) |set| {
                if (self.l.openSetDeclaresMembership(src_ty, set.decl)) return .member_to_open_set;
            }
        }
        if (src_ty == .any and dst_ty != .any) return .unbox_any;
        if (dst_ty == .any and src_ty != .any) return .box_any;

        if (!src_ty.isBuiltin() and !dst_ty.isBuiltin()) {
            if (self.l.module.types.get(src_ty) == .function and self.l.module.types.get(dst_ty) == .function)
                return .function_signature_reject;
            if (self.l.module.types.get(src_ty) == .closure and self.l.module.types.get(dst_ty) == .closure) {
                const have = self.l.module.types.get(src_ty).closure;
                const want = self.l.module.types.get(dst_ty).closure;
                if (!self.l.module.types.sameTypes(have.params, want.params) or
                    !self.l.module.types.sameType(have.ret, want.ret) or have.pack_start != want.pack_start)
                    return .closure_signature_reject;
            }
            if (self.l.module.types.get(src_ty) == .closure and self.l.module.types.get(dst_ty) == .function) {
                return .closure_to_fn_reject;
            }
            // A unique lambda erases only when its env is empty: the pair is
            // {fn, null} and nothing has to be stored anywhere.
            if (self.l.module.types.get(dst_ty) == .closure) {
                if (self.l.uniqueLambdaOf(src_ty)) |u| {
                    if (u.func == .formation) return .closure_signature_reject;
                    const env = self.l.module.types.get(src_ty).@"struct";
                    return if (env.fields.len == 0) .unique_to_closure else .unique_to_closure_reject;
                }
            }
            // A pointer to a unique lambda erases by borrowing: the pointer is
            // the env word, and the caller taking the address is what gives the
            // env a home. The signatures must agree.
            if (self.l.module.types.get(src_ty) == .pointer and self.l.module.types.get(dst_ty) == .closure) {
                if (self.l.uniqueLambdaOf(self.l.module.types.get(src_ty).pointer.pointee)) |u| {
                    const want = self.l.module.types.get(dst_ty).closure;
                    if (u.func == .lowered and self.l.module.types.sameType(u.ret, want.ret) and self.l.module.types.sameTypes(u.params, want.params)) return .lambda_ptr_to_closure;
                    return .lambda_ptr_to_closure_reject;
                }
            }
        }

        // Anonymous positional products of the same arity coerce element-wise
        // (`.{1, 1}` into a `(i32, i32)` multi-return success type).
        if (!src_ty.isBuiltin() and !dst_ty.isBuiltin()) {
            const si = self.l.module.types.get(src_ty);
            const di = self.l.module.types.get(dst_ty);
            if (si == .@"struct" and di == .@"struct" and si.@"struct".fields.len == di.@"struct".fields.len and
                self.l.module.types.isAnonStruct(src_ty) and self.l.module.types.isAnonStruct(dst_ty))
            {
                return .struct_elementwise;
            }
        }

        if (!src_ty.isBuiltin() and !dst_ty.isBuiltin()) {
            const si = self.l.module.types.get(src_ty);
            const di = self.l.module.types.get(dst_ty);
            if (si == .array and di == .array and si.array.sentinel != null and di.array.sentinel == null and
                self.l.module.types.sameType(si.array.element, di.array.element) and si.array.length == di.array.length) return .array_drop_terminator;
        }

        // Fixed array → slice of the same element: an aggregate array value
        // (e.g. a `.[...]` literal passed directly as a call arg) needs to be
        // materialized into addressable storage and wrapped in a {ptr,len}
        // header. Without this the array value is passed where a slice is
        // expected — the callee reads the header off the wrong bytes. The
        // local-bound path already does this conversion on its own.
        if (self.l.module.types.sliceInfoOf(dst_ty)) |ds| {
            if (!src_ty.isBuiltin()) {
                const si = self.l.module.types.get(src_ty);
                if (si == .array and self.l.module.types.sameType(si.array.element, ds.element) and
                    (ds.sentinel == null or ds.sentinel == si.array.sentinel)) return .array_to_slice;
                // `[*]T → []T`: a many-pointer carries NO length, so it cannot form a
                // `{ptr,len}` slice header implicitly. Silently passing the bare 8-byte
                // pointer where a 16-byte fat pointer is expected corrupts the callee's
                // view (garbage `.len`, mis-aligned reads) — at comptime it segfaults,
                // at runtime it fails LLVM verification. Reject loudly so
                // the user supplies the length via `ptr[0..len]`.
                if (si == .many_pointer) return .many_to_slice_reject;
            }
            // Two slices over the same element differing only in the width of
            // their length word: the fat pointer is rebuilt on the destination's
            // `Len`, the view unchanged. A destination naming a terminator takes
            // only a source that already carries it.
            if (self.l.module.types.sliceInfoOf(src_ty)) |ss| {
                if (self.l.module.types.sameType(ss.element, ds.element) and (ds.sentinel == null or ds.sentinel == ss.sentinel)) return .slice_len_convert;
            }
        }

        // Optional → Concrete unwrap (narrowing).
        if (!src_ty.isBuiltin()) {
            const src_info = self.l.module.types.get(src_ty);
            if (src_info == .optional) {
                const child_ty = src_info.optional.child;
                // `?T → bool` is NOT a presence test. The unwrap-then-narrow
                // ladder below would extract the payload and narrow it to `i1`,
                // which silently yields `false` for every optional.
                // There is no implicit optional→bool coercion in the language
                // (only `T → ?T` wrapping and flow-sensitive narrowing); a bool
                // position wants an explicit presence test. Reject loudly unless
                // the payload is itself a bool (`?bool → bool` is a genuine
                // unwrap of a bool payload, handled by the same arm below).
                if (dst_ty == .bool and child_ty != .bool) {
                    return .optional_to_bool_reject;
                }
                if (self.l.module.types.sameType(child_ty, dst_ty) or (dst_ty.isBuiltin() and child_ty.isBuiltin())) {
                    return .optional_unwrap;
                }
                // ?A → ?B: a presence-preserving payload coercion. Without a
                // dedicated arm this fell to `.optional_wrap` (dst is optional),
                // which unwrapped the SOURCE optional unconditionally and re-
                // wrapped it as always-present — turning a null `?i32` into a
                // present `?i64` carrying the zero payload (generic
                // `??` returning the wrong fallback). Only meaningful when the
                // children differ (same-type optionals are `.no_op` already).
                if (!dst_ty.isBuiltin() and self.l.module.types.get(dst_ty) == .optional) {
                    return .optional_to_optional;
                }
                // A proven-present optional uses its payload's implicit pointer conversion.
                if (self.classify(child_ty, dst_ty).implicitPointer()) return .optional_unwrap;
            }
        }

        // void (null literal) → Optional.
        if (src_ty == .void and !dst_ty.isBuiltin()) {
            if (self.l.module.types.get(dst_ty) == .optional) return .void_to_optional;
        }

        // Concrete → Optional wrap.
        if (!dst_ty.isBuiltin()) {
            if (self.l.module.types.get(dst_ty) == .optional) return .optional_wrap;
        }

        // Concrete → Protocol (auto type erasure) — only when the source has a
        // resolvable concrete type name; otherwise fall through to the numeric
        // ladder (matching `coerceToType`, which leaves the erase block).
        if (self.l.getProtocolInfo(dst_ty) != null) {
            if (self.l.resolveConcreteTypeName(src_ty) != null) return .erase_protocol;
        }

        // Numeric / pointer ladder.
        const src_float = Lowering.isFloat(src_ty);
        const dst_float = Lowering.isFloat(dst_ty);
        const src_int = self.l.isIntEx(src_ty);
        const dst_int = self.l.isIntEx(dst_ty);

        // Int ↔ payload-less enum. Such an enum IS an integer of its backing
        // type (§Enums), so the conversion is that integer conversion plus a
        // retype. Modeled rather than left to the same-shaped passthrough,
        // which keeps the SOURCE type and so answers `i64` for `n.(Zone)`
        // (issue 0396). No range check: like every other `xx`/`.(T)`
        // conversion this is well-defined, not value-preserving, and a flags
        // enum makes non-variant bit patterns legal by construction.
        if (src_int and self.l.enumBackingType(dst_ty) != null) return .int_to_enum;
        if (self.l.enumBackingType(src_ty) != null and dst_int) return .enum_to_int;

        if (!src_ty.isBuiltin() and self.l.module.types.get(src_ty) == .@"error" and dst_int) return .error_to_int;
        if (src_int and dst_float) return .int_to_float;
        if (src_float and dst_int) return .float_to_int;

        const src_bits = self.l.typeBitsEx(src_ty);
        const dst_bits = self.l.typeBitsEx(dst_ty);
        if (src_int and dst_int and src_bits == dst_bits) return .integer_retype;
        if (src_bits > 0 and dst_bits > 0) {
            if (dst_bits < src_bits) return .narrow;
            if (dst_bits > src_bits) return .widen;
        }
        // A legal error-set retype: the source tag word is the destination
        // channel's discriminant. Modeled because each channel is sized by its
        // own member payloads, so a `.none` weld is refused on width. A pair
        // the destination cannot name is `.none`: membership is the
        // implicit gate, and `unifyValueArmTypes` reads a modeled plan as a
        // safe join.
        if (lower_error.errorSetValueRetypeIsLegal(self.l, src_ty, dst_ty)) return .error_set_retype;
        if (!src_ty.isBuiltin() and !dst_ty.isBuiltin()) {
            const src = self.l.module.types.get(src_ty);
            const dst = self.l.module.types.get(dst_ty);
            if (src == .failable and dst == .failable and
                self.l.module.types.sameType(src.failable.value, dst.failable.value) and
                lower_error.errorSetValueRetypeIsLegal(self.l, src.failable.err, dst.failable.err)) return .failable_retype;
        }
        if (self.destSentinel(dst_ty) != null and
            src_ty != .void and src_ty != .noreturn and src_ty != .unresolved) return .adds_terminator_reject;
        return .none;
    }

    fn classifyPointer(self: CoercionResolver, src_ty: TypeId, dst_ty: TypeId) ?CoercionPlan {
        const tt = &self.l.module.types;
        const src = tt.get(src_ty);
        const dst = tt.get(dst_ty);
        if (self.isVoidPointer(dst_ty) and self.isTypedAddress(src_ty)) return .ptr_to_void;
        if (self.isVoidPointer(src_ty)) {
            if (dst == .pointer or (dst == .many_pointer and dst.many_pointer.sentinel == null)) return .void_to_ptr;
            if (dst == .function and dst.function.call_conv == .c) return .void_to_c_function;
        }
        if (src == .many_pointer) {
            if (dst == .pointer and tt.sameType(src.many_pointer.element, dst.pointer.pointee)) return .many_to_single;
            if (dst == .many_pointer and dst.many_pointer.sentinel == null and
                tt.sameType(src.many_pointer.element, dst.many_pointer.element)) return .many_drop_terminator;
        }
        if (src == .pointer) {
            if (dst == .many_pointer) {
                const pointee = tt.get(src.pointer.pointee);
                if (pointee == .array and tt.sameType(pointee.array.element, dst.many_pointer.element) and
                    (dst.many_pointer.sentinel == null or dst.many_pointer.sentinel == pointee.array.sentinel)) return .array_ptr_to_many_ptr;
                if (dst.many_pointer.sentinel == null and tt.sameType(src.pointer.pointee, dst.many_pointer.element)) return .single_to_many;
            }
            if (dst == .pointer and self.objcAncestor(src.pointer.pointee, dst.pointer.pointee)) return .objc_upcast;
        }
        return null;
    }

    fn objcAncestor(self: CoercionResolver, src_ty: TypeId, dst_ty: TypeId) bool {
        const tt = &self.l.module.types;
        const src = tt.get(src_ty);
        const dst = tt.get(dst_ty);
        if (src != .@"struct" or dst != .@"struct") return false;
        var current = self.l.program_index.lookup(.runtime_class, tt.getString(src.@"struct".name)) orelse return false;
        const target = self.l.program_index.lookup(.runtime_class, tt.getString(dst.@"struct".name)) orelse return false;
        if (current.runtime != .objc_class or target.runtime != .objc_class) return false;
        while (true) {
            const parent = for (current.members) |member| {
                if (member == .extends) break member.extends;
            } else return false;
            current = self.l.program_index.lookup(.runtime_class, parent) orelse return false;
            if (current == target) return true;
        }
    }

    /// The `xx`-operator head decision for `lowerXX`. `.coerce` defers to the
    /// built-in ladder (`coerceToType` / `classify`) + the user-`Into` fallback.
    /// Branch order mirrors `lowerXX` exactly.
    pub const XXPlan = enum {
        unbox_any, // src is Any → unbox (lowerXX adds the f32/f64 match dispatch)
        no_op,
        erase_protocol, // dst is a protocol → buildProtocolErasure
        erase_protocol_wrap, // dst is ?P (protocol child) → node-aware erase to P, then wrap
        reerase_protocol, // both are interfaces → one row of the target's conformance table
        reerase_protocol_wrap, // dst is ?Q, both interfaces → the same row, answered as an optional
        protocol_to_pointer, // src is a protocol, dst is a pointer → recover ctx
        protocol_to_raw, // src is a protocol, dst is @Protocol → build {ctx, typeId} field-wise
        protocol_to_any, // src is a protocol, dst is any → the {ctx, typeId} prefix view
        coerce, // built-in ladder + user `Into` fallback
    };

    /// Is `dst_ty` the `@Protocol` view — the declared contract struct
    /// with a pointer field "ctx" and a `Type` field
    /// "typeId"? Name AND shape gate the modeled protocol→raw conversion
    /// together, so an unrelated same-named user struct with a different
    /// shape can never hijack it (and an identical one converts soundly by
    /// construction).
    fn isProtocolViewDst(self: CoercionResolver, dst_ty: TypeId) bool {
        if (dst_ty.isBuiltin()) return false;
        const info = self.l.module.types.get(dst_ty);
        if (info != .@"struct") return false;
        const st = info.@"struct";
        if (!std.mem.eql(u8, self.l.module.types.getString(st.name), "@Protocol")) return false;
        if (st.fields.len != 2) return false;
        if (!std.mem.eql(u8, self.l.module.types.getString(st.fields[0].name), "ctx")) return false;
        const fty = st.fields[0].ty;
        if (fty.isBuiltin() or self.l.module.types.get(fty) != .pointer) return false;
        if (!std.mem.eql(u8, self.l.module.types.getString(st.fields[1].name), "typeId")) return false;
        return st.fields[1].ty == .type_value;
    }

    /// Is `dst_ty` the `@Any` view — the declared contract struct with
    /// a pointer field "data" and a `Type` field "typeId"? Same
    /// name-AND-shape gate as `isProtocolViewDst`. Consulted only by postfix
    /// `av.(@Any)` (the view's own pair); `@unbox` is the payload read.
    pub fn isAnyViewDst(self: CoercionResolver, dst_ty: TypeId) bool {
        if (dst_ty.isBuiltin()) return false;
        const info = self.l.module.types.get(dst_ty);
        if (info != .@"struct") return false;
        const st = info.@"struct";
        if (!std.mem.eql(u8, self.l.module.types.getString(st.name), "@Any")) return false;
        if (st.fields.len != 2) return false;
        if (!std.mem.eql(u8, self.l.module.types.getString(st.fields[0].name), "data")) return false;
        const fty = st.fields[0].ty;
        if (fty.isBuiltin() or self.l.module.types.get(fty) != .pointer) return false;
        if (!std.mem.eql(u8, self.l.module.types.getString(st.fields[1].name), "typeId")) return false;
        return st.fields[1].ty == .type_value;
    }

    pub fn classifyXX(self: CoercionResolver, src_ty: TypeId, dst_ty: TypeId) XXPlan {
        if (src_ty == .any) return .unbox_any;
        if (self.l.module.types.sameType(src_ty, dst_ty)) return .no_op;
        // Re-erasure precedes the ordinary erasure: the concrete type behind an
        // interface handle is not statically known, so the conversion is a
        // runtime table read rather than a coercion of the operand (§6.4).
        if (self.l.isErasedProtocolType(src_ty) and self.l.isErasedProtocolType(dst_ty) and src_ty != dst_ty)
            return .reerase_protocol;
        if (self.l.getProtocolInfo(dst_ty) != null) return .erase_protocol;
        // dst is `?P` with a protocol child: erase to the child with the
        // operand NODE in hand (borrow-mode for lvalue sources, exactly like
        // the plain `xx s : P` path), then wrap inline. Falling through to
        // `.coerce` would reach the node-less value-erasure arm, which
        // heap-boxes the receiver through context.allocator with no owner to
        // ever free it. Excluded sources take the ladder as
        // before: an optional (`?A → ?P` is presence-preserving), `void`
        // (the null literal), and a source already equal to the child
        // (plain wrap, no erasure needed).
        if (!dst_ty.isBuiltin() and self.l.module.types.get(dst_ty) == .optional) {
            const child = self.l.module.types.get(dst_ty).optional.child;
            const src_is_optional = !src_ty.isBuiltin() and self.l.module.types.get(src_ty) == .optional;
            if (self.l.isErasedProtocolType(src_ty) and self.l.isErasedProtocolType(child) and src_ty != child)
                return .reerase_protocol_wrap;
            if (self.l.getProtocolInfo(child) != null and src_ty != child and
                src_ty != .void and !src_is_optional) return .erase_protocol_wrap;
        }
        if (self.l.getProtocolInfo(src_ty) != null and !dst_ty.isBuiltin() and
            self.l.module.types.get(dst_ty) == .pointer) return .protocol_to_pointer;
        if (self.l.getProtocolInfo(src_ty) != null and self.isProtocolViewDst(dst_ty)) return .protocol_to_raw;
        // Protocol → any (explicit): the CONCRETE view — {data = ctx,
        // typeId} read straight off the value's prefix.
        // The IMPLICIT boxing of a protocol value (`av : any = s`) is
        // untouched: it still boxes the protocol value itself.
        if (self.l.getProtocolInfo(src_ty) != null and dst_ty == .any) return .protocol_to_any;
        return .coerce;
    }

    /// How two operand types meet for `== != < <= > >=`. Comparisons are
    /// not stores: the operands do not have to already be the comparison
    /// type, and the converted values are not written onward.
    pub const CompareMeet = union(enum) {
        /// Both sides convert to this type (identity when already equal).
        type: TypeId,
        /// Signed vs unsigned integers that do not widen into each other.
        signedness,
        incompatible,
        /// No comparison-specific meeting; the existing operand rules apply.
        none,
    };

    pub fn classifyCompare(self: CoercionResolver, lhs_ty: TypeId, rhs_ty: TypeId) CompareMeet {
        if (self.l.module.types.sameType(lhs_ty, rhs_ty)) return .{ .type = lhs_ty };
        if (lhs_ty == .unresolved or rhs_ty == .unresolved) return .none;
        if (lhs_ty == .void or rhs_ty == .void) return .none;

        const l_addr = self.isAddressType(lhs_ty);
        const r_addr = self.isAddressType(rhs_ty);
        if (l_addr and r_addr) {
            if (self.l.module.types.sameType(lhs_ty, rhs_ty)) return .{ .type = lhs_ty };
            return .{ .type = self.l.module.types.ptrTo(.void) };
        }
        if ((l_addr and self.l.isIntEx(rhs_ty)) or (r_addr and self.l.isIntEx(lhs_ty))) return .incompatible;

        if (!self.isNumericScalar(lhs_ty) or !self.isNumericScalar(rhs_ty)) return .none;
        return switch (self.numericMeet(lhs_ty, rhs_ty)) {
            .type => |ty| .{ .type = ty },
            .signedness => .signedness,
        };
    }

    pub fn isNumericScalar(self: CoercionResolver, ty: TypeId) bool {
        return self.l.isIntEx(ty) or Lowering.isFloat(ty);
    }

    /// The arithmetic common type of two numeric scalars.
    pub const NumericMeet = union(enum) {
        type: TypeId,
        /// Signed vs unsigned integers that do not widen into each other.
        signedness,
    };

    pub fn numericMeet(self: CoercionResolver, lhs_ty: TypeId, rhs_ty: TypeId) NumericMeet {
        const l_float = Lowering.isFloat(lhs_ty);
        const r_float = Lowering.isFloat(rhs_ty);
        if (l_float or r_float) {
            if (l_float and r_float) {
                const lb = self.l.typeBitsEx(lhs_ty);
                const rb = self.l.typeBitsEx(rhs_ty);
                return .{ .type = if (lb >= rb) lhs_ty else rhs_ty };
            }
            return .{ .type = if (l_float) lhs_ty else rhs_ty };
        }

        const l_u = self.l.module.types.isUnsignedInt(lhs_ty);
        const r_u = self.l.module.types.isUnsignedInt(rhs_ty);
        const lb = self.l.typeBitsEx(lhs_ty);
        const rb = self.l.typeBitsEx(rhs_ty);
        if (l_u == r_u) return .{ .type = if (lb >= rb) lhs_ty else rhs_ty };
        // Unsigned → strictly wider signed is the implicit numeric rule.
        if (l_u and !r_u and lb < rb) return .{ .type = rhs_ty };
        if (r_u and !l_u and rb < lb) return .{ .type = lhs_ty };
        return .signedness;
    }

    fn isVoidPointer(self: CoercionResolver, ty: TypeId) bool {
        if (ty.isBuiltin()) return false;
        const info = self.l.module.types.get(ty);
        return info == .pointer and info.pointer.pointee == .void;
    }

    fn isTypedAddress(self: CoercionResolver, ty: TypeId) bool {
        if (ty.isBuiltin()) return false;
        return switch (self.l.module.types.get(ty)) {
            .pointer, .many_pointer => true,
            else => false,
        };
    }

    fn isAddressType(self: CoercionResolver, ty: TypeId) bool {
        if (ty.isBuiltin()) return false;
        return switch (self.l.module.types.get(ty)) {
            .pointer, .many_pointer, .function => true,
            else => false,
        };
    }
};
