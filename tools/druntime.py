#!/usr/bin/env python3
"""Prepare pinned upstream sources, cross-build a bootstrap archive, and audit port blockers.
fetch is the only network operation. Every build rechecks source hashes;
bootstrap is a subset; startup applies the platform patch and builds the main-thread lifecycle.
audit fails if any selected unmodified full-runtime module fails.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]
CONFIG = PROJECT / 'runtime/druntime'
BUILD = PROJECT / 'build/druntime'
SOURCE = BUILD / 'upstream'
ARCHIVE = BUILD / 'ldc-source.tar.gz'
TARGET = 'x86_64-unknown-none-elf'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_files(archive, lock):
    """Only regular druntime sources and the upstream license enter the prepared tree."""
    files = {}
    with tarfile.open(archive, 'r:gz') as bundle:
        for entry in bundle.getmembers():
            prefix = lock['archive_prefix']
            if not entry.name.startswith(prefix):
                continue
            relative = entry.name[len(prefix):]
            if relative != 'LICENSE' and not relative.startswith('runtime/druntime/src/'):
                continue
            if entry.isdir():
                continue
            if not entry.isfile() or '..' in Path(relative).parts:
                raise ValueError(f'Unexpected archive member: {entry.name}')
            if relative in files:
                raise ValueError(f'Duplicate archive member: {entry.name}')
            files[relative] = bundle.extractfile(entry).read()
    if not files.get('runtime/druntime/src/object.d') or not files.get('LICENSE'):
        raise ValueError('Archive does not contain druntime sources and LICENSE')
    return files


def prepare(lock, supplied_archive):
    BUILD.mkdir(parents=True, exist_ok=True)
    # A failed download or hash check never replaces a previously verified archive.
    with tempfile.TemporaryDirectory(dir=BUILD) as temporary:
        candidate = Path(temporary) / 'source.tar.gz'
        if supplied_archive:
            shutil.copyfile(supplied_archive, candidate)
        elif ARCHIVE.exists():
            shutil.copyfile(ARCHIVE, candidate)
        else:
            with urllib.request.urlopen(lock['url'], timeout=60) as response:
                candidate.write_bytes(response.read())
        if digest(candidate.read_bytes()) != lock['sha256']:
            raise ValueError('Source archive SHA-256 mismatch')
        files = source_files(candidate, lock)
        if SOURCE.exists():
            verify_sources(lock)
        else:
            staged = Path(temporary) / 'upstream'
            for name, data in files.items():
                output = staged / name
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(data)
            manifest = {'lock': lock, 'files': {name: digest(data) for name, data in files.items()}}
            (staged / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
            staged.rename(SOURCE)
        candidate.replace(ARCHIVE)
    print(f'Prepared verified druntime sources: {SOURCE}')


def verify_sources(lock):
    if not SOURCE.exists():
        raise ValueError('Sources missing: run make druntime-fetch (or supply DRUNTIME_ARCHIVE) first')
    manifest = json.loads((SOURCE / 'manifest.json').read_text())
    if manifest['lock'] != lock:
        raise ValueError('Source lock changed; use a separate clean build/druntime directory')
    actual = {str(path.relative_to(SOURCE)) for path in SOURCE.rglob('*') if path.is_file()}
    if actual != set(manifest['files']) | {'manifest.json'}:
        raise ValueError('Prepared source file inventory changed')
    for name, expected in manifest['files'].items():
        if digest((SOURCE / name).read_bytes()) != expected:
            raise ValueError(f'Prepared source modified: {name}; preserve changes as reviewed patches')
    return SOURCE / 'runtime/druntime/src'


def flags(ldc, src, lock):
    compiler = shutil.which(ldc)
    if compiler is None:
        raise ValueError(f'LDC not found: {ldc}')
    compiler = str(Path(compiler).resolve())
    version = subprocess.check_output([compiler, '--version'], text=True)
    if not version.startswith(f"LDC - the LLVM D compiler ({lock['ldc_version']}):"):
        raise ValueError(f"Expected LDC {lock['ldc_version']}, got {version.splitlines()[0]}")
    # Empty config removes host import paths, default libraries and target overrides.
    config = BUILD / 'empty.conf'
    config.write_text('// Deliberately empty: use only pinned source imports.\n')
    return [compiler, f'-conf={config}', f'-mtriple={TARGET}', '-d-version=DlangOS',
            '-O2', '-checkaction=halt', '-relocation-model=static', '-disable-red-zone',
            '-mattr=-mmx,-sse,-sse2', '-fno-moduleinfo', f'-I{src}']


def verify_elf(path):
    data = path.read_bytes()
    if (data[:7] != b'\x7fELF\x02\x01\x01' or len(data) < 64
            or struct.unpack_from('<HH', data, 16) != (1, 62)):
        raise ValueError(f'Not an x86-64 ELF relocatable object: {path}')


def build(lock, ldc, audit=False):
    if not ARCHIVE.exists() or digest(ARCHIVE.read_bytes()) != lock['sha256']:
        raise ValueError('Verified source archive missing or changed; run druntime-fetch')
    src = verify_sources(lock)
    command = flags(ldc, src, lock)
    output = BUILD / ('audit' if audit else 'bootstrap')
    output.mkdir(parents=True, exist_ok=True)
    archive = output / 'libdruntime-bootstrap.a'
    if not audit:
        archive.unlink(missing_ok=True)
    results = []
    objects = []
    for name in lock['audit_modules'] if audit else lock['modules']:
        obj = output / (name.replace('/', '_') + '.o')
        obj.unlink(missing_ok=True)
        invocation = [*command, '-c', f'-of={obj}', str(src / name)]
        result = subprocess.run(invocation, capture_output=True, text=True)
        (output / (name.replace('/', '_') + '.log')).write_text(result.stdout + result.stderr)
        if result.returncode == 0:
            verify_elf(obj)
            objects.append(obj)
        results.append({'module': name, 'returncode': result.returncode, 'command': invocation,
                        'diagnostics': result.stdout + result.stderr})
    report = {'scope': 'full-runtime compile probes' if audit else 'bootstrap subset, not a full druntime',
              'target': TARGET, 'source': lock, 'results': results}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    if any(row['returncode'] for row in results):
        raise ValueError(f'Compile failures recorded in {output / "report.json"}')
    if audit:
        print('Compile probes passed; this does not establish full-runtime linking or execution')
        return
    subprocess.run([*command, '-lib', f'-of={archive}', *map(str, objects)], check=True)
    # Ship provenance and original notices alongside the archive. The retained source
    # archive includes all original per-file copyright headers, without modification.
    shutil.copyfile(CONFIG / 'LICENSE-Boost.txt', output / 'LICENSE-Boost.txt')
    shutil.copyfile(CONFIG / 'LICENSE-LDC.txt', output / 'LICENSE-LDC.txt')
    shutil.copyfile(CONFIG / 'source.lock.json', output / 'source.lock.json')
    shutil.copyfile(CONFIG / 'NOTICE.md', output / 'NOTICE.md')
    print(f'Built bootstrap subset: {archive}')


def build_startup(lock, ldc, cc):
    """Apply the reviewed platform patch to a disposable copy, then link two real TLS applications."""
    original = verify_sources(lock)
    target = BUILD / 'target-src'
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(original, target)
    patches = sorted((CONFIG / 'patches').glob('*.patch'))
    for patch in patches:
        subprocess.run(['patch', '-s', '-p1', '-d', str(target), '-i', str(patch)], check=True)
    command = [*flags(ldc, target, lock), f'-I{CONFIG / "port"}',
               f'-I{PROJECT / "source"}', f'-I{PROJECT / "apps"}',
               '-exception-model=sjlj', '-fno-moduleinfo-localclasses']
    output = BUILD / 'startup'
    output.mkdir(parents=True, exist_ok=True)
    modules = ['object.d', 'rt/dmain2.d', 'rt/minfo.d', 'rt/sections_ldc.d',
               'rt/sections.d', 'rt/config.d', 'core/bitop.d', 'core/internal/hash.d',
               'core/internal/abort.d', 'core/internal/container/common.d']
    objects = []
    commands = []
    for module in modules:
        obj = output / (module.replace('/', '_') + '.o')
        invocation = [*command, '-c', f'-of={obj}', str(target / module)]
        subprocess.run(invocation, check=True)
        verify_elf(obj)
        objects.append(obj)
        commands.append(invocation)
    unwind = output / 'unwind.o'
    invocation = [*command, '-c', f'-of={unwind}', str(PROJECT / 'apps/runtime/d_unwind.d')]
    subprocess.run(invocation, check=True)
    objects.append(unwind)
    commands.append(invocation)
    archive = output / 'libdruntime-startup.a'
    archive.unlink(missing_ok=True)
    subprocess.run([*command, '-lib', f'-of={archive}', *map(str, objects)], check=True)
    c_object = output / 'c_abi.o'
    c_command = [cc, '--target=x86_64-unknown-none-elf', '-ffreestanding', '-nostdinc',
                 '-fno-stack-protector', '-fno-pic', '-mno-red-zone', '-mno-sse', '-mno-sse2',
                 '-O2', '-c', str(PROJECT / 'apps/experiments/druntime_abi.c'), '-o', str(c_object)]
    subprocess.run(c_command, check=True)
    verify_elf(c_object)
    commands.append(c_command)
    # Only applications emit ModuleInfo; the runtime itself has no registered constructors in this stage.
    app_command = [flag for flag in command if flag != '-fno-moduleinfo']
    for name, versions in [('startup', []), ('startup-second', ['-d-version=TlsSecond'])]:
        elf = output / (name + '.elf')
        invocation = [*app_command, *versions, '-link-internally', '-defaultlib=', '-L=-nostdlib',
                      '-L=--gc-sections', '-L=-z', '-L=max-page-size=4096', '-L=-T',
                      f'-L={CONFIG / "app.ld"}', f'-L=-Map={output / (name + ".map")}', f'-of={elf}',
                      *[str(CONFIG / 'port/dlangos' / file) for file in ('entry.d', 'libc.d', 'tls.d')],
                      str(PROJECT / 'apps/user_api.d'), str(PROJECT / 'source/runtime.d'),
                      str(PROJECT / 'apps/experiments/druntime_startup.d'),
                      str(PROJECT / 'apps/experiments/druntime_dependency.d'), str(c_object), str(archive)]
        subprocess.run(invocation, check=True)
        if elf.stat().st_size > 1048576:
            raise ValueError(f'ELF exceeds DlangFS limit: {elf}')
        commands.append(invocation)
    report = {'scope': 'static single-thread startup; GC and general exception support not ported',
              'source': lock, 'patches': {p.name: digest(p.read_bytes()) for p in patches},
              'commands': commands}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    for name in ('LICENSE-LDC.txt', 'LICENSE-Boost.txt', 'NOTICE.md', 'source.lock.json'):
        shutil.copyfile(CONFIG / name, output / name)
    print(f'Built standard druntime startup applications: {output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('fetch', 'build', 'audit', 'startup'))
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--ldc', default='ldc2')
    parser.add_argument('--cc', default='clang')
    args = parser.parse_args()
    lock = json.loads((CONFIG / 'source.lock.json').read_text())
    try:
        if args.action == 'fetch':
            prepare(lock, args.archive)
        elif args.action == 'startup':
            build_startup(lock, args.ldc, args.cc)
        else:
            build(lock, args.ldc, audit=args.action == 'audit')
    except (OSError, ValueError, KeyError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, f'druntime: {error}\n')


if __name__ == '__main__':
    main()
