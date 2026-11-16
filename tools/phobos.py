#!/usr/bin/env python3
"""Fetch pinned Phobos sources and build the std.stdio output subset against DlangOS.
Original sources remain intact; build applies tracked patches to disposable copies.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

import druntime

PROJECT = druntime.PROJECT
CONFIG = PROJECT / 'runtime/phobos'
BUILD = PROJECT / 'build/phobos'
ARCHIVE = BUILD / 'phobos-source.tar.gz'
SOURCE = BUILD / 'upstream'


def verify_archive(lock, archive):
    if not archive.exists() or druntime.digest(archive.read_bytes()) != lock['sha256']:
        raise ValueError('Phobos source archive missing or changed; run make phobos-fetch')


def unpack(archive, target, prefix):
    with tarfile.open(archive, 'r:gz') as bundle:
        for entry in bundle.getmembers():
            if entry.isdir():
                continue
            if not entry.name.startswith(prefix) or not entry.isfile():
                raise ValueError(f'Unexpected Phobos archive member: {entry.name}')
            relative = Path(entry.name[len(prefix):])
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError(f'Invalid Phobos archive member: {entry.name}')
            output = target / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(bundle.extractfile(entry).read())


def fetch(lock, supplied):
    BUILD.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=BUILD) as temporary:
        candidate = Path(temporary) / 'source.tar.gz'
        if supplied or ARCHIVE.exists():
            shutil.copyfile(supplied or ARCHIVE, candidate)
        else:
            with urllib.request.urlopen(lock['url'], timeout=60) as response:
                candidate.write_bytes(response.read())
        verify_archive(lock, candidate)
        candidate.replace(ARCHIVE)
    print(f'Prepared pinned Phobos archive: {ARCHIVE}')


def apply_patch(target, patch):
    subprocess.run(['patch', '-s', '-p1', '-d', str(target), '-i', str(patch)], check=True)


def build(lock, ldc):
    verify_archive(lock, ARCHIVE)
    runtime_lock = json.loads((druntime.CONFIG / 'source.lock.json').read_text())
    original_runtime = druntime.verify_sources(runtime_lock)
    # Generated trees have no user edits: patches under runtime/ are the source of truth.
    for directory in (SOURCE, BUILD / 'target-src', BUILD / 'druntime-src'):
        if directory.exists():
            shutil.rmtree(directory)
    unpack(ARCHIVE, SOURCE, lock['archive_prefix'])
    phobos = BUILD / 'target-src'
    runtime = BUILD / 'druntime-src'
    shutil.copytree(SOURCE, phobos)
    shutil.copytree(original_runtime, runtime)
    runtime_patches = sorted((druntime.CONFIG / 'patches').glob('*.patch'))
    for patch in runtime_patches:
        apply_patch(runtime, patch)
    stdio_patch = CONFIG / 'patches/0001-dlangos-stdio.patch'
    runtime_patch = CONFIG / 'patches/0002-dlangos-runtime.patch'
    apply_patch(phobos, stdio_patch)
    apply_patch(runtime, runtime_patch)
    output = BUILD / 'output'
    output.mkdir(parents=True, exist_ok=True)
    command = [*druntime.flags(ldc, runtime, runtime_lock), f'-I{phobos}',
               f'-I{druntime.CONFIG / "port"}', f'-I{PROJECT / "apps"}',
               f'-I{PROJECT / "source"}', '-exception-model=sjlj', '-fno-moduleinfo-localclasses']
    modules = [(phobos, name) for name in ('std/stdio.d', 'std/utf.d', 'std/exception.d')]
    modules += [(runtime, name) for name in (
        'core/exception.d', 'core/internal/cast_.d', 'core/internal/array/utils.d',
        'core/internal/util/array.d', 'core/memory.d', 'rt/lifetime.d',
        'rt/ehalloc.d', 'rt/arraycat.d', 'rt/util/typeinfo.d')]
    objects, commands = [], []
    for root, module in modules:
        obj = output / (module.replace('/', '_') + '.o')
        invocation = [*command, '-c', f'-of={obj}', str(root / module)]
        subprocess.run(invocation, check=True)
        druntime.verify_elf(obj)
        objects.append(str(obj))
        commands.append(invocation)
    archive = output / 'libphobos-output.a'
    archive.unlink(missing_ok=True)
    invocation = [*command, '-lib', f'-of={archive}', *objects]
    subprocess.run(invocation, check=True)
    commands.append(invocation)
    app_command = [flag for flag in command if flag != '-fno-moduleinfo']
    for name in ('phobos_hello', 'phobos_output'):
        elf = output / (name + '.elf')
        invocation = [*app_command, '-link-internally', '-defaultlib=', '-L=-nostdlib',
                      '-L=--gc-sections', '-L=-z', '-L=max-page-size=4096', '-L=-T',
                      f'-L={druntime.CONFIG / "app.ld"}', f'-L=-Map={output / (name + ".map")}',
                      f'-of={elf}', str(PROJECT / 'apps/experiments' / (name + '.d')),
                      *[str(druntime.CONFIG / 'port/dlangos' / file) for file in
                        ('entry.d', 'libc.d', 'tls.d', 'gc.d')],
                      str(PROJECT / 'apps/user_api.d'), str(PROJECT / 'source/runtime.d'),
                      str(archive), str(druntime.BUILD / 'startup/libdruntime-startup.a')]
        subprocess.run(invocation, check=True)
        if elf.stat().st_size > 1048576:
            raise ValueError(f'ELF exceeds DlangFS limit: {elf}')
        commands.append(invocation)
    patches = [*runtime_patches, stdio_patch, runtime_patch]
    report = {'scope': 'Phobos std.stdio output; no tracing GC, filesystem streams or FP/SIMD',
              'source': lock, 'druntime': runtime_lock,
              'patches': {str(p.relative_to(PROJECT)): druntime.digest(p.read_bytes()) for p in patches},
              'commands': commands}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    for name in ('LICENSE_1_0.txt', 'NOTICE.md', 'source.lock.json'):
        shutil.copyfile(CONFIG / name, output / name)
    print(f'Built upstream Phobos output applications: {output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('fetch', 'build'))
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--ldc', default='ldc2')
    args = parser.parse_args()
    lock = json.loads((CONFIG / 'source.lock.json').read_text())
    try:
        if args.action == 'fetch':
            fetch(lock, args.archive)
        else:
            build(lock, args.ldc)
    except (OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, f'phobos: {error}\n')


if __name__ == '__main__':
    main()
