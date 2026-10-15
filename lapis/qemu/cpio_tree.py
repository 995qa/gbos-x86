#!/usr/bin/env python3
"""cpio_tree.py DIR OUT.cpio [prefix-in-archive]: newc cpio of a directory tree (files, dirs, symlinks)."""
import os, stat, sys

def pack(root, extra=()):
    out = bytearray(); ino = [1000]
    def ent(name, mode, data=b'', major=0, minor=0):
        raw = name.encode() + b'\0'
        ino[0] += 1
        f = [ino[0], mode, 0, 0, 1, 0, len(data), 0, 0, major, minor, len(raw), 0]
        out.extend(b'070701' + b''.join(b'%08x' % n for n in f) + raw)
        out.extend(bytes(-len(out) % 4)); out.extend(data); out.extend(bytes(-len(out) % 4))
    for d, dirs, files in os.walk(root):
        dirs.sort()
        rel = os.path.relpath(d, root)
        if rel != '.':
            ent(rel, 0o40755)
        for n in sorted(files + [x for x in dirs if os.path.islink(os.path.join(d, x))]):
            p = os.path.join(d, n); r = os.path.relpath(p, root)
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                ent(r, 0o120777, os.readlink(p).encode())
            elif stat.S_ISREG(st.st_mode):
                ent(r, 0o100000 | (0o755 if st.st_mode & 0o111 else 0o644), open(p, 'rb').read())
    for name, mode, data, ma, mi in extra:
        ent(name, mode, data, ma, mi)
    ent('TRAILER!!!', 0)
    return bytes(out)

if __name__ == '__main__':
    open(sys.argv[2], 'wb').write(pack(sys.argv[1]))
