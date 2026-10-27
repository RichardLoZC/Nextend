#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/outputs/Nextend.app"
# This is a generated bundle, never the installed application. Start fresh so
# cloud-provider history and previous signing resources cannot enter a release.
if [ -d "$APP" ]; then
  PREVIOUS="$ROOT/work/macos-bundle-$(date +%s)-$$"
  mv "$APP" "$PREVIOUS"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/work/swift-cache"
xcrun swiftc -O -whole-module-optimization -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$ROOT/work/swift-cache" \
  -import-objc-header "$ROOT/macos/CGVirtualDisplayPrivate.h" \
  "$ROOT"/macos/*.swift -o "$APP/Contents/MacOS/Nextend" \
  -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Security -framework QuartzCore -framework Metal -framework ApplicationServices
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Nextend</string>
<key>CFBundleIdentifier</key><string>dev.padbridge.mac</string>
<key>CFBundleName</key><string>Nextend</string>
<key>CFBundleDisplayName</key><string>Nextend</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.8.1</string>
<key>CFBundleVersion</key><string>13</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBonjourServices</key><array><string>_nextend._tcp</string></array>
<key>NSLocalNetworkUsageDescription</key><string>连接已配对的小米 Pad，以加密方式传输拓展屏画面。</string>
<key>NSScreenCaptureUsageDescription</key><string>采集 Nextend 创建的虚拟拓展屏，传送至小米 Pad。</string>
</dict></plist>
PLIST
# Keep the default ad-hoc cdhash requirement. An identifier-only requirement
# lets unrelated local code impersonate this app's authorization identity.
# Changed builds may need screen-recording authorization again.
cp "$ROOT/assets/brand/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
rsync -r --exclude='.duckversions' "$ROOT/macos/Resources/" "$APP/Contents/Resources/"
python3 "$ROOT/ops/mac_bundle.py" "$APP"
printf '%s\n' "$APP"
