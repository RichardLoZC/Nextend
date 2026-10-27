#!/usr/bin/env python3
"""Verify one authenticated session survives Home and another app.

Requires the installed test build and an idle Pad. Sends no desktop or Mac input.
Restores the prior remote settings and returns the Pad to Nextend in finally.
"""
import json
import socket
import subprocess
import time
import xml.etree.ElementTree as ET
from device_protocol import ADB, Client


def main():
    devices = subprocess.check_output([ADB, 'devices', '-l'], text=True)
    serials = [line.split()[0] for line in devices.splitlines() if ' device ' in line and 'usb:' in line]
    assert len(serials) == 1, 'Connect one USB Pad'
    adb = [ADB, '-s', serials[0]]
    def shell(*args):
        return subprocess.check_output(adb + ['shell', *args], text=True)
    def show():
        shell('am', 'start', '-n', 'dev.padbridge/.MainActivity')
    key = subprocess.check_output(adb + ['exec-out', 'run-as', 'dev.padbridge', 'cat', 'files/pairing.key'])
    assert len(key) == 32
    pref = subprocess.run(adb + ['exec-out', 'run-as', 'dev.padbridge', 'cat', 'shared_prefs/settings.xml'], capture_output=True, text=True)
    previous = None
    if pref.returncode == 0:
        entry = ET.fromstring(pref.stdout).find("./string[@name='remote.settings']")
        if entry is not None:
            previous = json.loads(entry.text)
    port = int(subprocess.check_output(adb + ['forward', 'tcp:0', 'tcp:49371']))
    defaults = dict(type='pad-settings', language='zh', showFPS=False, size=20, font=1, color='#FFFFFF', x=.03, y=.03,
                    safeArea=dict(enabled=False, top=.03, right=0, bottom=0, left=0))
    try:
        show()
        with socket.create_connection(('127.0.0.1', port), timeout=7) as sock:
            c = Client(sock, key)
            probe = dict(type='probe', version=1, width=2400, height=1600, fps=60)
            c.send(probe); caps = c.read(); assert 'hevc' in caps['codecs']
            c.send(dict(probe, type='config', codec='hevc', color='bt709-limited-sdr', bitDepth=8, input=False, controlsVersion=1))
            assert c.read()['type'] == 'ready'
            last_ping = 0
            def receive():
                nonlocal last_ping
                now = time.monotonic()
                if now - last_ping >= 1:
                    c.send(dict(type='ping')); last_ping = now
                value = c.read()
                assert value['type'] in ('stats', 'pong', 'keyframe'), value
                return value
            def visible(expected, seconds=8):
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    value = receive()
                    if value['type'] == 'stats' and value.get('viewerVisible') is expected:
                        return value
                raise AssertionError(f'viewerVisible never became {expected}')
            def hold(seconds):
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    receive()
            try:
                visible(True)
                for _ in range(3):
                    shell('input', 'keyevent', 'KEYCODE_HOME'); visible(False); hold(7)
                    show(); visible(True)
                print('PASS same authenticated socket survives three Home/return cycles beyond the old timeout')
                shell('am', 'start', '-a', 'android.settings.SETTINGS'); visible(False); hold(7)
                show(); visible(True)
                print('PASS another foreground app does not release the display session')
                settings = dict(previous or defaults)
                settings['safeArea'] = dict(enabled=True, top=.08, right=.04, bottom=.02, left=.03)
                c.send(settings); hold(2)
                saved = shell('run-as', 'dev.padbridge', 'cat', 'shared_prefs/settings.xml')
                value = json.loads(ET.fromstring(saved).find("./string[@name='remote.settings']").text)
                assert value['safeArea'] == settings['safeArea']
                legacy = dict(settings); del legacy['safeArea']
                c.send(legacy); hold(2)
                saved = shell('run-as', 'dev.padbridge', 'cat', 'shared_prefs/settings.xml')
                value = json.loads(ET.fromstring(saved).find("./string[@name='remote.settings']").text)
                assert value['safeArea'] == settings['safeArea'], 'legacy settings discarded calibration'
                shell('input', 'keyevent', 'KEYCODE_HOME'); visible(False)
                show(); visible(True)
                print('PASS safe margins persist across background/foreground while the session stays connected')
                print('PASS legacy settings preserve saved safe-area calibration')
            finally:
                show()
                c.send(previous or defaults); c.send(dict(type='stop'))
        print('PASS explicit stop releases the session')
    finally:
        subprocess.run(adb + ['forward', '--remove', f'tcp:{port}'], check=True)
        show()


if __name__ == '__main__':
    main()
