#!/usr/bin/env python3
"""Adversarial integration tests against the installed Pad app; no desktop is sent.

Requires the Pad app in the foreground, idle, and Python's cryptography package.
Every test forward is removed in finally. Pairing material is never printed.
"""
import hashlib
import hmac
import json
import os
import socket
import struct
import subprocess
import threading
import time
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ADB = os.environ.get("ADB", "/opt/homebrew/bin/adb")
CONTEXT = b"PadBridge/v1/"

def raw_send(sock, body):
    sock.sendall(struct.pack(">I", len(body)) + body)

def exact(sock, size):
    result = b""
    while len(result) < size:
        part = sock.recv(size - len(result))
        if not part:
            raise EOFError("peer closed")
        result += part
    return result

def raw_read(sock):
    length, = struct.unpack(">I", exact(sock, 4))
    assert 0 < length <= 65536
    return exact(sock, length)

class Client:
    def __init__(self, sock, key, expected="hello"):
        self.sock = sock
        nonce = os.urandom(32)
        raw_send(sock, b"PDB1" + nonce)
        reply = raw_read(sock)
        assert len(reply) == 64
        salt = nonce + reply[:32]
        assert hmac.compare_digest(reply[32:], hmac.digest(key, CONTEXT + b"pad" + salt, "sha256"))
        raw_send(sock, hmac.digest(key, CONTEXT + b"mac" + salt, "sha256"))
        prk = hmac.digest(salt, key, "sha256")
        self.tx = AESGCM(hmac.digest(prk, CONTEXT + b"mac-to-pad\x01", "sha256"))
        self.rx = AESGCM(hmac.digest(prk, CONTEXT + b"pad-to-mac\x01", "sha256"))
        self.sent = self.received = 0
        self.hello = self.read()
        assert self.hello["type"] == expected, self.hello

    def packet(self, value):
        aad = struct.pack(">Q", self.sent)
        payload = b"\x01" + json.dumps(value).encode()
        return aad + self.tx.encrypt(b"\0" * 4 + aad, payload, aad)

    def send(self, value):
        packet = self.packet(value)
        raw_send(self.sock, packet)
        self.sent += 1
        return packet

    def read(self):
        packet = raw_read(self.sock)
        aad = struct.pack(">Q", self.received)
        assert packet[:8] == aad
        body = self.rx.decrypt(b"\0" * 4 + aad, packet[8:], aad)
        self.received += 1
        assert body[0] == 1
        return json.loads(body[1:])

    def rejected(self):
        try:
            assert self.read()["type"] in ("error", "hdr-error")
        except EOFError:
            return
        assert self.sock.recv(1) == b""

def main():
    devices = subprocess.check_output([ADB, "devices", "-l"], text=True)
    serials = [line.split()[0] for line in devices.splitlines() if " device " in line and "usb:" in line]
    assert len(serials) == 1, "Connect exactly one authorized USB Pad"
    serial = serials[0]
    prefix = [ADB, "-s", serial]
    key = subprocess.check_output(prefix + ["exec-out", "run-as", "dev.padbridge", "cat", "files/pairing.key"])
    assert len(key) == 32
    port = int(subprocess.check_output(prefix + ["forward", "tcp:0", "tcp:49371"]))
    def connect():
        return socket.create_connection(("127.0.0.1", port), timeout=7)
    probe = {"type": "probe", "version": 1, "width": 3200, "height": 2136, "fps": 60}
    try:
        with connect() as s:
            s.sendall(struct.pack(">I", 0x7fffffff))
            assert s.recv(1) == b""
        print("PASS oversized unauthenticated packet rejected")
        with connect() as s:
            raw_send(s, b"PDB1" + os.urandom(32)); raw_read(s)
            raw_send(s, bytes(32)); assert s.recv(1) == b""
        print("PASS incorrect authentication proof rejected")
        with connect() as s:
            c = Client(s, key)
            first = c.send(probe); assert c.read()["codecs"]
            raw_send(s, first); c.rejected()
        print("PASS replay rejected")
        with connect() as s:
            c = Client(s, key)
            packet = bytearray(c.packet(probe)); packet[-1] ^= 1
            raw_send(s, packet); c.rejected()
        print("PASS altered authentication tag rejected")
        with connect() as s:
            c = Client(s, key); c.send(probe); caps = c.read()
            c.send(dict(probe, type="config", codec=caps["codecs"][0], color="bt709-limited-sdr", input=False))
            assert c.read()["type"] == "ready"
            c.send({"type": "touch", "x": 0.5, "y": 0.5}); c.rejected()
        print("PASS input injection message rejected")
        for color, codec, depth in [("unknown-hdr", "hevc", 10), ("bt2020-limited-hlg10", "h264", 10), ("bt2020-limited-hlg10", "hevc", 8), ("bt709-limited-sdr", "hevc", 10), ("bt709-limited-sdr", "unknown", 8)]:
            with connect() as s:
                c = Client(s, key); c.send(probe); c.read()
                c.send(dict(probe, type="config", codec=codec, color=color, bitDepth=depth, input=False))
                c.rejected()
        print("PASS invalid HDR codec/color/bit-depth combinations rejected")
        with connect() as s:
            c = Client(s, key); c.send(probe); caps = c.read()
            c.send(dict(probe, type="config", codec=caps["codecs"][0], color="bt709-limited-sdr", input=False))
            assert c.read()["type"] == "ready"
            for _ in range(2):
                stats = c.read()
                assert stats["type"] == "stats", "new message breaks legacy Mac"
                assert "videoFormat" in stats
            c.send({"type": "stop"})
        print("PASS legacy SDR client receives only compatible message types")
        with connect() as s:
            start = time.monotonic(); s.sendall(struct.pack(">I", 36))
            def trickle():
                try:
                    for _ in range(20):
                        s.sendall(b"P"); time.sleep(0.4)
                except OSError:
                    pass
            worker = threading.Thread(target=trickle, daemon=True); worker.start()
            assert s.recv(1) == b""
            elapsed = time.monotonic() - start
            assert 4.5 <= elapsed < 6.5, elapsed
        print("PASS total handshake deadline defeats slow byte trickle")
    finally:
        subprocess.run(prefix + ["forward", "--remove", f"tcp:{port}"], check=True)

if __name__ == "__main__":
    main()
