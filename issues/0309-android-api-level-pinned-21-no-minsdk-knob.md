# 0309 — `--target android` pins API 21 (cannot link API-gated NDK libraries), and the APK bundler hardcodes `minSdkVersion="21"`

## Symptom

Two sides of the same gap — there is no way to express "this app needs
API level ≥ 26":

1. **Target shorthand pins API 21.** `--target android` expands to
   `aarch64-linux-android21` (src/main.zig, target shorthand table).
   Linking any NDK library introduced after API 21 fails:
   `ld.lld: error: unable to find library -laaudio` (AAudio exists in
   the NDK sysroot only under `usr/lib/aarch64-linux-android/26/` and
   newer; clang resolves the library dir from the triple's API suffix).
   The only spelling that works is the full triple
   `--target aarch64-linux-android26` — undiscoverable unless you read
   main.zig. (AAudio is the concrete casualty: any game/app doing
   native audio on Android needs it; OpenSL ES is deprecated.)
2. **Bundler manifest hardcodes minSdk 21.** The synthesized
   `AndroidManifest.xml` in library/modules/platform/bundle.sx writes
   `<uses-sdk android:minSdkVersion="21" ...>` unconditionally, and
   `BuildOptions` has no setter for it. An app deliberately built with
   the API-26 triple still ships an APK declaring minSdk 21: devices on
   API 21–25 can install it from a store listing and then crash at
   `dlopen` (`libaaudio.so` absent). The manifest should not be allowed
   to promise a lower floor than the binary was linked against.

Observed vs expected: `sx build --target android main.sx` with
`opts.add_link_flag("-laaudio")` in build.sx → link error (expected:
links, or at least a clear message that the API level must be raised).
And the produced APK's manifest says minSdk 21 regardless of the
triple's API suffix (expected: minSdk follows the build's API level,
or is settable).

## Reproduction

```sx
// main.sx
#import "modules/std.sx";
#import "modules/build.sx";
#import "modules/platform/bundle.sx";

#run {
    opts := build_options();
    opts.set_bundle_id("co.example.aaudiotest");
    opts.set_output_path("out/libaatest.so");
    opts.set_bundle_path("out/aatest.apk");
    opts.add_link_flag("-laaudio");
}

main :: () -> i32 { 0 }
```

- `sx build --target android main.sx` →
  `ld.lld: error: unable to find library -laaudio` (clang resolves the
  NDK library dir from the triple's API suffix; `libaaudio.so` only
  exists under API ≥ 26 dirs).
- `sx build --target aarch64-linux-android26 main.sx` → builds; then
  inspect the produced manifest: `aapt2 dump xmltree out/aatest.apk
  AndroidManifest.xml | grep minSdk` → still `21`.

## Investigation prompt

Suspected areas:

1. `src/main.zig` target shorthand expansion (`"android"` →
   `"aarch64-linux-android21"`). Options: raise the default to a
   current-ish floor (API 26 covers ~95%+ of devices and unlocks
   AAudio), or accept `android-26` / `android-34` style shorthands that
   splice the API suffix into the triple. The full-triple escape hatch
   already works, so even a docs-line in `sx build --help` naming it
   would be an improvement.
2. `library/modules/platform/bundle.sx` manifest synthesis (two
   `<uses-sdk android:minSdkVersion="21" ...>` sites, ~lines 966/990),
   plus `library/modules/build.sx` + the compiler's BuildConfig for a
   new `set_min_sdk(level)` intrinsic. Reasonable default: parse the
   API suffix from `target_triple()` when no explicit setter is used,
   so `--target aarch64-linux-android26` automatically produces
   `minSdkVersion="26"`.

Verification:

1. `sx build --target android main.sx` (or the new shorthand) links
   `-laaudio` cleanly.
2. The bundled APK's manifest minSdk equals the triple's API level (or
   the `set_min_sdk` value), verifiable via `aapt2 dump xmltree`.
3. End-to-end: `cd /Users/agra/projects/m3te && sx build --target
   android main.sx` — currently forced to spell
   `--target aarch64-linux-android26` for its AAudio backend
   (audio_android.sx) — builds unmodified and the APK installs on the
   emulator.
