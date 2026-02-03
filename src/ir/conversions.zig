const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const lower = @import("lower.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const Lowering = lower.Lowering;

/// Coercion planning (architecture phase A4.3): classify HOW a value of one
/// type converts to another, before `Lowering` emits the IR for it. The
/// classifier is pure (reads the type table + protocol/impl registries); all
/// actual IR emission — `unbox_any`/`optional_wrap`/`int_to_float`/protocol
/// erasure/the `Into` call — stays in `Lowering`.
///
/// A `*Lowering` facade (Principle 5, like `CallResolver`/`GenericResolver`/
/// `ProtocolResolver`). Two entry points:
///   - `classify(src, dst)` — the built-in coercion ladder consumed by
///     `coerceToType` (the shared, recursive value-conversion path).
///   - `classifyXX(src, dst)` — the `xx`-operator head consumed by `lowerXX`
///     (Any unbox, no-op, protocol erasure, protocol→pointer, else the ladder
///     + the user-`Into` fallback).
pub const CoercionResolver = struct {
    l: *Lowering,

    /// The built-in coercion the `coerceToType` ladder will emit for `src → dst`.
    /// `.none` means no built-in applies (the value passes through unchanged;
    /// `lowerXX` then tries a user `Into`). Branch order mirrors `coerceToType`
    /// exactly — the emitter switches on this and reproduces each arm.
    pub const CoercionPlan = enum {
        no_op, // src == dst
        unbox_any, // any → concrete
        box_any, // concrete → any
        closure_to_fn_reject, // closure value → bare fn-ptr (diagnostic, returns operand)
        tuple_elementwise, // (A,B) → (C,D), same arity
        struct_to_tuple, // anon/positional struct → tuple, same arity, element-wise
        optional_unwrap, // ?T → concrete (narrowing)
        optional_to_bool_reject, // ?T → bool (no presence-test coercion; diagnostic)
        void_to_optional, // void (null literal) → ?T
        optional_to_optional, // ?A → ?B (presence-preserving payload coercion)
        optional_wrap, // concrete → ?T
        erase_protocol, // concrete → protocol value
        int_to_float,
        float_to_int,
        ptr_int_bitcast, // ptr ↔ int
        widen, // same kind, dst wider
        narrow, // same kind, dst narrower
        array_to_slice, // [N]T → []T (materialize backing storage + header)
        many_to_slice_reject, // [*]T → []T (no length — needs ptr[0..len]; diagnostic)
        string_to_cstring, // literal-only implicit; other strings need to_cstring
        cstring_to_string_reject, // explicit from_cstring required (diagnostic)
        none, // nothing applies — pass the value through
    };

    pub fn classify(self: CoercionResolver, src_ty: TypeId, dst_ty: TypeId) CoercionPlan {
        if (src_ty == dst_ty) return .no_op;
        if (src_ty == .string and dst_ty == .cstring) return .string_to_cstring;
        // string → `[*]u8`/`[*]i8`: the C-import synthesizes `char const *`
        // params as byte many-pointers, so a string LITERAL argument gets the
        // same literal-only blessing as `cstring` (its bytes are a terminated
        // constant; the emitted value is the DATA POINTER). A non-literal
        // string may be an unterminated view — same rejection as cstring.
        // Previously this pair fell to `.none` and passed the 16-byte
        // {ptr,len} header through by ABI accident (first field lands in the
        // first register); the issue-0191 guard now rejects that weld, so the
        // legitimate literal case needs this modeled arm.
        if (src_ty == .string and !dst_ty.isBuiltin()) {
            const di = self.l.module.types.get(dst_ty);
            if (di == .many_pointer and (di.many_pointer.element == .u8 or di.many_pointer.element == .i8)) {
                return .string_to_cstring;
            }
        }
        if (src_ty == .cstring and dst_ty == .string) return .cstring_to_string_reject;
        if (src_ty == .any and dst_ty != .any) return .unbox_any;
        if (dst_ty == .any and src_ty != .any) return .box_any;

        if (!src_ty.isBuiltin() and !dst_ty.isBuiltin()) {
            if (self.l.module.types.get(src_ty) == .closure and self.l.module.types.get(dst_ty) == .function) {
                return .closure_to_fn_reject;
            }
        }

        // Tuple → Tuple, same arity. A STRUCT source of the same arity
        // coerces element-wise too — an untyped `.{ }` literal self-types as
        // an anonymous struct, and its values flow into tuple slots (a catch
        // fallback for a multi-value failable, a tuple-typed field) exactly
        // as the old `.( )` tuple literal did.
        if (!src_ty.isBuiltin() and !dst_ty.isBuiltin()) {
            const si = self.l.module.types.get(src_ty);
            const di = self.l.module.types.get(dst_ty);
            if (si == .tuple and di == .tuple and si.tuple.fields.len == di.tuple.fields.len) {
                return .tuple_elementwise;
            }
            if (si == .@"struct" and di == .tuple and si.@"struct".fields.len == di.tuple.fields.len) {
                return .struct_to_tuple;
            }
        }

        // Fixed array → slice of the same element: an aggregate array value
        // (e.g. a `.[...]` literal passed directly as a call arg) needs to be
        // materialized into addressable storage and wrapped in a {ptr,len}
        // header. Without this the array value is passed where a slice is
        // expected — the callee reads the header off the wrong bytes (issue
        // 0084). The local-bound path already does this conversion on its own.
        if (!src_ty.isBuiltin() and !dst_ty.isBuiltin()) {
            const si = self.l.module.types.get(src_ty);
            const di = self.l.module.types.get(dst_ty);
            if (si == .array and di == .slice and si.array.element == di.slice.element) {
                return .array_to_slice;
            }
            // `[*]T → []T`: a many-pointer carries NO length, so it cannot form a
            // `{ptr,len}` slice header implicitly. Silently passing the bare 8-byte
            // pointer where a 16-byte fat pointer is expected corrupts the callee's
            // view (garbage `.len`, mis-aligned reads) — at comptime it segfaults
            // (issue 0141), at runtime it fails LLVM verification. Reject loudly so
            // the user supplies the length via `ptr[0..len]`.
            if (si == .many_pointer and di == .slice) {
                return .many_to_slice_reject;
            }
        }

        // Optional → Concrete unwrap (narrowing).
        if (!src_ty.isBuiltin()) {
            const src_info = self.l.module.types.get(src_ty);
            if (src_info == .optional) {
                const child_ty = src_info.optional.child;
                // `?T → bool` is NOT a presence test. The unwrap-then-narrow
                // ladder below would extract the payload and narrow it to `i1`,
                // which silently yields `false` for every optional (issue 0169).
                // There is no implicit optional→bool coercion in the language
                // (only `T → ?T` wrapping and flow-sensitive narrowing); a bool
                // position wants an explicit presence test. Reject loudly unless
                // the payload is itself a bool (`?bool → bool` is a genuine
                // unwrap of a bool payload, handled by the same arm below).
                if (dst_ty == .bool and child_ty != .bool) {
                    return .optional_to_bool_reject;
                }
                if (child_ty == dst_ty or (dst_ty.isBuiltin() and child_ty.isBuiltin())) {
                    return .optional_unwrap;
                }
                // ?A → ?B: a presence-preserving payload coercion. Without a
                // dedicated arm this fell to `.optional_wrap` (dst is optional),
                // which unwrapped the SOURCE optional unconditionally and re-
                // wrapped it as always-present — turning a null `?i32` into a
                // present `?i64` carrying the zero payload (issue 0180: generic
                // `??` returning the wrong fallback). Only meaningful when the
                // children differ (same-type optionals are `.no_op` already).
                if (!dst_ty.isBuiltin() and self.l.module.types.get(dst_ty) == .optional) {
                    return .optional_to_optional;
                }
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
        const src_ptr = (!src_ty.isBuiltin() and self.l.module.types.get(src_ty) == .pointer) or src_ty == .cstring;
        const dst_ptr = (!dst_ty.isBuiltin() and self.l.module.types.get(dst_ty) == .pointer) or dst_ty == .cstring;

        if (src_int and dst_float) return .int_to_float;
        if (src_float and dst_int) return .float_to_int;
        if ((src_ptr and dst_int) or (src_int and dst_ptr)) return .ptr_int_bitcast;

        const src_bits = self.l.typeBitsEx(src_ty);
        const dst_bits = self.l.typeBitsEx(dst_ty);
        if (src_bits > 0 and dst_bits > 0) {
            if (dst_bits < src_bits) return .narrow;
            if (dst_bits > src_bits) return .widen;
        }
        return .none;
    }

    /// The `xx`-operator head decision for `lowerXX`. `.coerce` defers to the
    /// built-in ladder (`coerceToType` / `classify`) + the user-`Into` fallback.
    /// Branch order mirrors `lowerXX` exactly.
    pub const XXPlan = enum {
        unbox_any, // src is Any → unbox (lowerXX adds the f32/f64 match dispatch)
        no_op, // src == dst
        erase_protocol, // dst is a protocol → buildProtocolErasure
        erase_protocol_wrap, // dst is ?P (protocol child) → node-aware erase to P, then wrap
        protocol_to_pointer, // src is a protocol, dst is a pointer → recover ctx
        protocol_to_raw, // src is a protocol, dst is ProtocolRaw → build {ctx, type_id} field-wise
        protocol_to_any, // src is a protocol, dst is any → the {ctx, type_id} prefix view
        coerce, // built-in ladder + user `Into` fallback
    };

    /// Is `dst_ty` the `ProtocolRaw` view shape — a struct named
    /// "ProtocolRaw" with a pointer field "ctx" and a `Type` field
    /// "type_id"? Name AND shape gate the modeled protocol→raw conversion
    /// together, so an unrelated same-named user struct with a different
    /// shape can never hijack it (and an identical one converts soundly by
    /// construction).
    fn isProtocolRawDst(self: CoercionResolver, dst_ty: TypeId) bool {
        if (dst_ty.isBuiltin()) return false;
        const info = self.l.module.types.get(dst_ty);
        if (info != .@"struct") return false;
        const st = info.@"struct";
        if (!std.mem.eql(u8, self.l.module.types.getString(st.name), "ProtocolRaw")) return false;
        if (st.fields.len != 2) return false;
        if (!std.mem.eql(u8, self.l.module.types.getString(st.fields[0].name), "ctx")) return false;
        const fty = st.fields[0].ty;
        if (fty.isBuiltin() or self.l.module.types.get(fty) != .pointer) return false;
        if (!std.mem.eql(u8, self.l.module.types.getString(st.fields[1].name), "type_id")) return false;
        return st.fields[1].ty == .type_value;
    }

    /// Is `dst_ty` the `AnyRaw` view shape — a struct named "AnyRaw" with
    /// a pointer field "data" and a `Type` field "type_id"? Same
    /// name-AND-shape gate as `isProtocolRawDst`. Consulted ONLY by the
    /// POSTFIX arm (`av.(AnyRaw)` is the raw-view retrieval): `xx av`
    /// keeps its unbox meaning for EVERY target, AnyRaw included — the
    /// pure-sx assert helpers (`__sx_cast_maybe` & co.) and any generic
    /// `(av: any) -> $T { xx av }` rely on the unbox being universal.
    pub fn isAnyRawDst(self: CoercionResolver, dst_ty: TypeId) bool {
        if (dst_ty.isBuiltin()) return false;
        const info = self.l.module.types.get(dst_ty);
        if (info != .@"struct") return false;
        const st = info.@"struct";
        if (!std.mem.eql(u8, self.l.module.types.getString(st.name), "AnyRaw")) return false;
        if (st.fields.len != 2) return false;
        if (!std.mem.eql(u8, self.l.module.types.getString(st.fields[0].name), "data")) return false;
        const fty = st.fields[0].ty;
        if (fty.isBuiltin() or self.l.module.types.get(fty) != .pointer) return false;
        if (!std.mem.eql(u8, self.l.module.types.getString(st.fields[1].name), "type_id")) return false;
        return st.fields[1].ty == .type_value;
    }

    pub fn classifyXX(self: CoercionResolver, src_ty: TypeId, dst_ty: TypeId) XXPlan {
        if (src_ty == .any) return .unbox_any;
        if (src_ty == dst_ty) return .no_op;
        if (self.l.getProtocolInfo(dst_ty) != null) return .erase_protocol;
        // dst is `?P` with a protocol child: erase to the child with the
        // operand NODE in hand (borrow-mode for lvalue sources, exactly like
        // the plain `xx s : P` path), then wrap inline. Falling through to
        // `.coerce` would reach the node-less value-erasure arm, which
        // heap-boxes the receiver through context.allocator with no owner to
        // ever free it (issue 0213). Excluded sources take the ladder as
        // before: an optional (`?A → ?P` is presence-preserving), `void`
        // (the null literal), and a source already equal to the child
        // (plain wrap, no erasure needed).
        if (!dst_ty.isBuiltin() and self.l.module.types.get(dst_ty) == .optional) {
            const child = self.l.module.types.get(dst_ty).optional.child;
            const src_is_optional = !src_ty.isBuiltin() and self.l.module.types.get(src_ty) == .optional;
            if (self.l.getProtocolInfo(child) != null and src_ty != child and
                src_ty != .void and !src_is_optional) return .erase_protocol_wrap;
        }
        if (self.l.getProtocolInfo(src_ty) != null and !dst_ty.isBuiltin() and
            self.l.module.types.get(dst_ty) == .pointer) return .protocol_to_pointer;
        if (self.l.getProtocolInfo(src_ty) != null and self.isProtocolRawDst(dst_ty)) return .protocol_to_raw;
        // Protocol → any (explicit): the CONCRETE view — {data = ctx,
        // type_id} read straight off the value's prefix (RTTI Option B).
        // The IMPLICIT boxing of a protocol value (`av : any = s`) is
        // untouched: it still boxes the protocol value itself.
        if (self.l.getProtocolInfo(src_ty) != null and dst_ty == .any) return .protocol_to_any;
        return .coerce;
    }
};
