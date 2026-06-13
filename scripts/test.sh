#!/usr/bin/env bash
# Build and run the SoundCtl self-test suite (no Xcode/XCTest required).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" 2>&1 | tail -3
"$ROOT/.build/debug/SoundCtl" --self-test
