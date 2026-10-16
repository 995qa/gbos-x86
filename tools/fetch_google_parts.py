#!/usr/bin/env python3
"""fetch_google_parts.py RECOVERY.zip OUTDIR [NAME ...]

Pull the Android logical partitions gbOS86 needs (default: system_a vendor_a product_a system_ext_a system_dlkm_a
vendor_dlkm_a) out of Google's recovery.zip WITHOUT unpacking its 19 GB raw disk image: the zip entry is decompressed as
a stream, the GPT and the liblp (super) metadata are read from the first ~0.8 GB, and only the byte ranges of the
wanted partitions are written, to OUTDIR/NAME.img. Peak extra disk use is just the partitions (~8 GB). Stops reading as
soon as the last wanted byte has been written.
"""
import os, sys, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lp_extract import gpt, lp

DEFAULT = ['system_a', 'vendor_a', 'product_a', 'system_ext_a', 'system_dlkm_a', 'vendor_dlkm_a']
CHUNK = 8 << 20


class ForwardFile:
    """Read-only file over a stream: seek() may only move forward (it discards bytes), which is all gpt()/lp() need."""

    def __init__(self, stream):
        self.s, self.pos = stream, 0

    def tell(self):
        return self.pos

    def seek(self, off, whence=0):
        assert whence == 0, 'only absolute seeks'
        if off < self.pos:
            raise ValueError('stream cannot seek backwards (%d < %d)' % (off, self.pos))
        self.skip(off - self.pos)
        return self.pos

    def skip(self, n):
        while n:
            b = self.s.read(min(n, CHUNK))
            if not b:
                raise EOFError('disk image ended early')
            self.pos += len(b)
            n -= len(b)

    def read(self, n):
        b = self.s.read(n)
        self.pos += len(b)
        return b


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    zpath, outdir = sys.argv[1], sys.argv[2]
    names = sys.argv[3:] or DEFAULT
    zf = zipfile.ZipFile(zpath)
    big = max(zf.infolist(), key=lambda i: i.file_size)
    print('disk image in zip: %s (%.1f GB uncompressed)' % (big.filename, big.file_size / 1e9), flush=True)
    f = ForwardFile(zf.open(big))
    parts = gpt(f)
    sup = parts.get('super') or parts.get('super_a')
    if not sup:
        sys.exit('no super partition in the disk image')
    ver, lps = lp(f, sup[0])
    missing = [n for n in names if n not in lps]
    if missing:
        sys.exit('partitions not found in super: %s (have: %s)' % (missing, ', '.join(sorted(lps))))
    os.makedirs(outdir, exist_ok=True)
    jobs = []  # (disk offset, size, name, offset inside the partition)
    outs = {}
    for n in names:
        dst = os.path.join(outdir, n + '.img')
        outs[n] = open(dst, 'wb')
        pos = 0
        for off, size in lps[n]:
            if off is not None:
                jobs.append((off, size, n, pos))
            pos += size
        outs[n].truncate(pos)  # sparse until written; zero-fill extents stay zero
    jobs.sort()
    for a, b in zip(jobs, jobs[1:]):
        if a[0] + a[1] > b[0]:
            sys.exit('overlapping extents in super metadata: %s' % (a, b))
    total = sum(j[1] for j in jobs)
    done = 0
    for off, size, n, dpos in jobs:
        f.seek(off)
        o = outs[n]
        o.seek(dpos)
        left = size
        while left:
            b = f.read(min(left, CHUNK))
            if not b:
                sys.exit('disk image ended inside %s' % n)
            o.write(b)
            left -= len(b)
            done += len(b)
        print('\r%5.1f%%  %s' % (100 * done / total, n), end='', flush=True)
    print()
    for n, o in outs.items():
        o.close()
        print('wrote %s/%s.img (%.1f MB)' % (outdir, n, os.path.getsize(os.path.join(outdir, n + '.img')) / 1e6))


if __name__ == '__main__':
    main()
