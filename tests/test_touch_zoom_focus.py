#!/usr/bin/env python3
"""Opt-in native input test. Requires an unlocked, authorized Mac desktop.

Creates only dedicated test windows; posts mouse/zoom input to those windows.
Do not run while a user is interacting with the desktop.
"""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    children = []
    handles = []
    try:
        for name in ['A', 'B']:
            log = (args.output / (name + '.log')).open('w')
            handles.append(log)
            process = subprocess.Popen(['/usr/bin/swift', str(ROOT / 'tests/touch_zoom_fixture.swift'),
                str(args.output), name], stdout=log, stderr=subprocess.STDOUT)
            children.append(process)
            deadline = time.monotonic() + 15
            while not (args.output / (name + '.events')).exists():
                assert process.poll() is None, 'fixture failed: ' + name
                assert time.monotonic() < deadline, 'fixture did not become ready: ' + name
                time.sleep(.1)
        script = args.output / 'controller.swift'
        script.write_text('\n'.join((ROOT / name).read_text() for name in [
            'macos/TouchInput.swift', 'macos/TouchZoomTarget.swift', 'tests/touch_zoom_controller_test.swift']))
        with (args.output / 'controller.log').open('w') as log:
            result = subprocess.run(['/usr/bin/swift', str(script), str(args.output)],
                stdout=log, stderr=subprocess.STDOUT, timeout=25)
        assert result.returncode == 0, 'controller failed; inspect controller.log'
        report = json.loads((args.output / 'result.json').read_text())
        assert report['passed']
        print(json.dumps(report, indent=2))
    finally:
        # Resume only test children in case a failure happened during fault injection.
        for process in children:
            if process.poll() is None:
                process.send_signal(signal.SIGCONT)
        (args.output / 'stop').touch()
        for process in children:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=3)
        # Pair the test's synthetic DOWN even if its controller failed.
        subprocess.run(['/usr/bin/swift', '-e', 'import CoreGraphics; let e=CGEvent(mouseEventSource:nil, mouseType:.leftMouseUp, mouseCursorPosition:CGEvent(source:nil)?.location ?? .zero, mouseButton:.left); e?.post(tap:.cghidEventTap)'],
            capture_output=True, timeout=10)
        for handle in handles:
            handle.close()


if __name__ == '__main__':
    main()
