#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/outputs/Nextend.app/Contents/MacOS/Nextend"
SECONDS_TO_RUN="${1:-30}"
mkdir -p "$ROOT/outputs/benchmarks"
for FPS in 60 90 120; do
  "$APP" --benchmark --fps "$FPS" --seconds "$SECONDS_TO_RUN" \
    --report "$ROOT/outputs/benchmarks/usb-${FPS}.json"
done
