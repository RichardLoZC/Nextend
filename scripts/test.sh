#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-macos.sh"
"$ROOT/outputs/Nextend.app/Contents/MacOS/Nextend" --self-test
"$ROOT/scripts/build-android.sh" "$@"
# Device integration is deliberately separate so ordinary tests do not interrupt a live display:
# python3 tests/device_protocol.py
