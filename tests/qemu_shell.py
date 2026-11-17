"""Essential QEMU regressions on disposable disks.
main checks process isolation, ELF loading, and VM rollback;
verify_storage checks persistence and recovery. Runtime suites reuse the serial helpers.
"""

from contextlib import contextmanager
from hashlib import sha256
import os
from pathlib import Path
import re
import select
from struct import unpack_from
import subprocess
import sys
import tempfile
import time


PROMPT = b"dlang> "
UPLOAD_READY = b"Send hex, then . on its own line. ! cancels.\r\n"


class SerialConsole:
    def __init__(self, guest):
        self.input = guest.stdin
        self.output = guest.stdout
        self.pending = b""

    def send(self, data):
        self.input.write(data)
        self.input.flush()

    def read_until(self, marker, timeout=5):
        deadline = time.monotonic() + timeout
        while marker not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.output], [], [], remaining)[0]:
                raise AssertionError(f"Timed out waiting for {marker!r}; got {self.pending!r}")
            received = os.read(self.output.fileno(), 4096)
            if not received:
                raise AssertionError(f"QEMU exited while waiting for {marker!r}; got {self.pending!r}")
            self.pending += received
        output, self.pending = self.pending.split(marker, 1)
        return output

    def command(self, data):
        self.send(data)
        return self.read_until(PROMPT)


def expect_equal(actual, expected):
    if actual != expected:
        raise AssertionError(f"Expected {expected!r}; got {actual!r}")


PROJECT = Path(__file__).resolve().parents[1]
APP_DIRECTORY = PROJECT / "build" / "apps"


@contextmanager
def boot(qemu_command, disk, *, disk_ready=True):
    command = [*qemu_command, "-drive", f"if=ide,index=0,format=raw,file={disk}"]
    with subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    ) as guest:
        try:
            console = SerialConsole(guest)
            log = console.read_until(PROMPT, timeout=35)
            unavailable = b"Data disk unavailable" in log
            if b"Dlang OS (x86_64)\r\n" not in log or unavailable == disk_ready:
                raise AssertionError(f"Unexpected startup or disk state: {log!r}")
            yield console
        finally:
            if guest.poll() is None:
                guest.terminate()
                try:
                    guest.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    guest.kill()


def expect_command(console, command, response=b""):
    expect_equal(console.command(command + b"\r"), command + b"\r\n" + response)


def spawn_process(console, program):
    response = console.command(b"spawn " + program + b"\r")
    match = re.fullmatch(rb"spawn " + program + rb"\r\nStarted PID ([0-9]+)\r\n", response)
    if match is None:
        raise AssertionError(f"Unable to start {program!r}: {response!r}")
    return int(match[1])


def process_list(console):
    response = console.command(b"ps\r")
    rows = re.findall(rb"^([0-9]+) ([A-Za-z0-9_.-]+) ([0-9]+) ([0-9]+) ([0-9]+)\r$", response, re.M)
    totals = re.search(rb"Exited: ([0-9]+)  Faulted: ([0-9]+)", response)
    if totals is None:
        raise AssertionError(f"Missing process totals: {response!r}")
    return {int(pid): (name, int(value), int(slices), int(preemptions))
            for pid, name, value, slices, preemptions in rows}, tuple(map(int, totals.groups()))


def wait_process_names(console, *names):
    expected = sorted(names)
    deadline = time.monotonic() + 5
    while True:
        running, totals = process_list(console)
        actual = sorted(task[0] for task in running.values())
        if actual == expected:
            return running, totals
        if time.monotonic() >= deadline:
            expect_equal(actual, expected)
        time.sleep(0.05)


def stop_process(console, pid):
    expect_command(console, f"kill {pid}".encode(), b"Stopped.\r\n")


def free_memory(console):
    response = console.command(b"mem\r")
    match = re.search(rb"Free pages: ([0-9]+) KiB", response)
    if match is None:
        raise AssertionError(f"Missing allocator statistics: {response!r}")
    return int(match[1])


def verify_processes(console):
    baseline_memory = free_memory(console)
    spin = spawn_process(console, b"spin")
    first = spawn_process(console, b"counter")
    second = spawn_process(console, b"counter")
    exited = spawn_process(console, b"exit")
    faulted = spawn_process(console, b"fault")

    if free_memory(console) >= baseline_memory:
        raise AssertionError("Live processes did not consume physical pages")
    before, _ = process_list(console)
    deadline = time.monotonic() + 5
    while True:
        after, totals = process_list(console)
        if (all(pid in before and pid in after and after[pid][1] > before[pid][1]
                for pid in (first, second))
                and spin in before and spin in after and after[spin][3] > before[spin][3]):
            break
        if time.monotonic() >= deadline:
            raise AssertionError(f"Runnable processes did not make progress: {before}, {after}")
        time.sleep(0.01)
    # spin makes no syscalls. Check that timer interrupts preempt it and both other tasks make progress.
    if (spin not in before or spin not in after or after[spin][0] != b"spin"
            or after[spin][3] <= before[spin][3]):
        raise AssertionError(f"Non-yielding process did not get preempted: {before}, {after}")
    for pid in (first, second):
        if (pid not in before or pid not in after or after[pid][0] != b"counter"
                or not before[pid][1] < after[pid][1]):
            raise AssertionError(f"Counter {pid} lost progress or its stack: {before}, {after}")
    expect_equal(totals, (1, 1))
    if exited in after or faulted in after:
        raise AssertionError(f"A finished process is still runnable: {after}")

    for pid in (spin, first, second):
        stop_process(console, pid)
    expect_equal(free_memory(console), baseline_memory)
    expect_equal(process_list(console)[0], {})


def begin_upload(console, name, size):
    command = b"put " + name + b" " + str(size).encode()
    console.send(command + b"\r\n")
    expect_equal(console.read_until(UPLOAD_READY, timeout=15), command + b"\r\n")


def put_file(console, name, contents):
    begin_upload(console, name, len(contents))
    hex_lines = [contents[offset : offset + 32].hex().encode()
                 for offset in range(0, len(contents), 32)]
    console.send(b"\r\n".join([*hex_lines, b".", b""]))
    expect_equal(console.read_until(PROMPT, timeout=20), b"Saved.\r\n")


def expect_file_bytes(console, name, expected):
    console.send(b"get " + name + b"\r")
    output = console.read_until(PROMPT, timeout=20).splitlines()
    expect_equal(output[0:2], [b"get " + name, b"HEX " + str(len(expected)).encode()])
    received = bytes.fromhex(b"".join(output[2:]).decode("ascii"))
    if received != expected:
        raise AssertionError(
            f"{name!r}: expected {len(expected)} bytes ({sha256(expected).hexdigest()}), "
            f"got {len(received)} bytes ({sha256(received).hexdigest()})"
        )


def run_hello(console):
    expect_command(console, b"run hello.elf", b"Hello from a D ELF on disk!\r\n")


def verify_disk_elf(console):
    baseline_memory = free_memory(console)
    hello = (APP_DIRECTORY / "hello.elf").read_bytes()
    before, totals = process_list(console)
    expect_command(console, b"run missing.elf", b"File not found.\r\n")
    put_file(console, b"hello.elf", hello[:64])
    expect_command(console, b"run hello.elf", b"Unsupported or invalid ELF executable.\r\n")
    expect_equal(process_list(console), (before, totals))

    # Reclaim allocations if entry-point validation fails after mapping PT_LOAD segments.
    invalid_entry = bytearray(hello)
    invalid_entry[24:32] = bytes(8)
    put_file(console, b"hello.elf", invalid_entry)
    for _ in range(8):
        expect_command(console, b"run hello.elf", b"Unsupported or invalid ELF executable.\r\n")
    expect_equal(free_memory(console), baseline_memory)

    put_file(console, b"hello.elf", hello)
    run_hello(console)
    run_hello(console)  # Reused BSS must be clear of data from the previous run.
    expect_equal(process_list(console), (before, (totals[0] + 2, totals[1])))
    expect_equal(free_memory(console), baseline_memory)


def verify_virtual_memory(console):
    baseline = free_memory(console)
    before, totals = process_list(console)
    put_file(console, b"vm.elf", (APP_DIRECTORY / "vm.elf").read_bytes())
    for _ in range(2):
        console.send(b"run vm.elf\r")
        expect_equal(console.read_until(PROMPT, timeout=30),
                     b"run vm.elf\r\nVM: large BSS, stack, heap growth, shrink and OOM rollback passed.\r\n")
        expect_equal(free_memory(console), baseline)
    expect_equal(process_list(console), (before, (totals[0] + 2, totals[1])))


def verify_unsupported_formats(qemu_command, root):
    # A valid DlangFS3 header from the former formatter (16 slots, 16 KiB per file).
    legacy_header = bytes.fromhex(
        "444c414e47465333 03000000 00020000 10000000 00400000 01000000"
        " 21000000 22000000 18000000 f2c703ff"
    )
    legacy_disk = root / "unsupported-v3.img"
    fixtures = (
        (root / "unsupported-v1.img", b"DLANGFS1"),
        (root / "unsupported-v2.img", b"DLANGFS2"),
        (legacy_disk, legacy_header),
    )
    for disk, header in fixtures:
        original = header.ljust(1024 * 1024, b"\0")
        disk.write_bytes(original)
        with boot(qemu_command, disk, disk_ready=False) as console:
            expect_command(console, b"write forbidden.txt no", b"Data disk unavailable.\r\n")
        expect_equal(disk.read_bytes(), original)

    # A legacy disk alongside a supported one must not count as a second mount candidate.
    current = root / "current.img"
    format_disk(current)
    extra_drive = ["-drive", f"if=ide,index=1,format=raw,file={legacy_disk}"]
    with boot([*qemu_command, *extra_drive], current) as console:
        expect_command(console, b"write current.txt writable", b"Saved.\r\n")
    with boot(qemu_command, current) as console:
        expect_command(console, b"cat current.txt", b"writable\r\n")
    expect_equal(legacy_disk.read_bytes(), legacy_header.ljust(1024 * 1024, b"\0"))


def format_disk(path, *options):
    subprocess.run([sys.executable, str(PROJECT / "tools/format-disk.py"), str(path), *options], check=True)


def verify_storage(command, root):
    disk = root / "storage.img"
    format_disk(disk, "--slots", "3")
    payload = bytes(range(256)) * 4096
    with boot(command, disk) as console:
        expect_command(console, b"write history.txt first version", b"Saved.\r\n")
        expect_command(console, b"write history.txt second version", b"Saved.\r\n")
        put_file(console, b"full.bin", payload)
        # An interrupted upload must not replace the committed contents.
        begin_upload(console, b"history.txt", 3)
        console.send(b"41\r\n.\r\n")
        expect_equal(console.read_until(PROMPT),
                     b"Invalid hex data or byte count. File was not changed.\r\n")
    saved = disk.read_bytes()
    with boot(command, disk) as console:
        expect_command(console, b"cat history.txt", b"second version\r\n")
        expect_file_bytes(console, b"full.bin", payload)
    expect_equal(disk.read_bytes(), saved)
    damaged = bytearray(saved)
    damaged[damaged.index(b"second version")] ^= 1
    disk.write_bytes(damaged)
    with boot(command, disk) as console:
        expect_command(console, b"cat history.txt", b"first version\r\n")

    # 空きスロット (slot 2) の B 側だけに書きかけのメタデータを残す。
    records_lba, copy_sectors = unpack_from("<II", saved, 24)
    first_write = (records_lba + (2 * 2 + 1) * copy_sectors) * 512
    damaged[first_write + 4] = 1  # シーケンス番号は 0 のままなので無効なレコード。
    disk.write_bytes(damaged)
    with boot(command, disk) as console:
        expect_command(console, b"cat history.txt", b"first version\r\n")
        expect_file_bytes(console, b"full.bin", payload)
        expect_command(console, b"write retry.txt recovered", b"Saved.\r\n")
    with boot(command, disk) as console:
        expect_command(console, b"cat retry.txt", b"recovered\r\n")


def main(qemu_command):
    with tempfile.TemporaryDirectory(prefix="dlang-") as directory:
        root = Path(directory)
        disk = root / "data.img"
        format_disk(disk)
        with boot(qemu_command, disk) as console:
            expect_command(console, b"uname", b"Dlang OS x86_64\r\n")
            verify_processes(console)
            verify_disk_elf(console)
            verify_virtual_memory(console)
        verify_storage(qemu_command, root)
        verify_unsupported_formats(qemu_command, root)
    print("PASS: boot, process isolation, ELF validation, VM rollback, persistence and recovery")


if __name__ == "__main__":
    main(sys.argv[1:])
