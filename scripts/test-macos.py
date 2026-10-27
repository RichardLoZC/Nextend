#!/usr/bin/env python3
"""Test the built app on native storage, preserving the running installed app."""
from pathlib import Path
import argparse
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'ops'))
from mac_bundle import copy_bundle, temporary_test_app

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--display-lifecycle', action='store_true')
    args = parser.parse_args()
    logs = ROOT/'work/reconnect-fix'; logs.mkdir(parents=True, exist_ok=True)
    with temporary_test_app('nextend-test-') as directory:
        app = copy_bundle(ROOT/'outputs/Nextend.app', Path(directory)/'Nextend.app')
        binary = app/'Contents/MacOS/Nextend'
        steps = [('mac-signature', ['codesign', '--verify', '--deep', '--strict', str(app)]),
                 ('mac-self-test', [str(binary), '--self-test']),
                 ('mac-recovery-test', [str(binary), '--recovery-self-test'])]
        if args.display_lifecycle:
            steps.append(('mac-display-lifecycle', [sys.executable, str(ROOT/'tests/display_lifecycle.py')]))
        env = os.environ.copy(); env['NEXTEND_TEST_APP'] = str(binary)
        for name, command in steps:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90, env=env)
            (logs/(name+'.log')).write_bytes(result.stdout)
            print(name + ': ' + ('PASS' if result.returncode == 0 else 'FAIL'), flush=True)
            print(result.stdout.decode(errors='replace'), flush=True)
            if result.returncode: raise SystemExit(result.returncode)

if __name__ == '__main__': main()
