#!/usr/bin/env python3
"""Create a DlangFS4 image, or a legacy v3 fixture, without overwriting existing files.
header validates the layout; main writes a sparse image with two generations per slot.
"""

import argparse
from pathlib import Path
import struct

SECTOR_BYTES = 512


def header(slots=16, file_bytes=1048576, records_lba=1, copy_sectors=None, version=4):
    minimum_stride = 1 + (file_bytes + SECTOR_BYTES - 1) // SECTOR_BYTES
    if copy_sectors is None:
        copy_sectors = minimum_stride
    if not (version in (3, 4) and 1 <= slots <= 16
            and 1 <= file_bytes <= (65535 if version == 3 else 1048576)
            and 1 <= records_lba <= 0xFFFFFFFF and minimum_stride <= copy_sectors <= 0xFFFFFFFF
            and records_lba + slots * 2 * copy_sectors <= 0x100000000):
        raise ValueError("Invalid volume layout")
    result = bytearray(SECTOR_BYTES)
    struct.pack_into('<8s9I', result, 0, f'DLANGFS{version}'.encode(), version, SECTOR_BYTES, slots,
                     file_bytes, records_lba, copy_sectors, 34 if version == 3 else 36, 24, 0)
    checksum = 2166136261
    for value in result[:40] + result[44:]:
        checksum = ((checksum ^ value) * 16777619) & 0xFFFFFFFF
    struct.pack_into('<I', result, 40, checksum)
    return bytes(result), records_lba + slots * 2 * copy_sectors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    parser.add_argument('--slots', type=int, default=16)
    parser.add_argument('--format-version', type=int, choices=(3, 4), default=4)
    parser.add_argument('--file-bytes', type=int)
    parser.add_argument('--records-lba', type=int, default=1)
    parser.add_argument('--copy-sectors', type=int)
    parser.add_argument('--size-bytes', type=int)
    args = parser.parse_args()
    try:
        file_bytes = args.file_bytes if args.file_bytes is not None else (16384 if args.format_version == 3 else 1048576)
        metadata, sectors = header(args.slots, file_bytes, args.records_lba, args.copy_sectors, args.format_version)
        size_bytes = args.size_bytes if args.size_bytes is not None else max(1024 * 1024, sectors * SECTOR_BYTES)
        if size_bytes < sectors * SECTOR_BYTES or size_bytes % SECTOR_BYTES:
            raise ValueError('Image must be sector-aligned and large enough for the volume')
        with args.path.open('xb') as image:
            image.truncate(size_bytes)
            image.write(metadata)
    except (OSError, ValueError) as error:
        parser.exit(1, f'format-disk: {error}\n')


if __name__ == '__main__':
    main()
