#!/bin/bash
# Arma build/Butake-Stack.dmg: la app en release y un acceso a Aplicaciones para instalar arrastrando.
#
# Con un certificado «Developer ID Application» en el llavero, firma con hardened runtime,
# notariza con Apple y adjunta el ticket (staple): macOS abre la app sin advertencias.
# Sin certificado, firma ad hoc y macOS pide confirmar la primera apertura.
#
# Variables opcionales:
#   SIGN_IDENTITY   identidad a usar (por omisión, el primer «Developer ID Application» del llavero)
#   NOTARY_PROFILE  perfil guardado con `xcrun notarytool store-credentials` (por omisión «butake-notary»)
#   SKIP_NOTARIZE=1 firma con Developer ID pero no envía a Apple
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
./scripts/build-native.sh >/dev/null
APP="build/native.noindex/Butake Stack.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="build/dmg.noindex"
OUT="build/Butake-Stack.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-butake-notary}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"

if [ -n "$IDENTITY" ]; then
    echo "Firmando con: $IDENTITY"
    # De adentro hacia afuera: primero el motor (ejecutable auxiliar), luego la app.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/butake-stack"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=1 "$APP"
else
    echo "Sin certificado Developer ID: firma ad hoc (macOS pedirá confirmar la primera apertura)."
fi

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Butake Stack.app"
ln -s /Applications "$STAGE/Aplicaciones"
# Installer window: brand background, the app on the left and Aplicaciones on the right. The layout
# is written by Finder (AppleScript); if Finder can't be automated, the plain image is made instead.
VOLUME="Butake Stack $VERSION"
mkdir -p "$STAGE/.background"
swift scripts/dmg-background.swift "$STAGE/.background" >/dev/null
tiffutil -cathidpicheck "$STAGE/.background/dmg-background.png" "$STAGE/.background/dmg-background@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
rm -f "$STAGE/.background/"*.png
RW="build/Butake-Stack-rw.dmg"
rm -f "$RW"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT="/Volumes/$VOLUME"
[ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -force -quiet
hdiutil attach -readwrite -noverify -noautoopen "$RW" >/dev/null
if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 600}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "Butake Stack.app" of container window to {170, 190}
        set position of item "Aplicaciones" of container window to {490, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "Ventana del instalador con fondo y disposición."
else
    echo "Finder no se pudo automatizar: DMG sin fondo."
fi
SetFile -a C "$MOUNT" 2>/dev/null || true
SetFile -a E "$MOUNT/Butake Stack.app" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" >/dev/null
rm -f "$RW"
rm -rf "$STAGE"

if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$OUT"
    if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
        echo "Enviando a notarizar (perfil $NOTARY_PROFILE)… puede tardar unos minutos."
        xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$OUT"
        xcrun stapler validate "$OUT"
        spctl --assess --type open --context context:primary-signature --verbose=2 "$OUT" || true
    fi
fi

(cd build && shasum -a 256 Butake-Stack.dmg | tee Butake-Stack.dmg.sha256)
echo "$OUT ($(du -h "$OUT" | cut -f1)) · versión $VERSION · $(lipo -archs "$APP/Contents/MacOS/ButakeStack") · ${IDENTITY:-ad hoc}"
