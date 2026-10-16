#!/usr/bin/env python3
"""Verify USB/Wi-Fi admission and switching with no desktop or Pad UI input.

Run serially with other device tests. The app must be open and idle. The Pad
must share a reachable Wi-Fi network; MAC_WIFI_INTERFACE defaults to en0.
No pairing key or device address is printed.
"""
import os
import socket
import struct
import subprocess
import time
from device_protocol import ADB, Client, raw_send, raw_read

PROBE = dict(type="probe", version=1, width=2400, height=1600, fps=60)

def ready(client):
    client.send(PROBE)
    capabilities = client.read()
    assert "hevc" in capabilities["codecs"]
    client.send(dict(PROBE, type="config", codec="hevc", color="bt709-limited-sdr", bitDepth=8, input=False))
    assert client.read()["type"] == "ready"

def ping(client):
    client.send(dict(type="ping"))
    for _ in range(8):
        message = client.read()
        if message["type"] == "pong": return
        assert message["type"] == "stats", message
    raise AssertionError("No pong from active session")

def main():
    devices = subprocess.check_output([ADB, "devices", "-l"], text=True)
    serials = [s.split()[0] for s in devices.splitlines() if " device " in s and "usb:" in s]
    assert len(serials) == 1, "Connect exactly one authorized USB Pad"
    prefix = [ADB, "-s", serials[0]]
    key = subprocess.check_output(prefix + ["exec-out", "run-as", "dev.padbridge", "cat", "files/pairing.key"])
    assert len(key) == 32
    port = int(subprocess.check_output(prefix + ["forward", "tcp:0", "tcp:49371"]))
    def usb(): return socket.create_connection(("127.0.0.1", port), timeout=7)
    def wifi():
        sock = socket.socket(); sock.settimeout(7)
        # macOS IP_BOUND_IF, matching the app's explicit physical-interface route.
        sock.setsockopt(socket.IPPROTO_IP, 25, socket.if_nametoindex(os.environ.get("MAC_WIFI_INTERFACE", "en0")))
        try: sock.connect((address, 49371)); return sock
        except Exception: sock.close(); raise
    try:
        with usb() as sock:
            current = Client(sock, key); address = current.hello.get("wifiAddress")
            assert address, "Pad has no Wi-Fi listener address"
            ready(current)
            with wifi() as other:
                Client(other, key, expected="busy")
                assert other.recv(1) == b""
            ping(current)
        print("PASS authenticated Wi-Fi cannot steal an active USB decoder")
        time.sleep(0.3)
        with wifi() as sock:
            current = Client(sock, key); ready(current)
            with usb() as other:
                Client(other, key, expected="busy")
            with usb() as invalid:
                raw_send(invalid, b"PDB1" + os.urandom(32)); raw_read(invalid)
                raw_send(invalid, bytes(32)); assert invalid.recv(1) == b""
            ping(current)
        print("PASS USB → Wi-Fi without Pad mode selection; competing USB/auth failures leave Wi-Fi active")
        time.sleep(0.3)
        with wifi() as unauthenticated:
            unauthenticated.sendall(struct.pack(">I", 36))
            with usb() as sock:
                current = Client(sock, key); ready(current); ping(current)
        print("PASS Wi-Fi → USB without Pad mode selection; incomplete Wi-Fi authentication does not block USB")
    finally:
        subprocess.run(prefix + ["forward", "--remove", f"tcp:{port}"], check=True)

if __name__ == "__main__": main()
