#!/bin/bash
# build_app.sh — production pipeline for ClipVault
#   1. Unit tests must pass (native arch)
#   2. Universal release build (arm64 + x86_64)
#   3. .icns assembly from rendered brand assets
#   4. .app bundle assembly with full Info.plist
#   5. Ad-hoc codesign + verification
#   6. Distribution archives: ZIP always, DMG when hdiutil cooperates
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Version identity comes from VERSION + git; never hardcode it here.
source "$ROOT/Scripts/version.sh"
VERSION="$(cv_version)"
cv_validate_semver "$VERSION"
BUILD_NUMBER="$(cv_build_number)"
SOURCE_COMMIT="$(cv_commit)"
BUNDLE_ID="app.clipvault.ClipVault"

echo "▶︎ Building ClipVault $VERSION (build $BUILD_NUMBER, commit $SOURCE_COMMIT)"

APP_NAME="ClipVault"
STAGE="$ROOT/dist/stage"
APP="$STAGE/$APP_NAME.app"

echo "▶︎ Step 0/6 · SPM build gate (module boundary sanity)"
swift build >/dev/null || { echo "SPM debug build failed — module boundary regression"; exit 1; }

echo "▶︎ Step 1/6 · Tests"
swift run ClipVaultTests >/tmp/clipvault-tests.log 2>&1 || { cat /tmp/clipvault-tests.log; exit 1; }
grep -E "tests passed" /tmp/clipvault-tests.log | tail -1

echo "▶︎ Step 2/6 · Universal release build (arm64 + x86_64)"
# SPM cannot produce universal binaries without full Xcode (xcbuild), so we
# compile directly with swiftc: single-module, per-arch, then lipo.
BUILD=".build/manual"
rm -rf "$BUILD/src" "$BUILD/arm64" "$BUILD/x86_64"
mkdir -p "$BUILD/src" "$BUILD/arm64" "$BUILD/x86_64"
find Sources/ClipVaultCore -name '*.swift' | sort | while read -r f; do cp "$f" "$BUILD/src/"; done
cp Sources/ClipVault/main.swift "$BUILD/src/main.swift"
# Single-module compile: drop the module import (everything is one module here).
sed -i '' '/^import ClipVaultCore$/d' "$BUILD/src/main.swift"
for ARCH in arm64 x86_64; do
    swiftc -O -whole-module-optimization \
           -target "$ARCH-apple-macos13.0" \
           "$BUILD"/src/*.swift \
           -o "$BUILD/$ARCH/$APP_NAME"
done
UNIVERSAL_BIN="$BUILD/$APP_NAME"
lipo -create "$BUILD/arm64/$APP_NAME" "$BUILD/x86_64/$APP_NAME" -output "$UNIVERSAL_BIN"
lipo -archs "$UNIVERSAL_BIN"

echo "▶︎ Step 3/6 · Icon set (.icns)"
rm -rf "$ROOT/Resources/AppIcon.iconset"
mkdir -p "$ROOT/Resources/AppIcon.iconset"
cp "$ROOT"/Resources/brand/icon_*.png "$ROOT/Resources/AppIcon.iconset/"
mkdir -p "$ROOT/Resources"
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"

echo "▶︎ Step 4/6 · Bundle assembly"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$UNIVERSAL_BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CVSourceCommit</key>
    <string>$SOURCE_COMMIT</string>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>ClipVault uses Accessibility only to press ⌘V for you when you choose Quick Paste. It never reads other apps' content or your keystrokes.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 ClipVault. All rights reserved.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

echo "▶︎ Step 5/6 · Ad-hoc codesign"
codesign --force --deep --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Signature|TeamIdentifier|Identifier=" || true

echo "▶︎ Step 6/6 · Distribution archive"
rm -f "dist/$APP_NAME-$VERSION-universal.dmg" "dist/$APP_NAME-$VERSION.zip"
ln -sfn /Applications "$STAGE/Applications"

# The ZIP is produced unconditionally — it is the artifact CI, the release
# workflow and the install instructions all rely on. The DMG is a nicety on
# top: a wedged root-owned diskimages-helper can deny it ("Resource busy"),
# and that must never fail the build or leave us with no archive at all.
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$APP_NAME-$VERSION.zip"
echo "ZIP created."

if hdiutil create -volname "$APP_NAME $VERSION" \
                  -srcfolder "$STAGE" \
                  -ov -format UDZO \
                  "dist/$APP_NAME-$VERSION-universal.dmg" >/dev/null 2>&1; then
    echo "DMG created."
else
    echo "DMG skipped — hdiutil unavailable (wedged diskimages-helper?); the ZIP stands alone."
fi

echo ""
echo "✔ Artifacts:"
ls -lh dist/ | grep -E "$VERSION"
