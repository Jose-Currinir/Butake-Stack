#!/bin/bash
# Arma build/Butake-Stack.dmg: Stack.app en release y un acceso a Aplicaciones para instalar
# arrastrando. El nombre del archivo no cambia: lo enlazan el sitio y las versiones publicadas.
# También build/Butake-Stack.zip (la app sola), que es lo que instala el actualizador de la app.
# Una versión se publica con los cuatro archivos: el .dmg, el .zip y sus .sha256.
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
APP="build/native.noindex/Stack.app"
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
ditto "$APP" "$STAGE/Stack.app"
ln -s /Applications "$STAGE/Aplicaciones"
# Installer window: brand background, the app on the left and Aplicaciones on the right. The layout
# is written by Finder (AppleScript); if Finder can't be automated, the plain image is made instead.
VOLUME="Stack $VERSION"
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
        set position of item "Stack.app" of container window to {170, 190}
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
# Nothing is written onto Stack.app itself: Finder information on the bundle (e.g. SetFile -a E)
# makes `codesign --verify --strict` fail, and the in-app updater checks new versions that way.
sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" >/dev/null
rm -f "$RW"
rm -rf "$STAGE"

# The app inside the final image must pass the check the in-app updater runs on a new version.
CHECK=$(mktemp -d)
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$CHECK" "$OUT" >/dev/null
if ! codesign --verify --deep --strict "$CHECK/Stack.app"; then
    hdiutil detach "$CHECK" -quiet || hdiutil detach "$CHECK" -force -quiet
    printf 'Error: la app del DMG no pasa codesign --strict; el actualizador la rechazaría.\n' >&2
    exit 1
fi
hdiutil detach "$CHECK" -quiet || hdiutil detach "$CHECK" -force -quiet
rmdir "$CHECK"

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

# build/Butake-Stack.zip: the app the in-app updater installs. It never mounts the DMG: macOS treats a mounted
# image like a removable volume, and reading it needs a privacy permission Stack is never asked for.
ZIP="build/Butake-Stack.zip"
rm -f "$ZIP" "$ZIP.sha256"
if [ -n "$IDENTITY" ] && [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    # The DMG's notarization covers the app inside it: the same ticket goes on the app.
    xcrun stapler staple "$APP"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
# The app inside the zip must pass what the updater checks before installing it.
CHECK=$(mktemp -d)
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/Stack.app" || { printf 'Error: la app del zip no pasa codesign --strict.\n' >&2; exit 1; }
if [ -n "$IDENTITY" ] && [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    spctl --assess --type execute "$CHECK/Stack.app" || { printf 'Error: Gatekeeper rechaza la app del zip.\n' >&2; exit 1; }
fi
rm -rf "$CHECK"
(cd build && shasum -a 256 Butake-Stack.zip | tee Butake-Stack.zip.sha256)
echo "$OUT ($(du -h "$OUT" | cut -f1)) · versión $VERSION · $(lipo -archs "$APP/Contents/MacOS/ButakeStack") · ${IDENTITY:-ad hoc}"
