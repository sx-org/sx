#!/bin/bash
# Cross-compile regression runner.
#
# For each (target, example) tuple, runs `./sx build --target <t> <example>`
# and asserts (a) exit 0 and (b) the expected output file was produced.
# Compile correctness only — these examples can't be executed on the host
# (iOS Obj-C runtime / Android NDK).
#
# Tuple list starts empty and grows as Phase 0 / 1 / 2 / 3 of the FFI plan
# add cross-only examples. Skips with a warning (still exits 0) when the
# required toolchain isn't installed, so contributors without the iOS SDK
# or Android NDK aren't blocked.
#
# Usage: ./tests/cross_compile.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SX="$ROOT_DIR/zig-out/bin/sx"
TMP_DIR="${TMPDIR:-/tmp}/sx-cross-compile"
mkdir -p "$TMP_DIR"

# Tuple format: "<target>|<example_path>"
# Add entries as cross-only examples land. Verifies the example
# compiles cleanly for the target's NDK / SDK without needing the
# host to actually run it.
TUPLES=(
    "android|examples/1336-ffi-objc-call-10-os-gate.sx"
    "android|examples/1401-ffi-jni-call-02-void.sx"
    # Step 1.24: verify the inverse OS gate — `inline if OS == .android
    # { #jni_call(...) }` must strip its body before lowering on iOS so
    # emit_llvm doesn't try to use libjvm symbols the iOS SDK lacks.
    "ios-sim|examples/1401-ffi-jni-call-02-void.sx"
    # #jni_main pipeline slice 2: an example carrying a `#jni_main
    # #jni_class(...)` decl must continue to lower + link cleanly for
    # android even without an APK build (compile-only check).
    "android|examples/1423-ffi-jni-main-01-emit.sx"
    # `super.method(args)` dispatch: lowers to JNI CallNonvirtualVoidMethod
    # against the parent class (Activity by default). Compile-only check
    # — runtime correctness is verified by on-device chess deploy.
    "android|examples/1424-ffi-jni-main-02-super.sx"
    # `Alias.new(args)` constructor dispatch: lowers to FindClass +
    # GetMethodID("<init>") + NewObject. Compile-only — runtime via chess.
    "android|examples/1425-ffi-jni-main-03-ctor.sx"
    # Week 6: iOS-simulator branch of platform.bundle. Cross-compiles
    # against the iPhoneSimulator SDK; the post-link callback then
    # writes an `.app` with the iOS-shaped Info.plist (UIDeviceFamily,
    # LSRequiresIPhoneOS, UIApplicationSceneManifest, DTPlatformName).
    "ios-sim|examples/1615-platform-ios-sim-bundle.sx"
)

PASS=0
FAIL=0
SKIP=0

toolchain_available() {
    local target="$1"
    case "$target" in
        ios|ios-sim)
            xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1
            ;;
        android|android-arm64)
            # discoverAndroidNdk in target.zig accepts $ANDROID_NDK_HOME,
            # $ANDROID_NDK_ROOT, or a scan of $HOME/Library/Android/sdk/ndk.
            [[ -n "${ANDROID_NDK_HOME:-}" || -n "${ANDROID_NDK_ROOT:-}" ]] \
                || [[ -d "$HOME/Library/Android/sdk/ndk" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

for tuple in "${TUPLES[@]:-}"; do
    [[ -z "$tuple" ]] && continue
    target="${tuple%%|*}"
    example="${tuple#*|}"
    label="$target / $(basename "$example" .sx)"

    if ! toolchain_available "$target"; then
        SKIP=$((SKIP + 1))
        printf "  %-50s SKIP (no toolchain)\n" "$label"
        continue
    fi

    out_obj="$TMP_DIR/$(basename "$example" .sx).$target.o"
    printf "  %-50s" "$label"
    "$SX" build --target "$target" -o "$out_obj" "$ROOT_DIR/$example" >/dev/null 2>&1
    rc=$?
    if [[ $rc -eq 0 && -s "$out_obj" ]]; then
        PASS=$((PASS + 1))
        echo "ok"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL (exit=$rc, output=$out_obj)"
    fi
done

echo "$PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
