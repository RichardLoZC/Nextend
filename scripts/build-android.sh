#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${JAVA_HOME:-}" ] && [ -d /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
fi
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
cd "$ROOT/android"
./gradlew :app:assembleDebug :app:testDebugUnitTest --console=plain "$@"
mkdir -p "$ROOT/outputs"
cp app/build/outputs/apk/debug/app-debug.apk "$ROOT/outputs/Nextend.apk"
printf '%s\n' "$ROOT/outputs/Nextend.apk"
