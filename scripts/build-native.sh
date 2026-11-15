#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/native/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
if ! command -v cargo >/dev/null 2>&1; then
    if [ -f "$HOME/.cargo/env" ]; then source "$HOME/.cargo/env"; fi
fi
# The version comes from VERSION at the root, its only source (the site reads it too); the build
# number goes up by one with every version handed to QA.
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD=163
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Error: VERSION debe ser X.Y.Z (dice «%s»).\n' "$VERSION" >&2
    exit 1
fi
cargo build --release --locked --manifest-path engine/Cargo.toml
xcrun swift build --disable-sandbox --package-path native -c release
SWIFT_BIN="$(xcrun swift build --disable-sandbox --package-path native -c release --show-bin-path)"
APP_PATH="$PROJECT_ROOT/build/native.noindex/Stack.app"
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
# Licenses of third-party code linked into the app (SwiftTerm, MIT: its notice must travel with it).
mkdir -p "$APP_PATH/Contents/Resources/Acknowledgements"
cp native/.build/checkouts/SwiftTerm/LICENSE "$APP_PATH/Contents/Resources/Acknowledgements/SwiftTerm-LICENSE.txt"
# AppKit localizes the standard menus (Archivo, Edición, Ventana…) only when the main bundle declares the language.
mkdir -p "$APP_PATH/Contents/Resources/es.lproj"
printf '"CFBundleName" = "Stack";\n"CFBundleDisplayName" = "Stack";\n' > "$APP_PATH/Contents/Resources/es.lproj/InfoPlist.strings"
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ButakeStack</string>
<key>CFBundleDevelopmentRegion</key><string>es</string>
<key>CFBundleLocalizations</key><array><string>es</string></array>
<key>CFBundleAllowMixedLocalizations</key><true/>
<key>CFBundleIdentifier</key><string>cl.butake.stack.native</string>
<key>CFBundleName</key><string>Stack</string>
<key>CFBundleDisplayName</key><string>Stack</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>cl.butake.stack</string><key>CFBundleURLSchemes</key><array><string>butakestack</string></array></dict></array>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>ButakeLogo.png</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Butake SpA.</string>
</dict></plist>
PLIST
# Inside out: the engine (also run by the session agent and the AWS credential process) and then
# the app, with the same stable identity (scripts/signing.sh).
source "$PROJECT_ROOT/scripts/signing.sh"
stack_sign "$APP_PATH/Contents/Resources/butake-stack" cl.butake.stack.engine
stack_sign "$APP_PATH" cl.butake.stack.native
codesign --verify --deep --strict "$APP_PATH"
printf '%s\n' "$APP_PATH"
