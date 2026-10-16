#!/usr/bin/env python3
"""Authenticated loopback receiver: reject a live HDR frame, then accept SDR.

Uses this Mac's existing pairing key without printing it. No Pad traffic or
desktop capture; the sender runs its synthetic test against 127.0.0.1 only.
"""
import hmac
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import threading
import time

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from device_protocol import exact, raw_send, CONTEXT

ROOT = Path(__file__).resolve().parent.parent
KEY = (Path.home() / "Library/Application Support/PadBridge/pairing.key").read_bytes()
assert len(KEY) == 32

def raw_read(sock):
    length, = struct.unpack(">I", exact(sock, 4))
    assert 0 < length <= 16 * 1024 * 1024
    return exact(sock, length)

class Peer:
    def __init__(self, sock):
        self.sock = sock
        initial = raw_read(sock)
        assert len(initial) == 36 and initial[:4] == b"PDB1"
        nonce = os.urandom(32)
        salt = initial[4:] + nonce
        raw_send(sock, nonce + hmac.digest(KEY, CONTEXT + b"pad" + salt, "sha256"))
        assert hmac.compare_digest(raw_read(sock), hmac.digest(KEY, CONTEXT + b"mac" + salt, "sha256"))
        prk = hmac.digest(salt, KEY, "sha256")
        self.tx = AESGCM(hmac.digest(prk, CONTEXT + b"pad-to-mac\x01", "sha256"))
        self.rx = AESGCM(hmac.digest(prk, CONTEXT + b"mac-to-pad\x01", "sha256"))
        self.sent = self.received = 0
    def send(self, value):
        aad = struct.pack(">Q", self.sent)
        raw_send(self.sock, aad + self.tx.encrypt(b"\0" * 4 + aad, b"\1" + json.dumps(value).encode(), aad))
        self.sent += 1
    def read(self):
        packet = raw_read(self.sock)
        aad = struct.pack(">Q", self.received)
        assert packet[:8] == aad
        result = self.rx.decrypt(b"\0" * 4 + aad, packet[8:], aad)
        self.received += 1
        return result

def main():
    (ROOT / "outputs/benchmarks").mkdir(parents=True, exist_ok=True)
    (ROOT / "work/test-results").mkdir(parents=True, exist_ok=True)
    colors = []
    failures = []
    with socket.socket() as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 49371)); server.listen(1); server.settimeout(20)
        def run():
            try:
                for attempt in range(2):
                    client, _ = server.accept()
                    with client:
                        client.settimeout(10)
                        p = Peer(client)
                        p.send(dict(type="hello", version=1, input=False))
                        body = p.read(); assert body[0] == 1
                        probe = json.loads(body[1:]); assert probe["type"] == "probe"
                        p.send(dict(type="capabilities", codecs=["hevc", "h264"], colors=["bt709-limited-sdr", "bt2020-limited-hlg10"]))
                        config = json.loads(p.read()[1:]); colors.append(config["color"])
                        p.send(dict(type="ready", decoder="test-receiver", color=config["color"], bitDepth=config["bitDepth"]))
                        while True:
                            try: body = p.read()
                            except EOFError: break
                            if body[0] == 1:
                                message = json.loads(body[1:])
                                if message["type"] == "ping": p.send(dict(type="pong"))
                                elif message["type"] == "stop": break
                            elif body[0] == 2:
                                if attempt == 0:
                                    p.send(dict(type="hdr-error", message="injected output-format mismatch"))
                                    # EOF immediately follows the rejection; exercises ordering.
                                    client.shutdown(socket.SHUT_RDWR)
                                    break
                                seq, = struct.unpack(">Q", body[1:9])
                                p.send(dict(type="ack", seq=seq, decoded=True, receiveToDecodeMs=1))
            except Exception as error:
                failures.append(repr(error))
        worker = threading.Thread(target=run); worker.start()
        report = ROOT / "outputs/benchmarks/nextend-hdr-runtime-fallback.json"
        log = ROOT / "work/test-results/hdr-runtime-fallback.log"
        with log.open("w") as out:
            process = subprocess.run([str(ROOT / "outputs/Nextend.app/Contents/MacOS/Nextend"), "--benchmark", "--hdr", "--width", "2400", "--height", "1600", "--seconds", "3", "--host", "127.0.0.1", "--interface", "lo0", "--report", str(report)], stdout=out, stderr=subprocess.STDOUT, timeout=35)
        worker.join(2)
        assert not worker.is_alive() and not failures, failures
        assert process.returncode == 0, log.read_text()
        assert colors == ["bt2020-limited-hlg10", "bt709-limited-sdr"], colors
        result = json.loads(report.read_text())
        assert result["success"] and result["requestedHDR"] and result["color"] == "bt709-limited-sdr"
        assert "injected" in result["fallbackReason"], result
        print("PASS authenticated hdr-error + immediate EOF → clean SDR reconnect")

if __name__ == "__main__":
    main()
