#!/usr/bin/env python3
"""Verify real Pad MotionEvents -> encrypted touch packets without Mac input.

Requires an idle foreground Nextend Pad and the shell-only NextendTouchInput.jar
fixture at /data/local/tmp/nextend-touch-input.jar. Never run during a user's
active display session. Pairing keys and touch coordinates are not exported.
"""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import time
from device_protocol import ADB, Client


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--width', type=int, default=3200)
    parser.add_argument('--height', type=int, default=2136)
    args = parser.parse_args()
    devices = subprocess.check_output([ADB, 'devices', '-l'], text=True)
    serials = [line.split()[0] for line in devices.splitlines() if ' device ' in line and 'usb:' in line]
    assert len(serials) == 1, 'Connect exactly one authorized USB Pad'
    prefix = [ADB, '-s', serials[0]]
    key = subprocess.check_output(prefix + ['exec-out', 'run-as', 'dev.padbridge', 'cat', 'files/pairing.key'])
    port = int(subprocess.check_output(prefix + ['forward', 'tcp:0', 'tcp:49371']))
    results = []
    try:
        for mode in ['direct', 'trackpad']:
            for pattern in ['scroll', 'pinch-in', 'pinch-out', 'rightclick', 'final-pinch', 'cancel']:
                sock = socket.create_connection(('127.0.0.1', port), timeout=7)
                with sock:
                    c = Client(sock, key)
                    probe = dict(type='probe', version=1, width=args.width, height=args.height, fps=60)
                    c.send(probe); caps = c.read()
                    c.send(dict(probe, type='config', codec=caps['codecs'][0], color='bt709-limited-sdr',
                                bitDepth=8, input=False, touchVersion=1))
                    assert c.read()['type'] == 'ready'
                    c.send(dict(type='touch-mode', epoch=1, enabled=True, mode=mode))
                    while c.read()['type'] != 'touch-state':
                        pass
                    time.sleep(.25)
                    subprocess.run(prefix + ['shell', 'CLASSPATH=/data/local/tmp/nextend-touch-input.jar',
                        'app_process', '/', 'NextendTouchInput', pattern, str(args.width), str(args.height)],
                        check=True, capture_output=True, timeout=8)
                    packets = []
                    # end/cancel uses the same ordered sender as every command;
                    # a pong on the control writer would not be a reliable fence.
                    terminal = 'cancel' if pattern == 'cancel' else 'end'
                    while True:
                        row = c.read()
                        if row['type'] == 'touch':
                            packets.append(row)
                            if row['phase'] == terminal:
                                break
                    phases = [row['phase'] for row in packets]
                    assert phases and phases[0] == 'begin', phases
                    if pattern == 'scroll':
                        scrolls = [r for r in packets if r['phase'] == 'scroll']
                        assert scrolls and all(abs(r['x'] - .5) < .002 and abs(r['y'] - .4) < .002 for r in scrolls)
                        assert sum(r['dy'] for r in scrolls) > .10
                        assert not any(p in phases for p in ['click', 'rightclick', 'zoom-in', 'zoom-out', 'down'])
                    elif pattern in ['pinch-in', 'pinch-out', 'final-pinch']:
                        expected = 'zoom-out' if pattern == 'pinch-out' else 'zoom-in'
                        assert expected in phases, phases
                        assert not any(p in phases for p in ['scroll', 'click', 'rightclick', 'down'])
                    elif pattern == 'rightclick':
                        assert phases == ['begin', 'rightclick', 'end'], phases
                    else:
                        assert 'scroll' in phases and phases[-1] == 'cancel', phases
                        assert not any(p in phases for p in ['click', 'rightclick', 'down'])
                    c.send(dict(type='stop'))
                    results.append(dict(mode=mode, pattern=pattern, phases=phases, passed=True))
                    print('PASS', mode, pattern, flush=True)
                time.sleep(.2)
    finally:
        subprocess.run(prefix + ['forward', '--remove', f'tcp:{port}'], check=True)
        args.output.write_text(json.dumps(dict(cases=results, passed=len(results) == 12), indent=2) + '\n')


if __name__ == '__main__':
    main()
