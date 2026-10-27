#!/usr/bin/env python3
"""Real macOS helper lifecycle checks. Run alone; temporarily adds one display."""
import ctypes
import os
import json
from pathlib import Path
import select
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
APP = os.environ.get("NEXTEND_TEST_APP", str(ROOT / "outputs/Nextend.app/Contents/MacOS/Nextend"))
ARGS = [APP, "--display-host", "2400", "1600", "60", "bt2020-limited-hlg10"]
CG = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")

def online():
    ids = (ctypes.c_uint32 * 64)()
    count = ctypes.c_uint32()
    assert CG.CGGetOnlineDisplayList(64, ids, ctypes.byref(count)) == 0
    return set(ids[:count.value])

def ready(process):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if not select.select([process.stdout], [], [], .2)[0]:
            continue
        line = process.stdout.readline()
        assert line, "helper exited before readiness"
        try: message = json.loads(line)
        except ValueError: continue
        assert "error" not in message, message
        if "display" in message:
            return message["display"]["id"]
    raise AssertionError("helper did not become ready")

def restored(before):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if online() == before:
            return
        time.sleep(.1)
    raise AssertionError(f"display list changed: {before} -> {online()}")

def main():
    (ROOT / "outputs/benchmarks").mkdir(parents=True, exist_ok=True)
    baseline = online()
    results = []
    for case in ["stdin-eof", "sigterm", "startup-eof"]:
        process = subprocess.Popen(ARGS, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            if case != "startup-eof":
                display_id = ready(process)
                assert online() == baseline | {display_id}
            if case == "sigterm": process.terminate()
            else: process.stdin.close()
            process.wait(timeout=5)
            restored(baseline)
            results.append({"case": case, "success": True})
        finally:
            if process.poll() is None: process.kill(); process.wait()
    # A separate parent holds the helper's stdin open. Killing that parent
    # must close the pipe and remove the display without any cleanup callback.
    parent_code = """
import json, subprocess, sys
p = subprocess.Popen(json.loads(sys.argv[1]), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
while True:
    line = p.stdout.readline()
    if not line: raise RuntimeError('helper exited')
    try: message = json.loads(line)
    except ValueError: continue
    if 'display' in message:
        print(json.dumps(message), flush=True)
        break
sys.stdin.buffer.read(1)
"""
    parent = subprocess.Popen([sys.executable, "-c", parent_code, json.dumps(ARGS)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        display_id = ready(parent)
        assert online() == baseline | {display_id}
        parent.kill(); parent.wait(timeout=3)
        restored(baseline)
        results.append({"case": "parent-sigkill", "success": True})
    finally:
        if parent.poll() is None: parent.kill(); parent.wait()
    report = {"success": True, "baselineDisplays": sorted(baseline), "finalDisplays": sorted(online()), "cases": results}
    (ROOT / "outputs/benchmarks/nextend-display-lifecycle.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS helper EOF, SIGTERM, startup EOF, parent SIGKILL; display list restored")

if __name__ == "__main__": main()
