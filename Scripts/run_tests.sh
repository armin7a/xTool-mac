#!/bin/bash
# Runs the core tests (vault format, encryption, large files, password rules).
# XTOOL_LARGE_TEST=1 additionally round-trips a 5 GB file.
set -euo pipefail
source "$(dirname "$0")/compile.sh"

ARCH="$(uname -m)"
BUILD="$OUT/$ARCH-debug"
mkdir -p "$BUILD"
SDK="$(pick_sdk)"
MODE=(-Onone -g -DDEBUG -enable-testing)
compile_module ZIPFoundation lib "$ROOT/Vendor/ZIPFoundation/Sources/ZIPFoundation" -suppress-warnings
compile_module Sodium lib "$ROOT/Vendor/swift-sodium/Sodium" -suppress-warnings
compile_module XToolCore lib "$ROOT/Sources/XToolCore"

RUNNER="$BUILD/TestRunner"
mkdir -p "$RUNNER"
( cd "$RUNNER" && swiftc -module-name XToolCoreTests -swift-version 5 \
    -target "$ARCH-apple-macos$DEPLOYMENT" -sdk "$SDK" -Onone -g -enable-testing \
    -I "$BUILD" -I "$SODIUM_LIB/Headers" -L "$BUILD" \
    -lXToolCore -lZIPFoundation -lSodium "$SODIUM_LIB/libsodium.a" \
    -emit-executable -o "$RUNNER/tests" "$ROOT"/Tests/XToolCoreTests/*.swift )
"$RUNNER/tests"
