#!/bin/bash
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/python3 "$SCRIPT_ROOT/build_php.py" "$@"
