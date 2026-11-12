#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/native/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
if ! command -v cargo >/dev/null 2>&1; then
    if [ -f "$HOME/.cargo/env" ]; then source "$HOME/.cargo/env"; fi
fi
cargo build --release --locked --manifest-path engine/Cargo.toml
xcrun swift build --disable-sandbox --package-path native -c release
SWIFT_BIN="$(xcrun swift build --disable-sandbox --package-path native -c release --show-bin-path)"
APP_PATH="$PROJECT_ROOT/build/native.noindex/Butake Stack.app"
# Rebuilt from scratch: files removed from the project never linger in the bundle, and signed
# Mach-O files are replaced, never overwritten in place (the kernel kills those).
rm -rf "${APP_PATH:?}"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$SWIFT_BIN/ButakeStack" "$APP_PATH/Contents/MacOS/ButakeStack"
cp engine/target/release/butake-stack "$APP_PATH/Contents/Resources/butake-stack"
for resource in "$SWIFT_BIN/"*.bundle; do
    if [ -d "$resource" ]; then ditto "$resource" "$APP_PATH/Contents/Resources/$(basename "$resource")"; fi
done
cp native/Sources/ButakeStack/Resources/ButakeLogo.png "$APP_PATH/Contents/Resources/ButakeLogo.png"
# AppKit localizes the standard menus (Archivo, Edición, Ventana…) only when the main bundle declares the language.
mkdir -p "$APP_PATH/Contents/Resources/es.lproj"
printf '"CFBundleName" = "Butake Stack";\n"CFBundleDisplayName" = "Butake Stack";\n' > "$APP_PATH/Contents/Resources/es.lproj/InfoPlist.strings"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ButakeStack</string>
<key>CFBundleDevelopmentRegion</key><string>es</string>
<key>CFBundleLocalizations</key><array><string>es</string></array>
<key>CFBundleAllowMixedLocalizations</key><true/>
<key>CFBundleIdentifier</key><string>cl.butake.stack.native</string>
<key>CFBundleName</key><string>Butake Stack</string>
<key>CFBundleDisplayName</key><string>Butake Stack</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.1</string>
<key>CFBundleVersion</key><string>131</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>cl.butake.stack</string><key>CFBundleURLSchemes</key><array><string>butakestack</string></array></dict></array>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>ButakeLogo.png</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Butake SpA.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP_PATH"
printf '%s\n' "$APP_PATH"
