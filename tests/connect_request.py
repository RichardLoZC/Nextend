#!/usr/bin/env python3
"""Negative request-channel tests against an idle running Mac GUI.

Never sends a valid Connect command, changes settings, or posts OS input.
Pairing material stays in process memory. Port is the GUI's request listener.
"""
import argparse
import hmac
import json
import os
import socket
import struct
from pathlib import Path
from device_protocol import CONTEXT, exact, raw_read, raw_send
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def rejected(sock):
    assert sock.recv(1) == b"", "request should be rejected"


def authenticate(sock, key):
    nonce = os.urandom(32)
    raw_send(sock, b"PDR1" + nonce)
    reply = raw_read(sock)
    assert len(reply) == 64
    salt = nonce + reply[:32]
    assert hmac.compare_digest(reply[32:], hmac.digest(key, CONTEXT + b"request-mac" + salt, "sha256"))
    proof = hmac.digest(key, CONTEXT + b"request-pad" + salt, "sha256")
    raw_send(sock, proof)
    prk = hmac.digest(salt, key, "sha256")
    return (AESGCM(hmac.digest(prk, CONTEXT + b"request-pad-to-mac\x01", "sha256")),
            AESGCM(hmac.digest(prk, CONTEXT + b"request-mac-to-pad\x01", "sha256")), proof)


def packet(cipher, value, sequence=0):
    aad = struct.pack(">Q", sequence)
    body = b"\x01" + json.dumps(value).encode()
    return aad + cipher.encrypt(b"\0" * 4 + aad, body, aad)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    key = (Path.home() / "Library/Application Support/PadBridge/pairing.key").read_bytes()
    assert len(key) == 32
    def connect():
        return socket.create_connection((args.host, 49372), timeout=7)
    with connect() as s:
        s.sendall(struct.pack(">I", 2**31 - 1)); rejected(s)
    print("PASS oversized pre-auth request rejected")
    with connect() as s:
        raw_send(s, b"PDB1" + os.urandom(32)); rejected(s)
    print("PASS video handshake cannot authenticate a request")
    with connect() as s:
        raw_send(s, b"PDR1" + os.urandom(32)); raw_read(s)
        raw_send(s, bytes(32)); rejected(s)
    print("PASS incorrect request proof rejected")
    with connect() as s:
        cipher, _, old_proof = authenticate(s, key)
        raw_send(s, packet(cipher, {"type": "connect", "host": "192.0.2.1"})); rejected(s)
    print("PASS authenticated request cannot supply a callback host")
    with connect() as s:
        raw_send(s, b"PDR1" + os.urandom(32)); raw_read(s)
        raw_send(s, old_proof); rejected(s)
    print("PASS stale challenge proof rejected")
    with connect() as s:
        cipher, _, _ = authenticate(s, key)
        data = bytearray(packet(cipher, {"type": "connect"})); data[-1] ^= 1
        raw_send(s, data); rejected(s)
    print("PASS tampered connect command rejected")
    with connect() as s:
        cipher, _, _ = authenticate(s, key)
        raw_send(s, packet(cipher, {"type": "connect"}, sequence=1)); rejected(s)
    print("PASS wrong sequence rejected")
    with connect() as s:
        s.sendall(struct.pack(">I", 36) + b"P")
        rejected(s)
    print("PASS incomplete handshake expires")
    with connect() as s:
        cipher, receive, _ = authenticate(s, key)
        raw_send(s, packet(cipher, {"type": "resume"}))
        reply = raw_read(s)
        assert reply[:8] == bytes(8)
        decoded = receive.decrypt(bytes(4) + reply[:8], reply[8:], reply[:8])
        assert decoded[:1] == b"\x01"
        result = json.loads(decoded[1:])
        assert result == {"type": "connect-result", "accepted": False, "reverse": False}
    print("PASS idle resume cannot create a Mac session")
    with connect() as s:
        cipher, _, _ = authenticate(s, key)
        raw_send(s, packet(cipher, {"type": "resume", "force": True})); rejected(s)
    print("PASS resume cannot add control fields")


if __name__ == "__main__":
    main()
