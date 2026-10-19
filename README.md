# Nextend

**Turn an Android tablet into an extended display for your Mac.**

[简体中文](README.zh-CN.md) · [Releases](https://github.com/RichardLoZC/Nextend/releases) · [Architecture](docs/ARCHITECTURE.md)

Nextend is a native macOS and Android app with a liquid glass interface. It creates a separate HiDPI desktop, encodes it on the Mac, and displays it on the tablet over paired, encrypted USB or Wi-Fi.

## Features

- A real extended desktop with 2× HiDPI, not screen mirroring.
- Automatic hardware codec selection: HEVC preferred, H.264 compatibility fallback; HDR uses HEVC Main10.
- Choose USB or encrypted Wi-Fi on the Mac; the tablet listens for both and allows only one active session.
- Hardware HEVC / H.264, 3200 × 2136 or 2400 × 1600, and 60 / 90 / 120 fps targets.
- SDR and optional HLG 10-bit HDR, with verified output and SDR fallback.
- Encrypted USB through ADB; encrypted Wi-Fi after USB pairing.
- Mac background operation: closing the window hides the Dock icon and keeps the connection active. Reopen from the menu bar or Applications; the Dock icon returns with the window. Choose Quit to stop the app.
- Optional direct touch or trackpad mode, selected on the Mac. **Enable touch** defaults off and can change during a connection. Trackpad mode keeps the extended desktop visible.
- A clean tablet view with all settings and diagnostics on the Mac. The tablet waiting page can initiate a paired connection.
- Optional FPS overlay based on actual MediaCodec rendered-frame callbacks. Choose its position, color, font and size in **Pad settings** on the Mac. Preferences survive restarts.
- Chinese and English, switched on the Mac and synchronized to the tablet without reconnecting.

The current development version is **0.6.0**. Update both apps to use touch. Nextend was previously called PadBridge; internal app identifiers and pairing storage retain that name so upgrades preserve pairing.

## Requirements and limits

Tested on an M4 MacBook Air (macOS 27.0.1) and Xiaomi Pad 7 Ultra (Android 16). Other hardware has not been validated.

- Runtime: Apple Silicon Mac, macOS 14+, and Android 11+. HDR additionally requires compatible macOS capture, HEVC Main10 hardware, and an HLG display.
- USB: Android USB debugging and an authorized Mac. Xiaomi devices may also require enabling USB installation.
- Wi-Fi: both devices on a reachable local network. The tablet initiates the encrypted video socket, so a VPN that blocks incoming connections need not be disabled. A VPN that blocks all local traffic can still prevent Wi-Fi; USB does not use that route.
- The Android app stays in the foreground during streaming. Sleep, network loss or leaving the tablet app ends the connection.
- No audio, general keyboard forwarding or automatic reconnect. Bonjour discovers Macs for the tablet’s Connect button; it never establishes trust.
- Higher frame rates are targets, not guarantees. Start with USB at 60 fps. Static desktops may produce fewer frames.

HDR supports BT.2020 / HLG, limited-range 10-bit 4:2:0. PQ / HDR10 and Dolby Vision are not supported. Physical panel brightness and color accuracy have not been measured. The virtual display uses private macOS APIs, and HDR capture uses a deprecated API; revalidation is needed after OS updates.

## Install and connect

Download the matching Mac ZIP and Android APK from [Releases](https://github.com/RichardLoZC/Nextend/releases), or build from source. These are development builds: the Mac app is ad-hoc signed and not notarized; the Android APK is debuggable because the current USB pairing method uses `adb run-as`.

1. Install and open Nextend on the tablet; authorize USB debugging.
2. Move `Nextend.app` into `/Applications` or `~/Applications`, then open it. Use **Screen recording** to grant permission in System Settings, then reopen the app if prompted.
3. Select **USB** and click **Connect** on the Mac. No mode selection is needed on the tablet. Use **Arrange displays** to position the new desktop.
4. After USB pairing, disconnect and select **Encrypted Wi-Fi** on the Mac. The Mac remembers the Wi-Fi address from the authenticated USB handshake; you can also enter its address manually. Select the correct interface (usually `en0`) and connect. The tablet automatically updates its listener after network changes. Reconnect over USB to refresh the Mac’s saved address, or enter the new one manually. Switching transport requires no tablet controls.
5. To use HDR, disconnect first, enable HDR on the Mac, then reconnect. **HDR · HLG 10-bit** confirms the output format; an unavailable HDR path falls back to SDR with a reason.

The top-right Mac button switches both apps between Chinese and English. **Pad settings** controls the FPS overlay and displays decoder statistics. The tablet has no in-session menu. **Pair again** is in the Mac menu bar menu.

After USB pairing, you can also tap **Connect** on the tablet. Keep the Mac app running (its window may be closed). The tablet tries USB first and selects USB video when that request succeeds, even if the Mac previously used Wi-Fi. Otherwise it discovers the Mac with Bonjour and requests encrypted Wi-Fi. Quality settings remain on the Mac. Wireless requests hand their authenticated TCP socket to video, which performs a fresh handshake; the Mac need not open an incoming connection to the tablet. The Mac never accepts a callback address or input permission from the request.

Touch requires **System Settings → Privacy & Security → Accessibility → Nextend**. Grant it on first use, then turn **Enable touch** on again. The switch resets to off after quitting.

| Gesture | Direct touch | Trackpad |
|---|---|---|
| One finger | Tap, double-tap, drag on the extended display | Move the Mac pointer; tap / double-tap to click; tap, then touch again and move to drag |
| Two fingers | Tap for right-click; slide to scroll | Tap for right-click; slide to scroll; pinch for app zoom |
| Three fingers | — | Drag with the left mouse button |
| Four fingers | — | Swipe horizontally for Spaces; up for Mission Control; down for App Exposé |

Trackpad movement can reach any active Mac display. Pinch maps to Command +/− and four-finger swipes use Control + arrow shortcuts; applications and macOS shortcut settings must support them. Pressure, rotation, native continuous pinch events and all Apple trackpad gestures are not emulated. Scroll direction follows the Mac’s natural-scrolling preference.

Xiaomi system gestures can intercept input with three or more fingers before Nextend receives it. This occurs on the tested Pad 7 Ultra; one- and two-finger gestures work. Use one-finger tap-and-drag when three-finger dragging is intercepted: tap once, then promptly touch nearby again and move without lifting. Lifting ends the drag.

Ordinary Android apps cannot disable every vendor gesture per app. Xiaomi documents **Game Turbo → Game DND → Enhanced experience → Restrict screenshot gestures** for supported devices, but the user could not find this entry on the tested Pad. It does not guarantee disabling split-screen or other gestures. Nextend does not change global gesture settings. See [Xiaomi’s instructions](https://www.mi.com/global/support/faq/details/KA-673391/).

Closing the Mac window keeps streaming and removes its running-app icon from the Dock. Use **Open Nextend** in the menu bar to restore the window and Dock icon. Minimizing the window keeps the Dock icon. **Disconnect** stops the session; **Quit Nextend** also exits the app and releases the virtual display. macOS moves its windows back to the remaining displays.

If a rebuilt Mac app reports missing screen-recording permission despite an enabled switch, remove the old Nextend entry in System Settings, add the current app, and reopen it. Ad-hoc signing binds authorization to each build; a stable developer signature would be needed for production distribution. Wi-Fi also requires local-network permission. If that permission appears enabled but wireless access fails after an update, toggle the existing Nextend local-network switch off and on, then retry.

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
python3 tests/touch_protocol.py
python3 tests/connect_request.py
python3 tests/transport_switch.py
python3 tests/listener_recovery.py
```

Run display and streaming tests one at a time. Lifecycle checks create a temporary virtual display. The fallback test needs an existing local USB pairing key; protocol tests need the tablet app open and idle, and Python `cryptography`. Transport-switch and listener-recovery tests also need reachable Wi-Fi. The latter restarts the tablet app and temporarily occupies its wireless port to verify recovery.

`connect_request.py` also needs the Mac GUI running and idle, with an existing USB pairing. It tests invalid requests only; it never starts streaming or posts OS input.

```sh
outputs/Nextend.app/Contents/MacOS/Nextend --capture-test --require-hdr --seconds 30 --report outputs/hdr.json
outputs/Nextend.app/Contents/MacOS/Nextend --help
```

`--capture-test` includes desktop capture. `--benchmark` uses synthetic frames and does not validate screen capture. The FPS overlay measures rendered callbacks, not the panel's refresh rate or optical latency.

See [0.6.0 touch and connection validation](docs/RELEASE-0.6.md), [0.5.0 validation and high-refresh findings](docs/RELEASE-0.5.md), [0.4.0 validation](docs/RELEASE-0.4.md), [0.3.0 HDR measurements](docs/HDR-VALIDATION.md) and [earlier SDR measurements](docs/VALIDATION.md). Short smoke tests do not establish long-term stability. Historical measurements describe their original builds, not every subsequent release.

## Source and design

- [`macos/`](macos): AppKit, virtual-display helper, capture, Metal HDR conversion and VideoToolbox.
- [`android/`](android): Kotlin, SurfaceView, MediaCodec, gesture recognition and FPS overlay.
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md): encrypted protocol and statistics definitions.
- [`skills/liquid-glass-interface/`](skills/liquid-glass-interface): reusable design skill with native and web guidance.

Licensed under **GPL-3.0**. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md). This is an independent project, not an official OpenDisplay distribution. Use the matching Nextend apps together.
