#!/bin/bash
set -euo pipefail
sw_vers
xcrun swift --version
ADB_BIN="${ADB:-/opt/homebrew/bin/adb}"
"$ADB_BIN" devices -l
"$ADB_BIN" forward --list
printf 'Screen recording permission must be granted to Nextend in System Settings.\n'
printf 'USB mode requires an unlocked tablet, authorized USB debugging, and USB installation permission.\n'
printf 'Wireless mode requires USB pairing first, explicit Wi-Fi mode on the Pad, and VPN LAN access.\n'
