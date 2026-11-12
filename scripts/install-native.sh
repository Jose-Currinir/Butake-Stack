#!/bin/bash
# Builds and installs Butake Stack into /Applications, replacing any running copy.
# The session agent points at the engine inside the installed app, so activate from there.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/scripts/build-native.sh"
osascript -e 'tell application id "cl.butake.stack.native" to quit' 2>/dev/null || true
sleep 1
pkill -x ButakeStack 2>/dev/null || true
APP="/Applications/Butake Stack.app"
BACKUP="/Applications/Butake Stack.app.anterior"
# Keep the installed copy until the new one is in place; restore it if the copy fails.
rm -rf "$BACKUP"
if [ -d "$APP" ]; then mv "$APP" "$BACKUP"; fi
if ditto "$PROJECT_ROOT/build/native.noindex/Butake Stack.app" "$APP"; then
    rm -rf "$BACKUP"
else
    rm -rf "$APP"
    if [ -d "$BACKUP" ]; then mv "$BACKUP" "$APP"; fi
    printf 'Error: no se pudo copiar la app; se conservó la versión anterior.\n' >&2
    exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
open "$APP"
printf '%s\n' "$APP"
