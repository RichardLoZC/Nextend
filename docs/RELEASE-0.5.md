# Nextend 0.5.0

Validated on 2026-10-17 with an M4 MacBook Air, macOS 27.0.1, and Xiaomi Pad 7 Ultra, Android 16.

## Changes

- Select USB or encrypted Wi-Fi on the Mac. The foreground tablet app listens on USB loopback and its actual Wi-Fi address, with one authenticated session allowed to own the decoder. Disconnect before switching; no tablet mode control is needed.
- The authenticated USB handshake supplies the tablet's Wi-Fi address. Network changes rebuild only the Wi-Fi listener. Failed listener startup retries with a bounded delay; an obsolete retry cannot replace a newer listener.
- Codec negotiation is automatic in the interface: prefer hardware HEVC, use H.264 for SDR compatibility when HEVC is unavailable, and require HEVC Main10 for HLG HDR. A failed SDR encoder initialization can try the other advertised codec. This is capability-based selection, not a benchmark of every codec on each connection.
- The Mac language control is a direct Chinese / English button, including the menu-bar action. Switching language preserves the session.
- Transient VideoToolbox frame drops return their frame credit and request a new keyframe instead of immediately disconnecting. An encoder that produces no successful output for three seconds after a drop ends the session with a clear error, or attempts the existing HDR-to-SDR fallback.
- High-refresh profiles at 2400 × 1600 or below allow six frames in flight and an eight-surface capture pool. Native-resolution profiles retain four credits: increasing that queue raised latency without improving their throughput on this hardware. Both settings remain within the tablet's six-frame decoder accounting limit.

## Short performance measurements

These serial tests used the final Mac executable. Desktop tests ran for 12 seconds with a changing test pattern on the virtual desktop; the synthetic test ran for 10 seconds. The table averages the one-second samples after excluding the first three samples. The acknowledgement P95 is the final cumulative value. Local mirroring was stopped for these measurements.

| Transport and content | Resolution | Target | Source fps | Encoded fps | Rendered fps | Capture-to-decode acknowledgement P95 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| USB, SDR desktop capture | 2400 × 1600 | 90 | 90.00 | 88.23 | 87.79 | 65.79 ms |
| USB, SDR desktop capture | 3200 × 2136 | 90 | 89.88 | 62.88 | 62.89 | 69.43 ms |
| USB, HLG HDR desktop capture | 3200 × 2136 | 90 | 62.67 | 60.44 | 60.33 | 60.70 ms |
| Wi-Fi, HLG HDR desktop capture | 3200 × 2136 | 60 | 60.00 | 49.22 | 48.67 | 138.92 ms |
| USB, synthetic SDR input | 2400 × 1600 | 120 | 97.58 | 97.58 | 97.56 | 40.47 ms |

Both HDR tests confirmed the encoded and decoded HLG 10-bit format, plus source highlight values above SDR reference white. This validates the digital pipeline, not physical panel brightness or color accuracy. The 2400 × 1600 desktop run recorded seven decoder drops; its approximately 88 fps result is not a guarantee of uninterrupted 90 fps. Synthetic input does not validate desktop capture and did not reach its 120 fps target.

The native SDR source reached approximately 90 fps while output stayed near 63 fps. The lower-resolution desktop exceeded 60 fps through the same Mac and USB connection. This rules out a blanket 60 fps limit imposed by the Air's built-in display. The results point to processing and pipeline limits at native resolution; they are not a measurement of USB or Wi-Fi capacity. The HDR source itself was also near 60 fps in its 90 fps test. Apple's [M4 MacBook Air display specifications](https://support.apple.com/en-us/122212) independently list external-display modes above 60 Hz.

For this tested combination, use **3200 × 2136 at 60 fps** for clarity or HDR, or **2400 × 1600 at 90 fps** for smoother SDR motion. Static desktop content can produce few or no new frames even while the connection is healthy.

## H.264 and HDR limits

The diagnostic H.264 / SDR / native-resolution / 90 fps test produced zero encoded frames: VideoToolbox dropped every submitted frame. The new bounded failure path reported the problem and cleaned up; this release does not claim to make that hardware configuration work. The interface automatically chose HEVC successfully on the tested devices. Explicit codec selection remains available only through `--codec auto|hevc|h264` for diagnostics.

Nextend's H.264 path is SDR-only. HDR selects HEVC Main10 and HLG; an explicit H.264 + HDR request is rejected before starting. HEVC generally compresses more efficiently than H.264 at comparable visual quality, but compatibility and hardware cost vary, so it is a preferred default rather than a universal fastest option. See Apple's [HEVC overview](https://support.apple.com/116944) and [HEVC HDR guidance](https://developer.apple.com/videos/play/wwdc2020/10010/).

## Checks completed

- Mac build and self-tests, including automatic codec negotiation, HDR constraints, the four/six-credit bound, dropped-frame recovery deadlines, crypto integrity, role separation, localization and Metal HLG reference values.
- Android build and fifteen unit tests, including concurrent decoder admission and stale-owner release.
- Eight Android protocol integration groups, including rejected unsupported codecs, invalid HDR combinations, authentication failures, replay rejection, input rejection and the total handshake deadline.
- USB → Wi-Fi → USB without tablet interaction. Authenticated competing connections receive an encrypted busy response; unauthenticated or slow peers cannot take over the active decoder.
- Same-address Wi-Fi listener recovery after a temporary port conflict, while an active USB session keeps responding.
- Four display-helper lifecycle cases: EOF, SIGTERM, startup EOF and parent SIGKILL. Each restored the original online-display list.
- Authenticated runtime HDR rejection followed immediately by EOF: one clean SDR reconnect and final cleanup.
- Final standalone Mac GUI: USB connection, language switching during the same session, encrypted Wi-Fi with confirmed HLG output, and switching back to USB, all without selecting a mode on the tablet. The waiting page has no transport selector; streaming hides connection diagnostics outside its tap menu.

The last Android edit only invalidated stale listener-retry timers. Android build, all fifteen unit tests, protocol, transport switching and listener recovery passed after that edit. Performance measurements preceded it; the final GUI checks used both final installed apps. All display and streaming tests ran serially. These short tests do not establish long-term stability or performance across other devices, content and networks.

Mac builds remain ad-hoc signed and not notarized. Existing screen-recording and local-network authorizations were refreshed through macOS settings before the standalone GUI checks; their scope was unchanged. If wireless access stops working after an update despite an enabled local-network switch, toggle that existing Nextend permission off and on, then retry. Install the app in Applications before launching. Android remains debuggable for the current USB pairing method. Pairing keys, private logs, signing identities and build caches are excluded from published source and packages.
