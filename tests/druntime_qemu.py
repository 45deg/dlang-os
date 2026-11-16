"""Boot disposable disks to verify upstream static linking, C ABI, TLS isolation and module lifecycle.
Check actual timer preemption, normal teardown, slot reuse, and invalid ELF rejection.
"""
from pathlib import Path
import re
import struct
import time
import sys
import tempfile

from qemu_shell import boot, expect_command, expect_file_bytes, format_disk, put_file, process_list, free_memory, wait_process_names, PROMPT


def main(command):
    elf = Path('build/druntime/bootstrap/druntime_bootstrap.elf').read_bytes()
    if not 65535 < len(elf) <= 1048576:
        raise AssertionError('Bootstrap ELF must exercise the widened file length')
    with tempfile.TemporaryDirectory(prefix='dlang-druntime-') as directory:
        disk = Path(directory) / 'bootstrap.img'
        format_disk(disk)
        with boot(command, disk) as console:
            put_file(console, b'bootstrap.elf', elf)
        saved = disk.read_bytes()
        with boot(command, disk) as console:
            expect_file_bytes(console, b'bootstrap.elf', elf)
            expect_command(console, b'run bootstrap.elf',
                           b'Upstream druntime bootstrap and large ELF passed.\r\n')
        if disk.read_bytes() != saved:
            raise AssertionError('Reading and executing the ELF modified its disk')
    verify_startup(command)
    print('PASS: upstream startup, C ABI, TLS across preemption, destructor ordering, and large ELF persistence')


def verify_startup(command):
    output = Path('build/druntime/startup')
    expected = [b'Standard druntime C ABI and main TLS passed.', b'TLS destructor passed.',
                b'Dependency TLS destructor passed.', b'Shared destructor passed.',
                b'Dependency shared destructor passed.']
    with tempfile.TemporaryDirectory(prefix='dlang-startup-') as directory:
        disk = Path(directory) / 'startup.img'
        format_disk(disk)
        with boot(command, disk) as console:
            initial_memory = free_memory(console)
            for name in ('startup', 'startup-second'):
                put_file(console, (name + '.elf').encode(), (output / (name + '.elf')).read_bytes())
            for name in ('startup', 'startup-second'):
                reply = console.command(b'run ' + name.encode() + b'.elf &\r')
                if not re.search(rb'Started PID [0-9]+', reply):
                    raise AssertionError(reply)
            deadline = time.monotonic() + 15
            while True:
                running, totals = process_list(console)
                if len(running) == 2 and sorted(row[1] for row in running.values()) == [101, 202]:
                    if any(row[3] == 0 for row in running.values()):
                        raise AssertionError('TLS programs did not undergo timer preemption')
                    break
                if time.monotonic() >= deadline or len(running) != 2:
                    raise AssertionError(f'TLS programs failed before publishing results: {running}, {totals}')
                time.sleep(0.01)
            marker = expected[-1] + b'\r\n'
            transcript = b''.join(console.read_until(marker, timeout=15) + marker for _ in range(2))
            for line in expected:
                if transcript.splitlines().count(line) != 2:
                    raise AssertionError(f'Missing lifecycle output {line!r}: {transcript!r}')
            _, totals = wait_process_names(console)
            if totals != (2, 0) or free_memory(console) != initial_memory:
                raise AssertionError('TLS process exit faulted or leaked pages')
            # Reuse the process slot and physical pages: .tdata/.tbss must be reinitialized.
            console.send(b'run startup.elf\r')
            reply = console.read_until(PROMPT, timeout=15)
            if reply != b'run startup.elf\r\n' + b''.join(line + b'\r\n' for line in expected):
                raise AssertionError(reply)
            if free_memory(console) != initial_memory:
                raise AssertionError('Repeated startup leaked pages')
            # Reject invalid TLS size/alignment before running any constructors; undo partial ELF mappings.
            image = (output / 'startup.elf').read_bytes()
            phoff = struct.unpack_from('<Q', image, 32)[0]
            count = struct.unpack_from('<H', image, 56)[0]
            tls = next(phoff + i * 56 for i in range(count)
                       if struct.unpack_from('<I', image, phoff + i * 56)[0] == 7)
            for field, value in ((40, 65537), (48, 3), (8, len(image) + 1)):
                invalid = bytearray(image)
                struct.pack_into('<Q', invalid, tls + field, value)
                put_file(console, b'invalid.elf', invalid)
                expect_command(console, b'run invalid.elf', b'Unsupported or invalid ELF executable.\r\n')
                if free_memory(console) != initial_memory:
                    raise AssertionError('Rejected TLS ELF leaked pages')


if __name__ == '__main__':
    main(sys.argv[1:])
