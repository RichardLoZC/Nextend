# Nextend

**Turn an Android tablet into an extended display for your Mac.**

[简体中文](README.zh-CN.md) · [Releases](https://github.com/RichardLoZC/Nextend/releases) · [Architecture](docs/ARCHITECTURE.md)

Nextend is a native macOS and Android app with a liquid glass interface. It creates a separate HiDPI desktop, encodes it on the Mac, and displays it on the tablet over paired, encrypted USB or Wi-Fi.

## Features

- A real extended desktop with 2× HiDPI, not screen mirroring.
- Hardware HEVC / H.264, 3200 × 2136 or 2400 × 1600, and 60 / 90 / 120 fps targets.
- SDR and optional HLG 10-bit HDR, with verified output and SDR fallback.
- Encrypted USB through ADB; encrypted Wi-Fi after USB pairing.
- Mac background operation: closing the window keeps the connection active. Reopen from the Dock or menu bar; choose Quit to stop the app.
- A clean tablet view. Tap the video for controls and connection diagnostics.
- Optional FPS overlay based on actual MediaCodec rendered-frame callbacks. Drag it anywhere; choose color, font and size. Preferences survive restarts.
- Chinese and English, switchable on each device without reconnecting.

The current release is **0.4.0**. Nextend was previously called PadBridge; internal app identifiers and pairing storage retain that name so upgrades preserve pairing.

## Requirements and limits

Tested on an M4 MacBook Air (macOS 27.0.1) and Xiaomi Pad 7 Ultra (Android 16). Other hardware has not been validated.

- Runtime: Apple Silicon Mac, macOS 14+, and Android 11+. HDR additionally requires compatible macOS capture, HEVC Main10 hardware, and an HLG display.
- USB: Android USB debugging and an authorized Mac. Xiaomi devices may also require enabling USB installation.
- Wi-Fi: both devices on a reachable local network; VPN settings must permit local traffic.
- The Android app stays in the foreground during streaming. Sleep, network loss or leaving the tablet app ends the connection.
- No audio, touch/input forwarding, automatic discovery or automatic reconnect.
- Higher frame rates are targets, not guarantees. Start with USB at 60 fps. Static desktops may produce fewer frames.

HDR supports BT.2020 / HLG, limited-range 10-bit 4:2:0. PQ / HDR10 and Dolby Vision are not supported. Physical panel brightness and color accuracy have not been measured. The virtual display uses private macOS APIs, and HDR capture uses a deprecated API; revalidation is needed after OS updates.

## Install and connect

Download the matching Mac ZIP and Android APK from [Releases](https://github.com/RichardLoZC/Nextend/releases), or build from source. These are development builds: the Mac app is ad-hoc signed and not notarized; the Android APK is debuggable because the current USB pairing method uses `adb run-as`.

1. Install and open Nextend on the tablet; authorize USB debugging.
2. Move `Nextend.app` into `/Applications` or `~/Applications`, then open it. Use **Screen recording** to grant permission in System Settings, then reopen the app if prompted.
3. Select **USB** on both devices and click **Connect** on the Mac. Use **Arrange displays** to position the new desktop.
4. After USB pairing, select **Encrypted Wi-Fi** on the tablet. Enter its displayed IPv4 address on the Mac, select the correct interface (usually `en0`), and connect. After changing networks, select Wi-Fi again on the tablet to bind its new address.
5. To use HDR, disconnect first, enable HDR on the Mac, then reconnect. **HDR · HLG 10-bit** confirms the output format; an unavailable HDR path falls back to SDR with a reason.

The Mac language selector is in the top-right corner and menu bar. The tablet language selector and FPS settings are in its control menu. Tap the video or FPS overlay to show or hide that menu. Dragging the FPS overlay only moves it; it does not send input to the Mac.

Closing the Mac window keeps streaming. **Disconnect** stops the session; **Quit Nextend** also exits the app and releases the virtual display. macOS moves its windows back to the remaining displays.

If a rebuilt Mac app reports missing screen-recording permission despite an enabled switch, remove the old Nextend entry in System Settings, add the current app, and reopen it. Ad-hoc signing binds authorization to each build; a stable developer signature would be needed for production distribution. Wi-Fi also requires local-network permission.

## Build

Use Command Line Tools with the macOS 26 SDK or newer, JDK 17, Android SDK 36, and ADB. Full Xcode is not required. The native glass material falls back on macOS versions before 26.

```sh
./scripts/build-macos.sh
./scripts/build-android.sh
./scripts/install-usb.sh
mkdir -p "$HOME/Applications"
ditto outputs/Nextend.app "$HOME/Applications/Nextend.app"
open "$HOME/Applications/Nextend.app"
```

Quit the installed app before replacing it. Run the app from Applications: launching inside Documents can make VideoToolbox wait for protected-folder access.

The Android build pins Gradle 8.13, Android Gradle Plugin 8.11.1 and Kotlin 2.2.0. Scripts detect Homebrew JDK 17; other installations can set `JAVA_HOME`, `ANDROID_HOME` and `ADB`. Pass `--offline` to the Android script when dependencies are cached. Build products go to `outputs/`; caches and local reports go to ignored directories.

## Validation

```sh
./scripts/test.sh --offline
python3 tests/display_lifecycle.py
python3 tests/hdr_fallback.py
python3 tests/device_protocol.py
```

Run display and streaming tests one at a time. Lifecycle checks create a temporary virtual display. The fallback test needs an existing local USB pairing key; protocol tests need the tablet waiting in USB mode and Python `cryptography`.

```sh
outputs/Nextend.app/Contents/MacOS/Nextend --capture-test --require-hdr --seconds 30 --report outputs/hdr.json
outputs/Nextend.app/Contents/MacOS/Nextend --help
```

`--capture-test` includes desktop capture. `--benchmark` uses synthetic frames and does not validate screen capture. The FPS overlay measures rendered callbacks, not the panel's refresh rate or optical latency.

See [0.4.0 validation](docs/RELEASE-0.4.md), [0.3.0 HDR measurements](docs/HDR-VALIDATION.md) and [earlier SDR measurements](docs/VALIDATION.md). Short smoke tests do not establish long-term stability. Historical measurements describe their original builds, not every subsequent release.

## Source and design

- [`macos/`](macos): AppKit, virtual-display helper, capture, Metal HDR conversion and VideoToolbox.
- [`android/`](android): Kotlin, SurfaceView, MediaCodec, local controls and FPS overlay.
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md): encrypted protocol and statistics definitions.
- [`skills/liquid-glass-interface/`](skills/liquid-glass-interface): reusable design skill with native and web guidance.

Licensed under **GPL-3.0**. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md). This is an independent project, not an official OpenDisplay distribution. Use the matching Nextend apps together.
