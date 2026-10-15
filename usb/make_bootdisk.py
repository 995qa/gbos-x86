#!/usr/bin/env python3
"""make_bootdisk.py OUT.img: small GPT disk with misc + vbmeta_a/vbmeta_b for the ChromeOS-style boot HAL.

vbmeta_a/b carry cgpt slot attributes (priority bits 48-51, tries 52-55, successful bit 56);
slot A is active and marked successful.
"""
import struct, sys, uuid, zlib

SECTOR = 512
PARTS = [('misc', 4 << 20, 0), ('vbmeta_a', 1 << 20, (2 << 48) | (1 << 56)), ('vbmeta_b', 1 << 20, (1 << 48) | (1 << 56))]
BASIC_DATA = uuid.UUID('ebd0a0a2-b9e5-4433-87c0-68b99b26c7c7')


def main(out):
    first = 2048
    entries, lba = [], first
    for name, size, attrs in PARTS:
        n = size // SECTOR
        entries.append(struct.pack('<16s16sQQQ72s', BASIC_DATA.bytes_le, uuid.uuid4().bytes_le,
                                   lba, lba + n - 1, attrs, name.encode('utf-16-le')))
        lba += n
    total = lba + 2048
    table = b''.join(entries).ljust(128 * 128, b'\0')
    tcrc = zlib.crc32(table)
    disk = uuid.uuid4().bytes_le

    def hdr(my, alt, ent):
        h = struct.pack('<8sIIIIQQQQ16sQIII', b'EFI PART', 0x10000, 92, 0, 0, my, alt, first, total - 34,
                        disk, ent, 128, 128, tcrc)
        return h[:16] + struct.pack('<I', zlib.crc32(h)) + h[20:]
    mbr = bytearray(SECTOR)
    mbr[446:462] = struct.pack('<BBBBBBBBII', 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, min(total - 1, 0xFFFFFFFF))
    mbr[510:512] = b'\x55\xaa'
    with open(out, 'wb') as f:
        f.truncate(total * SECTOR)
        f.write(mbr); f.write(hdr(1, total - 1, 2).ljust(SECTOR, b'\0')); f.write(table)
        f.seek((total - 33) * SECTOR); f.write(table); f.write(hdr(total - 1, 1, total - 33).ljust(SECTOR, b'\0'))


if __name__ == '__main__':
    main(sys.argv[1])
