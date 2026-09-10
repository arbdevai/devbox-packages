#!/usr/bin/env bash
# Static archive validation only; this does not prove Android shell execution.
set -euo pipefail
python3 - "${1:?Usage: verify-bootstrap-prefix.sh archive.zip}" "$(dirname "$(realpath "$0")")" <<'PY'
import hashlib
import json
import posixpath
import re
import stat
import struct
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from path_policy import process as process_path_policy, PolicyError

PREFIX = '/data/data/com.devbox.terminal/files/usr'
PACKAGE = 'com.devbox.terminal'
path = Path(sys.argv[1]).resolve()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_name(value):
    require(value and not value.startswith('/') and '\\' not in value and '\x00' not in value,
            f'Unsafe archive path: {value!r}')
    require('..' not in value.split('/'), f'Traversal path: {value!r}')
    value = posixpath.normpath(value)
    require(value != '.', 'Empty archive member')
    return value


try:
    require(path.is_file(), 'Archive does not exist')
    names, directories, links = set(), set(), {}
    saw_prefix = False
    elf_count = 0
    package_names = []
    with zipfile.ZipFile(path) as bundle:
        require(sum(info.file_size for info in bundle.infolist()) <= 2 * 1024**3,
                'Archive exceeds decompressed size limit')
        for info in bundle.infolist():
            name = safe_name(info.filename)
            require(name not in names, f'Duplicate member: {name}')
            names.add(name)
            require(not stat.S_ISLNK(info.external_attr >> 16), 'Symlinks must use SYMLINKS.txt')
            if info.is_dir():
                directories.add(name)
                continue
            require(info.file_size <= 256 * 1024**2, f'Member too large: {name}')
            data = bundle.read(info)  # Verifies ZIP CRC without extracting files.
            entry_hash = hashlib.sha256(data).hexdigest()
            try:
                findings = process_path_policy(data, name, entry_hash)
                for line in findings:
                    print(f"  {line}")
            except PolicyError as e:
                require(False, str(e))
            saw_prefix |= PREFIX.encode() in data
            if data.startswith(b'\x7fELF'):
                require(len(data) >= 64 and data[4:7] == b'\x02\x01\x01', f'Invalid ELF64 header: {name}')
                require(struct.unpack_from('<H', data, 18)[0] == 183, f'Non-ARM64 ELF: {name}')
                elf_count += 1
            if name == 'SYMLINKS.txt':
                for line in data.decode('utf-8').splitlines():
                    parts = line.split('←')
                    require(len(parts) == 2 and all(parts), 'Malformed symlink record')
                    target, link = parts
                    link = safe_name(link)
                    require(link not in links, f'Duplicate symlink: {link}')
                    if target.startswith('/'):
                        require(target.startswith(PREFIX + '/'), f'Foreign symlink target: {target}')
                        target = target[len(PREFIX) + 1:]
                    else:
                        target = posixpath.normpath(posixpath.join(posixpath.dirname(link), target))
                    links[link] = safe_name(target)
            if name == 'var/lib/dpkg/status':
                package_names = sorted(set(re.findall(r'^Package: (\S+)$', data.decode('utf-8'), re.M)))
    require(links and 'SYMLINKS.txt' in names, 'Missing or empty symlink table')
    require(saw_prefix and elf_count > 0, 'No DevBox prefix or ARM64 ELF found')
    require(not names.intersection(links), 'Symlink collides with archive entry')
    for name in names | set(links):
        parent = posixpath.dirname(name)
        while parent:
            require(parent not in links, f'Symlink used as extraction parent: {parent}')
            parent = posixpath.dirname(parent)
    for required in ('bin/bash', 'bin/dash', 'bin/sh', 'bin/dpkg', 'bin/apt', 'var/lib/dpkg/status'):
        resolved, visited = required, set()
        while resolved in links:
            require(resolved not in visited, f'Symlink cycle: {required}')
            visited.add(resolved)
            resolved = links[resolved]
        require(resolved in names and resolved not in directories, f'Missing essential file: {required}')
    require(package_names, 'Empty package database')
    digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
    manifest = dict(application_name='DevBox', package_name=PACKAGE, prefix=PREFIX,
                    architecture='aarch64', archive_file=path.name, sha256=digest,
                    size_bytes=path.stat().st_size, file_count=len(names - directories),
                    symlink_count=len(links), elf_count=elf_count, installed_packages=package_names,
                    validation='static archive inspection; Android runtime testing still required')
    path.with_name(path.name + '.sha256').write_text(f'{digest}  {path.name}\n')
    path.with_name('manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Static bootstrap validation passed: {elf_count} ARM64 ELF files, {len(links)} symlinks')
except (ValueError, OSError, UnicodeError, zipfile.BadZipFile, struct.error) as error:
    print(f'Bootstrap validation FAILED: {error}', file=sys.stderr)
    sys.exit(1)
PY
