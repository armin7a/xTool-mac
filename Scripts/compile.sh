#!/bin/bash
# Compiles xTool with the plain Swift compiler. Needs no network and no Swift Package Manager:
# all dependencies are in Vendor/. Sourced by build_app.sh, run_tests.sh and run_dev.sh.
#
#   compile_all <arch> <config>     arch: arm64 | x86_64     config: debug | release
#
# Results land in $OUT/<arch>-<config>/ (outside Google Drive, which locks fresh build output).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$HOME/Library/Caches/xTool-build"
DEPLOYMENT="14.0"
SODIUM_LIB="$ROOT/Vendor/swift-sodium/Clibsodium.xcframework/macos-arm64_x86_64"

# Newest SDK this compiler can read: an SDK newer than the compiler fails with "module compiled with newer Swift".
pick_sdk() {
    local sdks="$(xcrun --show-sdk-platform-path 2>/dev/null)/Developer/SDKs"
    [ -d "$sdks" ] || sdks="/Library/Developer/CommandLineTools/SDKs"
    local probe; probe="$(mktemp -d)"
    echo 'import SwiftUI' > "$probe/p.swift"
    for sdk in $(ls -d "$sdks"/MacOSX[0-9]*.sdk | sort -t X -k 2 -n -r); do
        if swiftc -typecheck -sdk "$sdk" -target arm64-apple-macos$DEPLOYMENT "$probe/p.swift" >/dev/null 2>&1; then
            rm -rf "$probe"; echo "$sdk"; return 0
        fi
    done
    rm -rf "$probe"
    echo "Kein passendes macOS-SDK gefunden." >&2
    return 1
}

# compile_module <name> <kind: lib|exe> <source dir> [extra flags…]
compile_module() {
    local name="$1" kind="$2" src="$3"; shift 3
    local sources=()
    while IFS= read -r f; do sources+=("$f"); done < <(find "$src" -name '*.swift' -not -path '*/libsodium/*' | sort)
    local common=(-module-name "$name" -swift-version 5 -target "$ARCH-apple-macos$DEPLOYMENT" -sdk "$SDK"
                  -I "$BUILD" -I "$SODIUM_LIB/Headers" -L "$BUILD" "${MODE[@]}")
    if [ "$kind" = lib ]; then
        ( cd "$BUILD" && swiftc "${common[@]}" -parse-as-library -wmo -emit-module -emit-module-path "$BUILD/$name.swiftmodule" \
            -emit-object -o "$BUILD/$name.o" "$@" "${sources[@]}" )
        rm -f "$BUILD/lib$name.a"
        libtool -static -no_warning_for_no_symbols -o "$BUILD/lib$name.a" "$BUILD/$name.o"
    else
        ( cd "$BUILD" && swiftc "${common[@]}" -parse-as-library -wmo -emit-executable -o "$BUILD/$name" "$@" "${sources[@]}" )
    fi
}

compile_all() {
    ARCH="$1"; local config="$2"
    BUILD="$OUT/$ARCH-$config"
    mkdir -p "$BUILD"
    [ -n "${SDK:-}" ] || SDK="$(pick_sdk)"
    if [ "$config" = release ]; then MODE=(-O); else MODE=(-Onone -g -DDEBUG -enable-testing); fi

    echo "  $ARCH: Abhängigkeiten …"
    compile_module ZIPFoundation lib "$ROOT/Vendor/ZIPFoundation/Sources/ZIPFoundation" -suppress-warnings
    compile_module Sodium lib "$ROOT/Vendor/swift-sodium/Sodium" -suppress-warnings
    echo "  $ARCH: XToolCore …"
    compile_module XToolCore lib "$ROOT/Sources/XToolCore"
    echo "  $ARCH: xTool …"
    compile_module XTool exe "$ROOT/Sources/XTool" -lXToolCore -lZIPFoundation -lSodium "$SODIUM_LIB/libsodium.a"
    mv -f "$BUILD/XTool" "$BUILD/xTool"
}
