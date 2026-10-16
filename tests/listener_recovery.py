#!/usr/bin/env python3
"""Hold the Pad's Wi-Fi port briefly, then verify same-address listener retry.

Restarts only the development app; no desktop is sent and pairing is retained.
Uses Android's built-in toybox timeout/nc. Run with no active display session.
"""
import os
import socket
import subprocess
import time
from device_protocol import ADB, Client
from transport_switch import ready, ping

def main():
    devices = subprocess.check_output([ADB, "devices", "-l"], text=True)
    serials = [line.split()[0] for line in devices.splitlines() if " device " in line and "usb:" in line]
    assert len(serials) == 1
    prefix = [ADB, "-s", serials[0]]
    key = subprocess.check_output(prefix + ["exec-out", "run-as", "dev.padbridge", "cat", "files/pairing.key"])
    port = int(subprocess.check_output(prefix + ["forward", "tcp:0", "tcp:49371"]))
    blocker = None
    def usb(): return socket.create_connection(("127.0.0.1", port), timeout=7)
    def usb_client():
        # am start/install completes before the Activity's Surface is ready.
        for attempt in range(30):
            sock = None
            try:
                sock = usb()
                return sock, Client(sock, key)
            except (EOFError, OSError):
                if sock: sock.close()
                if attempt == 29: raise
                time.sleep(0.1)
    def wifi():
        sock = socket.socket(); sock.settimeout(7)
        sock.setsockopt(socket.IPPROTO_IP, 25, socket.if_nametoindex(os.environ.get("MAC_WIFI_INTERFACE", "en0")))
        try: sock.connect((address, 49371)); return sock
        except Exception: sock.close(); raise
    try:
        sock, initial = usb_client()
        with sock: address = initial.hello.get("wifiAddress")
        assert address, "No Wi-Fi address"
        subprocess.run(prefix + ["shell", "am", "force-stop", "dev.padbridge"], check=True)
        blocker = subprocess.Popen(prefix + ["shell", "toybox", "timeout", "6", "toybox", "nc", "-l", "-s", address, "-p", "49371"],
                                   stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        time.sleep(0.3)
        assert blocker.poll() is None, "Could not establish temporary port conflict"
        subprocess.run(prefix + ["shell", "am", "start", "-n", "dev.padbridge/.MainActivity"], stdout=subprocess.DEVNULL, check=True)
        sock, current = usb_client()
        with sock:
            ready(current)
            for _ in range(8):
                time.sleep(1); ping(current)
            assert blocker.poll() is not None, "Temporary conflict did not expire"
            with wifi() as other: Client(other, key, expected="busy")
            ping(current)
        time.sleep(0.3)
        with wifi() as sock:
            current = Client(sock, key); ready(current); ping(current)
        print("PASS Wi-Fi binding recovers on the same address after a temporary port conflict; USB stays active")
    finally:
        if blocker:
            if blocker.poll() is None: blocker.wait(timeout=7)
            if blocker.stdin: blocker.stdin.close()
            if blocker.stderr: blocker.stderr.close()
        subprocess.run(prefix + ["forward", "--remove", f"tcp:{port}"], check=True)

if __name__ == "__main__": main()
