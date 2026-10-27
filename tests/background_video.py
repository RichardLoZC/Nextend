#!/usr/bin/env python3
"""Exercise real encoding/decoding across app switches; run alone with an idle Pad.

Uses the installed Mac app. Default source is synthetic; --desktop captures the
real extended desktop, and --hdr requires HLG. No Mac input is injected.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

from device_protocol import ADB
from display_lifecycle import online, restored


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--desktop', action='store_true')
    parser.add_argument('--hdr', action='store_true')
    parser.add_argument('--app', default=str(Path.home() / 'Applications/Nextend.app/Contents/MacOS/Nextend'))
    parser.add_argument('--report', required=True)
    args = parser.parse_args()
    output = Path(args.report).resolve(); output.parent.mkdir(parents=True, exist_ok=True)
    report = output.with_suffix('.video.json'); log = output.with_suffix('.log')
    devices = subprocess.check_output([ADB, 'devices', '-l'], text=True)
    serials = [line.split()[0] for line in devices.splitlines() if ' device ' in line and 'usb:' in line]
    assert len(serials) == 1, 'Connect exactly one USB Pad'
    adb = [ADB, '-s', serials[0]]
    def shell(*values):
        subprocess.run(adb + ['shell', *values], check=True, stdout=subprocess.DEVNULL)
    def show():
        shell('am', 'start', '-n', 'dev.padbridge/.MainActivity')
    show(); time.sleep(1)
    baseline = online(); events = []
    command = [args.app, '--connect' if args.desktop else '--benchmark', '--width', '2400', '--height', '1600',
               '--fps', '60', '--seconds', '52', '--report', str(report)]
    if args.hdr: command.append('--require-hdr')
    with log.open('w') as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 35
            while time.monotonic() < deadline:
                assert process.poll() is None, f'Mac exited during preparation; inspect {log}'
                if '队列 ' in log.read_text(): break
                time.sleep(.2)
            else: raise AssertionError(f'No active video; inspect {log}')
            display_ids = online() - baseline
            assert len(display_ids) == 1, display_ids
            started = time.monotonic()
            def hold(seconds):
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    assert process.poll() is None, f'Mac stopped during switching; inspect {log}'
                    assert online() == baseline | display_ids, 'virtual display was removed or replaced'
                    time.sleep(.1)
            def event(name):
                events.append(dict(name=name, seconds=round(time.monotonic() - started, 2), displays=sorted(online())))
            hold(4)
            shell('input', 'keyevent', 'KEYCODE_HOME'); event('home'); hold(7)
            show(); event('return-home'); hold(6)
            shell('am', 'start', '-a', 'android.settings.SETTINGS'); event('settings'); hold(7)
            show(); event('return-settings'); hold(6)
            for _ in range(3):
                shell('input', 'keyevent', 'KEYCODE_HOME'); hold(.25)
                show(); hold(.65)
            event('rapid-switches-complete')
            process.wait(timeout=25)
            assert process.returncode == 0, log.read_text()[-1800:]
            data = json.loads(report.read_text())
            assert data['success'] is True, data['reason']
            if args.hdr: assert data['hdrVerified'] is True
            rows = data['samples']
            hidden = [r for r in rows if r.get('viewerVisible') is False and r['encodeFps'] < 1 and r['pending'] == 0]
            assert len(hidden) >= 6, 'encoding did not pause in the background'
            # Every hidden interval must be followed by real decoder output, including static sources.
            recoveries = 0
            for i in range(1, len(rows)):
                if rows[i-1].get('viewerVisible') is False and rows[i].get('viewerVisible') is True:
                    before = rows[i-1].get('decoded', 0)
                    assert any(r.get('decoded', 0) > before for r in rows[i:i+5]), 'no frame decoded after returning'
                    recoveries += 1
            assert recoveries >= 2, 'missing app-switch recovery samples'
            assert rows[-1].get('viewerVisible') is True
            restored(baseline)
            evidence = dict(success=True, mode=data['test'], color=data['color'], displayIDs=sorted(display_ids),
                            baselineDisplays=sorted(baseline), finalDisplays=sorted(online()),
                            pausedSamples=len(hidden), recoveredIntervals=recoveries, events=events,
                            videoReport=report.name)
            output.write_text(json.dumps(evidence, indent=2) + '\n')
            print(f'PASS {data["color"]}: same virtual display across Home, Settings, and three rapid switches; {recoveries} frame recoveries; clean teardown')
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=15)
            show()


if __name__ == '__main__':
    main()
