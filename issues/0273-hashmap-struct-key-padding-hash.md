# 0273 — hash maps hash indeterminate struct padding → equal struct keys miss

> **RESOLVED** (fix option 1 — field-wise structural hash, contained to the stdlib).
>
> **Root cause:** `map_hash_key` hashed all `size_of(K)` bytes of a key, including
> interior/trailing padding. A struct literal only writes its declared fields, so
> padding holds indeterminate stack garbage; `==` is field-wise and ignores it, so
> two field-equal struct keys built with different stack churn between them hashed
> differently → `get` missed (HashMap) / a phantom duplicate was appended
> (IndexMap).
>
> **Fix:** `library/modules/std/map.sx` — `map_hash_key` now delegates to a new
> comptime-unrolled, `is_struct`-gated recursion `map_hash_into(v, h)` that folds a
> running FNV-1a state field-by-field, SKIPPING padding, consistent with `==`:
> `string` (key or field) → content hash; struct/tuple → recurse per field
> (nested aggregates recurse); scalar/enum/bool/pointer → raw-byte leaf. Uses a
> LOCAL `field_type :: ($T, i64) -> Type #builtin;` forward-decl (no `meta.sx`
> import, so the prelude stays free of the metatype machinery). Enabled by the
> issue-0274 compiler support (`is_struct($T)` gate + enum-variant inference).
> `library/modules/std/hash.sx` gained `fnv1a_fold(h, data, len)` (incremental
> FNV from a running hash); `fnv1a_bytes` is now `fnv1a_fold(FNV_OFFSET_BASIS, …)`
> (byte-identical output — 0720 FNV vectors unchanged).
>
> **Regression test:** `examples/modules/0846-modules-hashmap-struct-key.sx`
> (padded struct key found after stack churn in both map kinds, struct-with-string
> field, struct-with-enum field, nested struct, and distinct keys not colliding).

## Symptom

`HashMap($K,$V)` / `IndexMap($K,$V)` with a **struct key that has padding**
break the table invariant `a == b ⇒ hash(a) == hash(b)`: two field-wise-equal
keys can hash differently, so a lookup on a logically-equal, present key returns
not-found (HashMap) or appends a phantom duplicate entry (IndexMap).

## Reproduction (reliable, with stack churn between the two constructions)

```sx
#import "modules/std.sx";
#import "modules/std/mem.sx";
#import "modules/std/hash.sx";

K :: struct { a: u8; b: i64; }   // size 16: 1 byte + 7 pad + 8

churn :: (n: i64) -> i64 {
    buf : [64]i64 = ---; i := 0; s := 0;
    while i < 64 { buf[i] = n + i; s += buf[i]; i += 1; } s
}

main :: () {
    gpa := GPA.init();
    m : HashMap(K, i64) = .{};
    k1 := K.{ a = 1, b = 2 };
    m.put(k1, 100, xx gpa);
    churn(7);                       // dirty the stack between the two literals
    k2 := K.{ a = 1, b = 2 };
    print("k1==k2: {}\n", k1.a == k2.a and k1.b == k2.b);   // true
    print("get found: {}\n", if v := m.get(k2) { true } else { false });  // false — BUG
    m.deinit(xx gpa);
}
```

Output: `k1==k2: true` / `get found: false`. Raw-byte hashes of the two keys
differ because the 7 padding bytes hold uninitialized stack garbage (a struct
literal only writes the declared fields; `==` is field-wise and ignores padding,
but the hash reads all 16 bytes).

## Root cause

`library/modules/std/map.sx:67`, the non-string arm of `map_hash_key`:

```sx
fnv1a_bytes(xx @key, size_of(K))
```

hashes all `size_of(K)` bytes — including interior/trailing padding. Sound for
keys with a unique byte representation (integers; `string` has its own content
arm), UNSOUND for any aggregate key with padding. The file header advertises
"any other (POD) key → raw `size_of(K)` byte hash" as supported, so struct keys
are a *claimed* but broken use case. Reading uninitialized padding also makes the
hash depend on prior stack contents (nondeterministic / heisenbug).

Zig's `AutoHashMap` (which this file ports) avoids this by hashing field-by-field
and/or gating on `std.meta.hasUniqueRepresentation`.

## Impact

Latent: every committed test (`0721/0722/0844/0845`) uses `i64`/`string` keys,
which are sound — so nothing shipped is broken. Struct keys (a documented,
untested path) are.

## Fix options

sx HAS comptime reflection (`field_count($T)`, `field_value(s, i)` — used by
`fmt.sx`'s `struct_to_string`), so a stdlib fix is feasible:

1. **Field-wise hash in `map_hash_key`** (Zig-parity, contained to map.sx): for a
   struct key, fold each field's bytes into a running FNV state, recursing into
   nested aggregate fields, skipping padding. Keeps the raw-byte fast path for
   scalars and the content arm for `string`. Most correct; most work (needs an
   incremental FNV + reflection recursion + care with `field_value`'s type-erased
   return).
2. **Compiler zero-inits struct-literal padding** (root-cause, language-wide):
   makes struct values byte-deterministic, so raw-byte hashing/compare/serialize
   all become sound. Broader; a language-semantics decision.
3. **Narrow the claim**: document that keys must have a unique byte representation
   (integers / `string`), and reject a padded aggregate key with a compile-time
   diagnostic (needs a `size_of(K)` vs sum-of-field-sizes check via reflection).
   Minimal; honest; defers real struct-key support.

## Regression test to add once fixed

A `HashMap(K, i64)` / `IndexMap(K, i64)` with a padded struct key
(`struct { a: u8; b: i64; }`), inserting then looking up a *separately
constructed* field-equal key (with stack churn between), asserting FOUND and no
phantom duplicate. (This is coverage gap **G2** from the 20-round review.)
