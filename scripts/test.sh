#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/build-macos.sh"
python3 "$ROOT/scripts/test-macos.py"
bash "$ROOT/scripts/build-android.sh" "$@"
python3 "$ROOT/tests/discovery_recovery.py"
python3 -m unittest discover -s "$ROOT/tests" -p "test_*release*.py"
# Device integration is deliberately separate so ordinary tests do not interrupt a live display:
# python3 tests/device_protocol.py
