#!/usr/bin/env python3
"""Exercise touch negotiation against the Pad without injecting any Mac input.

Requires an idle, foreground Pad. No desktop image or input event is sent.
"""
import socket
import subprocess
from device_protocol import ADB, Client


def main():
    devices = subprocess.check_output([ADB, "devices", "-l"], text=True)
    serials = [line.split()[0] for line in devices.splitlines() if " device " in line and "usb:" in line]
    assert len(serials) == 1, "Connect exactly one authorized USB Pad"
    prefix = [ADB, "-s", serials[0]]
    key = subprocess.check_output(prefix + ["exec-out", "run-as", "dev.padbridge", "cat", "files/pairing.key"])
    port = int(subprocess.check_output(prefix + ["forward", "tcp:0", "tcp:49371"]))

    def begin(negotiated=True, controls=False):
        sock = socket.create_connection(("127.0.0.1", port), timeout=7)
        client = Client(sock, key)
        assert client.hello["input"] is False and client.hello["touchVersion"] == 1
        probe = dict(type="probe", version=1, width=2400, height=1600, fps=60)
        client.send(probe)
        capabilities = client.read()
        codec = "hevc" if "hevc" in capabilities["codecs"] else "h264"
        config = dict(probe, type="config", codec=codec, color="bt709-limited-sdr", bitDepth=8, input=False)
        if negotiated:
            config["touchVersion"] = 1
        if controls:
            config["controlsVersion"] = 1
        client.send(config)
        ready = client.read()
        assert ready["type"] == "ready"
        assert ready.get("touchVersion") == (1 if negotiated else None)
        return sock, client

    def state(client, epoch, enabled):
        client.send(dict(type="touch-mode", epoch=epoch, enabled=enabled))
        for _ in range(10):
            value = client.read()
            if value["type"] == "touch-state":
                assert value["epoch"] == epoch and value["enabled"] is enabled
                return
            assert value["type"] == "stats", value
        raise AssertionError("missing mode acknowledgement")

    try:
        sock, client = begin()
        with sock:
            state(client, 1, False); state(client, 2, True); state(client, 3, False); state(client, 4, True)
            client.send(dict(type="stop"))
        print("PASS negotiated live off/on/off/on with increasing epochs")
        sock, client = begin(False)
        with sock:
            client.send(dict(type="touch-mode", epoch=1, enabled=True)); client.rejected()
        print("PASS legacy video session rejects unnegotiated touch mode")
        for invalid in [0, -1, True, "1", 1.5, 2147483648]:
            sock, client = begin()
            with sock:
                client.send(dict(type="touch-mode", epoch=invalid, enabled=True)); client.rejected()
        print("PASS invalid epoch types/ranges rejected")
        sock, client = begin()
        with sock:
            state(client, 1, True)
            client.send(dict(type="touch-mode", epoch=1, enabled=False)); client.rejected()
        print("PASS repeated epoch rejected")
        sock, client = begin()
        with sock:
            client.send(dict(type="touch-mode", epoch=1, enabled=1)); client.rejected()
        print("PASS enabled requires JSON boolean")
        sock, client = begin()
        with sock:
            client.send(dict(type="touch", epoch=1, phase="click", x=.5, y=.5)); client.rejected()
        print("PASS reverse-direction input injection rejected")
        sock, client = begin()
        with sock:
            client.send(dict(type="touch-mode", epoch=1, enabled=True, mode="trackpad"))
            assert client.read()["type"] == "touch-state"
            client.send(dict(type="touch-mode", epoch=2, enabled=True, mode="arbitrary")); client.rejected()
        print("PASS trackpad mode accepted; unknown modes rejected")
        preferences = dict(type="pad-settings", language="en", showFPS=False, size=20, font=1, color="#FFFFFF", x=.1, y=.2)
        sock, client = begin()
        with sock:
            client.send(preferences); client.rejected()
        print("PASS unnegotiated settings rejected")
        for field, invalid in [("showFPS", 1), ("size", True), ("font", 3), ("color", "red"), ("x", 1.1), ("language", "unsupported")]:
            sock, client = begin(controls=True)
            with sock:
                client.send(dict(preferences, **{field: invalid})); client.rejected()
        print("PASS invalid settings rejected")
    finally:
        subprocess.run(prefix + ["forward", "--remove", f"tcp:{port}"], check=True)


if __name__ == "__main__":
    main()
