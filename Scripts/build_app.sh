#!/bin/bash
# Builds xTool.app and dist/xTool-<version>.dmg.
# Works offline: needs only the Xcode Command Line Tools, all dependencies are in Vendor/.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/compile.sh"

VERSION="2.3.0"
BUILD_NUMBER="230"
BUNDLE_ID="ch.xtool.app"     # must stay: macOS keeps the vault in the container of this id
DIST="$ROOT/dist"
SDK="$(pick_sdk)"
echo "▸ SDK: $(basename "$SDK")"

echo "▸ Tests …"
bash "$SCRIPTS/run_tests.sh" | tail -n 1

echo "▸ Compiling (Apple Silicon and Intel) …"
compile_all arm64 release
compile_all x86_64 release
BINDIR="$OUT/universal"
mkdir -p "$BINDIR"
lipo -create "$OUT/arm64-release/xTool" "$OUT/x86_64-release/xTool" -output "$BINDIR/xTool"
echo "  Architectures: $(lipo -archs "$BINDIR/xTool")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_icns() { # $1 = out.icns, $2 = logo
    local png="$TMP/icon.png" set="$TMP/icon.iconset"
    SDKROOT="$SDK" swift "$SCRIPTS/make_icon.swift" icon "$2" "$png"
    mkdir -p "$set"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$png" --out "$set/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) "$png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$set" -o "$1"
}

write_plist() { # $1 = path, $2 = name, $3 = id, $4 = executable, $5 = category
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$2</string>
    <key>CFBundleDisplayName</key><string>$2</string>
    <key>CFBundleIdentifier</key><string>$3</string>
    <key>CFBundleExecutable</key><string>$4</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string></array>
    <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT</string>
    <key>LSApplicationCategoryType</key><string>$5</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 xTool</string>
</dict>
</plist>
PLIST
}

# Assembled and signed outside Google Drive: its extended attributes would break the signature.
APP="$OUT/stage/xTool.app"
echo "▸ Assembling xTool.app …"
rm -rf "$OUT/stage"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/xTool" "$APP/Contents/MacOS/xTool"
cat "$ROOT/Resources/Logo.png" > "$APP/Contents/Resources/Logo.png"
make_icns "$APP/Contents/Resources/AppIcon.icns" "$ROOT/Resources/Logo.png"
write_plist "$APP/Contents/Info.plist" "xTool" "$BUNDLE_ID" "xTool" "public.app-category.productivity"
xattr -cr "$APP"

echo "▸ Signing (ad hoc, App Sandbox) …"
cat "$SCRIPTS/xTool.entitlements" > "$TMP/app.entitlements"
codesign --force --options runtime --timestamp=none --entitlements "$TMP/app.entitlements" --sign - "$APP"
codesign --verify --strict --deep "$APP"

echo "▸ Creating DMG …"
STAGE="$TMP/dmg"
mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "xTool" -srcfolder "$STAGE" -ov -format UDZO "$TMP/xTool.dmg" >/dev/null
cat "$TMP/xTool.dmg" > "$DIST/xTool-$VERSION.dmg"

echo "✓ Done: $DIST/xTool-$VERSION.dmg ($(du -h "$DIST/xTool-$VERSION.dmg" | cut -f1))"
