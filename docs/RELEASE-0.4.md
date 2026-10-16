# Nextend 0.4.0

Validated on 2026-10-17 with an M4 MacBook Air, macOS 27.0.1, and Xiaomi Pad 7 Ultra, Android 16.

## Changes

- Closing the Mac window keeps streaming. The Dock and menu bar reopen the same window and session; Quit performs cleanup.
- The tablet shows connection diagnostics inside its tap menu. An optional rendered-FPS overlay supports position, color, font and size preferences.
- Chinese and English can be selected independently on each device. Language changes preserve the active session.
- Decorative captions were removed from both interfaces.
- The source includes build scripts, protocol documentation, tests, branding and the reusable liquid glass design skill.

## Checks completed

- Native Mac build and self-tests: encryption integrity, replay rejection, role separation, stream profiles, Metal HLG reference values, translation catalog, nested messages, serialization and oversized placeholder handling.
- Android build and thirteen unit tests: encrypted framing, color profiles, normalized overlay positions, and tap/drag transitions. Cases cover resize, invalid stored values, returning to the initial touch point, release without move events, and bottom-edge placement.
- Four real display-helper lifecycle cases: stdin EOF, SIGTERM, startup EOF and parent SIGKILL. Each restored the original online-display list.
- Authenticated runtime HDR rejection followed immediately by EOF: one clean SDR reconnect and final cleanup.
- Eight Android protocol integration groups, including malformed or unsupported configuration and capability negotiation.
- Final Mac GUI connected through USB with HLG 10-bit HDR. Closing its window kept the same app, helper and USB forwarding session alive. Reopening restored the connected window. Switching to English retained that session. Explicit Quit removed the app, helper and forwarding rule; the tablet returned to its waiting page.
- Tablet controls were inspected on the physical device through a local mirror, including menu visibility, English layout, font selection and the light style dialog.
- A user-reported disappearance during FPS dragging was addressed by drawing the badge in a stationary overlay and retaining its text during each gesture. The user then confirmed that dragging stayed visible and that size and custom-color controls worked on the physical tablet. Existing preferences survived APK updates.

Display lifecycle and HDR fallback tests were repeated after the final helper-message serialization change. Android build and all thirteen unit tests were repeated after the final overlay changes. Automated display tests run serially.

## HDR smoke measurement

A 15-second USB capture test during 0.4.0 development confirmed HDR metadata, decoder output and real source highlights. Excluding the first three samples, mean encoding was 60.00 fps and mean rendered callbacks were 59.83 fps. The final decode-acknowledgement RTT P95 was 58.20 ms.

That measurement preceded the last localization and tablet style fixes. It is a pipeline regression check, not a benchmark of every byte in the release binaries. The final GUI session confirmed connection and HDR output again; it did not repeat photometric source measurements. Local mirror overhead makes the GUI check unsuitable for frame-rate benchmarking.

## Limits

This release uses short regression and interaction checks. The earlier half-hour SDR run and 0.3.0 wireless HDR results remain historical evidence; they were not repeated for 0.4.0. Static desktop content can produce fewer frames than the selected target.

The FPS overlay counts MediaCodec rendered callbacks. It does not measure optical display latency or panel brightness. Physical color accuracy, all supported devices, and all accessibility configurations remain outside this validation.

Mac builds are ad-hoc signed and not notarized. Install the app into Applications before launching; running it from Documents can leave VideoToolbox waiting for protected-folder access. Android builds are debuggable for the current USB pairing workflow. Pairing keys, signing identities, private logs and build caches are excluded from the public repository and source archive.
