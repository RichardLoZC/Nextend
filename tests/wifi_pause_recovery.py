#!/usr/bin/env python3
"""Serial real-device test: forward encrypted bytes and pause only this connection."""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import threading
import time

def run(args):
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    name = "wifi-pause-" + str(args.pause).replace(".", "-")
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 49371)); listener.listen(1); listener.settimeout(15)
    stop = threading.Event()
    state = {"injected": False}
    sockets = []
    workers = []
    def relay():
        try:
            client, _ = listener.accept(); sockets.append(client)
            remote = socket.create_connection((args.pad, 49371), timeout=8); sockets.append(remote)
            client.settimeout(8); remote.settimeout(8)
            client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            remote.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            began = time.monotonic()
            def pump(source, target, inject):
                try:
                    while not stop.is_set():
                        try: data = source.recv(65536)
                        except socket.timeout: continue
                        if not data: break
                        if inject and not state["injected"] and time.monotonic() - began >= 4:
                            state["injected"] = True
                            before = time.monotonic(); state["pauseStartedSeconds"] = before - began
                            if stop.wait(args.pause): break
                            state["pausedSeconds"] = time.monotonic() - before
                        target.sendall(data)
                except OSError:
                    pass
                finally:
                    stop.set()
                    for sock in sockets:
                        try: sock.shutdown(socket.SHUT_RDWR)
                        except OSError: pass
            workers.extend([threading.Thread(target=pump, args=(client, remote, True), daemon=True),
                            threading.Thread(target=pump, args=(remote, client, False), daemon=True)])
            for worker in workers: worker.start()
            for worker in workers: worker.join(35)
        except Exception as error:
            state["relayError"] = type(error).__name__
            stop.set()
    relay_worker = threading.Thread(target=relay, daemon=True); relay_worker.start()
    report = output / (name + "-report.json")
    began = time.monotonic()
    process = None
    try:
        with (output / (name + ".log")).open("w") as log:
            process = subprocess.Popen([args.binary, "--benchmark", "--host", "127.0.0.1", "--interface", "lo0",
                "--bitrate", "12", "--seconds", "18", "--report", str(report)], stdout=log, stderr=subprocess.STDOUT)
            code = process.wait(timeout=40)
        state["elapsedSeconds"] = time.monotonic() - began
        state["exitCode"] = code
        detail = json.loads(report.read_text()) if report.exists() else {}
        state["reason"] = detail.get("reason")
        state["decodedAcknowledgements"] = detail.get("decodedAcknowledgements", 0)
        state["samples"] = len(detail.get("samples", []))
        if args.expect == "recover":
            passed = state["injected"] and code == 0 and detail.get("success") is True and state["decodedAcknowledgements"] > 100
        else:
            passed = state["injected"] and code != 0 and detail.get("success") is False and state["elapsedSeconds"] < 25
        state["passed"] = bool(passed)
        (output / (name + "-verification.json")).write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(state, ensure_ascii=False), flush=True)
        return 0 if passed else 1
    finally:
        stop.set(); listener.close()
        for sock in sockets:
            try: sock.close()
            except OSError: pass
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=8)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        relay_worker.join(2)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--pad", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--pause", type=float, default=4)
    parser.add_argument("--expect", choices=["recover", "end"], default="recover")
    arguments = parser.parse_args()
    if not 0 <= arguments.pause <= 12: parser.error("pause must be between 0 and 12 seconds")
    raise SystemExit(run(arguments))
