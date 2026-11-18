#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/scripts/build-native.sh"
exec "$PROJECT_ROOT/build/native.noindex/Stack.app/Contents/MacOS/ButakeStack"
