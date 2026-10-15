#!/usr/bin/env python3
"""List and extract Android logical partitions (super / liblp) from a raw GPT disk image.

  lp_extract.py DISK.raw                 list GPT partitions and super's logical partitions
  lp_extract.py DISK.raw OUTDIR NAME...  write each named logical partition (slot _a) to OUTDIR/NAME.img
"""
import os, struct, sys, uuid

SECTOR = 512


def gpt(f):
    f.seek(SECTOR)
    hdr = f.read(92)
    assert hdr[:8] == b'EFI PART', 'no GPT header'
    entries_lba, count, size = struct.unpack_from('<QII', hdr, 72)
    f.seek(entries_lba * SECTOR)
    table = f.read(count * size)
    parts = {}
    for i in range(count):
        e = table[i * size:(i + 1) * size]
        if e[:16] == b'\0' * 16:
            continue
        first, last = struct.unpack_from('<QQ', e, 32)
        name = e[56:128].decode('utf-16-le').rstrip('\0')
        parts[name] = (first * SECTOR, (last + 1) * SECTOR)
    return parts


def lp(f, base):
    f.seek(base + 4096)
    geo = f.read(4096)
    magic, _, _ = struct.unpack_from('<III', geo, 0)
    assert magic == 0x616C4467, 'bad liblp geometry magic %#x' % magic
    meta_max, slots, lbs = struct.unpack_from('<III', geo, 40)
    f.seek(base + 4096 + 2 * 4096)  # reserved + geometry + backup geometry, then primary slot 0
    head = f.read(meta_max)
    magic, major, minor, hsize = struct.unpack_from('<IHHI', head, 0)
    assert magic == 0x414C5030, 'bad liblp metadata magic %#x' % magic
    tables_size = struct.unpack_from('<I', head, 44)[0]
    desc = struct.unpack_from('<12I', head, 80)
    tables = head[hsize:hsize + tables_size]
    (p_off, p_n, p_sz, e_off, e_n, e_sz, g_off, g_n, g_sz, b_off, b_n, b_sz) = desc
    extents = []
    for i in range(e_n):
        n, ttype, tdata, tsrc = struct.unpack_from('<QIQI', tables, e_off + i * e_sz)
        extents.append((n, ttype, tdata, tsrc))
    out = {}
    for i in range(p_n):
        e = tables[p_off + i * p_sz:p_off + (i + 1) * p_sz]
        name = e[:36].split(b'\0')[0].decode()
        attrs, first, num, grp = struct.unpack_from('<IIII', e, 36)
        ranges = []
        for n, ttype, tdata, tsrc in extents[first:first + num]:
            if ttype == 0:  # LP_TARGET_TYPE_LINEAR
                ranges.append((base + tdata * SECTOR, n * SECTOR))
            else:            # zero-fill extent
                ranges.append((None, n * SECTOR))
        out[name] = ranges
    return (major, minor), out


def main():
    path = sys.argv[1]
    with open(path, 'rb') as f:
        parts = gpt(f)
        sup = parts.get('super') or parts.get('super_a')
        if len(sys.argv) == 2:
            for n, (a, b) in sorted(parts.items(), key=lambda x: x[1][0]):
                print('gpt  %-24s %8.1f MiB @ %d' % (n, (b - a) / 2**20, a))
        assert sup, 'no super partition'
        ver, lps = lp(f, sup[0])
        if len(sys.argv) == 2:
            print('liblp metadata v%d.%d' % ver)
            for n, r in lps.items():
                print('lp   %-24s %8.1f MiB  %d extent(s)' % (n, sum(s for _, s in r) / 2**20, len(r)))
            return
        outdir = sys.argv[2]
        os.makedirs(outdir, exist_ok=True)
        for name in sys.argv[3:]:
            ranges = lps[name]
            dst = os.path.join(outdir, name + '.img')
            with open(dst, 'wb') as o:
                for off, size in ranges:
                    if off is None:
                        o.seek(size, 1)
                        continue
                    f.seek(off)
                    left = size
                    while left:
                        chunk = f.read(min(left, 64 << 20))
                        o.write(chunk)
                        left -= len(chunk)
                o.truncate()
            print('wrote', dst, os.path.getsize(dst))


if __name__ == '__main__':
    main()
