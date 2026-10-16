#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB_BIN="${ADB:-/opt/homebrew/bin/adb}"
APK="$ROOT/outputs/Nextend.apk"
if [ ! -f "$APK" ]; then "$ROOT/scripts/build-android.sh"; fi
DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$($ADB_BIN devices -l | awk '/ device / && /usb:/ {print $1}')"
fi
if [ -z "$DEVICE" ] || [[ "$DEVICE" == *$'\n'* ]]; then
  printf 'Connect one authorized USB device, or pass its serial number.\n' >&2
  exit 1
fi
"$ADB_BIN" -s "$DEVICE" install -r "$APK"
"$ADB_BIN" -s "$DEVICE" shell am start -n dev.padbridge/.MainActivity
