#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/native/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
if ! command -v cargo >/dev/null 2>&1; then source "$HOME/.cargo/env"; fi
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/butake-stack-tests.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT
export BUTAKE_STACK_HOME="$TEST_HOME/store"
export BUTAKE_STACK_ENGINE="$PROJECT_ROOT/engine/target/debug/butake-stack"
cargo test --locked --manifest-path engine/Cargo.toml
cargo build --locked --manifest-path engine/Cargo.toml
/usr/bin/python3 -m unittest discover -s scripts/php/tests -p 'test_*.py'
xcrun swift test --disable-sandbox --package-path native
