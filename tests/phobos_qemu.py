"""Run upstream Phobos output ELFs in QEMU, including stream errors and process teardown."""
from pathlib import Path
import sys
import tempfile

from qemu_shell import boot, expect_command, format_disk, free_memory, put_file, wait_process_names


def main(command):
    output = Path('build/phobos/output')
    with tempfile.TemporaryDirectory(prefix='dlang-phobos-') as directory:
        disk = Path(directory) / 'data.img'
        format_disk(disk)
        with boot(command, disk) as (console, _):
            for name in ('phobos_hello', 'phobos_output'):
                put_file(console, (name + '.elf').encode(), (output / (name + '.elf')).read_bytes())
        # Boot from the saved filesystem, exercising the normal ELF loader and runtime entry.
        with boot(command, disk) as (console, _):
            initial_memory = free_memory(console)
            expect_command(console, b'run phobos_hello.elf', b'Hello, world!\r\n')
            expected = ('UTF-8: 日本語\r\n' + ('abcdefghijklmnopqrstuvwxyz' * 12)[:300]
                        + '\r\n\r\nRepeated output passed.\r\nClosed-stream error passed.\r\n').encode()
            expect_command(console, b'run phobos_output.elf', expected)
            # Stream closure and TLS from the previous process must not affect the next launch.
            expect_command(console, b'run phobos_hello.elf', b'Hello, world!\r\n')
            _, totals = wait_process_names(console)
            if totals != (3, 0) or free_memory(console) != initial_memory:
                raise AssertionError(f'Phobos process fault or leaked pages: {totals}')
    print('PASS: upstream Phobos writeln, UTF-8, long output, stream error, relaunch and page reclamation')


if __name__ == '__main__':
    main(sys.argv[1:])
