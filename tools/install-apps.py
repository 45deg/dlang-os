#!/usr/bin/env python3
"""QEMUのシリアルシェルを使い、DlangFSに未配置のアプリだけを追加する。"""

import argparse
import os
from pathlib import Path
import re
import select
import subprocess
import time


PROMPT = b"dlang> "
UPLOAD_READY = b"Send hex, then . on its own line. ! cancels.\r\n"
FILE_LIMIT = 16
FILE_BYTES = 16 * 1024


class Serial:
    def __init__(self, guest):
        self.input = guest.stdin.fileno()
        self.output = guest.stdout.fileno()
        self.pending = b""
        os.set_blocking(self.input, False)

    def read_until(self, marker, timeout=20):
        deadline = time.monotonic() + timeout
        while marker not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.output], [], [], remaining)[0]:
                raise RuntimeError(f"Timed out waiting for {marker!r}: {self.pending[-2048:]!r}")
            chunk = os.read(self.output, 4096)
            if not chunk:
                raise RuntimeError(f"QEMU exited while waiting for {marker!r}: {self.pending[-2048:]!r}")
            self.pending += chunk
        response, self.pending = self.pending.split(marker, 1)
        return response

    def send(self, data):
        deadline = time.monotonic() + 20
        pending = memoryview(data)
        while pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [self.input], [], remaining)[1]:
                raise RuntimeError("Timed out sending data to QEMU")
            pending = pending[os.write(self.input, pending):]


def install(serial, apps):
    startup = serial.read_until(PROMPT, timeout=35)
    if b"Dlang OS (x86_64)\r\n" not in startup or b"Data disk unavailable" in startup:
        raise RuntimeError(f"DlangFS mount failed: {startup[-2048:]!r}")

    serial.send(b"ls\r")
    reply = serial.read_until(PROMPT).splitlines()
    if not reply or reply[0] != b"ls" or any(not valid_name(name) for name in reply[1:]):
        raise RuntimeError(f"Unexpected file listing: {reply!r}")
    existing = set(reply[1:])
    missing = {name: contents for name, contents in apps.items() if name not in existing}
    if len(existing) + len(missing) > FILE_LIMIT:
        raise RuntimeError(f"DlangFS has {FILE_LIMIT - len(existing)} free slots; {len(missing)} are needed")

    for name, data in missing.items():
        command = b"put " + name + b" " + str(len(data)).encode()
        serial.send(command + b"\r\n")
        if serial.read_until(UPLOAD_READY) != command + b"\r\n":
            raise RuntimeError(f"Upload refused for {name.decode()}")
        hex_lines = (data[offset:offset + 32].hex().encode() for offset in range(0, len(data), 32))
        serial.send(b"\r\n".join([*hex_lines, b".", b""]))
        reply = serial.read_until(PROMPT)
        if reply != b"Saved.\r\n":
            raise RuntimeError(f"Unable to save {name.decode()}: {reply!r}")
        print(f"Installed {name.decode()}", flush=True)


def valid_name(name):
    return re.fullmatch(rb"[A-Za-z0-9_-][A-Za-z0-9_.-]{0,23}", name) is not None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--app", type=Path, action="append", required=True)
    parser.add_argument("qemu", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if len(args.qemu) < 2 or args.qemu[0] != "--":
        parser.error("Specify the QEMU command after --")

    apps = {}
    try:
        for path in args.app:
            name = os.fsencode(path.name)
            content = path.read_bytes()
            if not valid_name(name) or name in apps or not 0 < len(content) <= FILE_BYTES:
                raise RuntimeError(f"Invalid application name or size: {path}")
            apps[name] = content

        command = [*args.qemu[1:], "-drive", f"if=ide,index=0,format=raw,file={args.disk.resolve()}"]
        with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as guest:
            try:
                install(Serial(guest), apps)
            finally:
                if guest.poll() is None:
                    guest.terminate()
                    try:
                        guest.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        guest.kill()
    except (OSError, RuntimeError) as error:
        parser.exit(1, f"install-apps: {error}\n")


if __name__ == "__main__":
    main()
