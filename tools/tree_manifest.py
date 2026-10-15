#!/usr/bin/env python3
"""tree_manifest.py TREE : print path, type, mode, uid, gid, xattrs (hex), symlink target for every entry (no sizes/times)."""
import os, stat, sys
root = sys.argv[1]
def line(p):
    st = os.lstat(p)
    try:
        xa = ','.join('%s=%s' % (k, os.getxattr(p, k, follow_symlinks=False).hex()) for k in sorted(os.listxattr(p, follow_symlinks=False)))
    except OSError:
        xa = '?'
    tgt = os.readlink(p) if stat.S_ISLNK(st.st_mode) else ''
    return '%s %o %d %d %s %s' % (os.path.relpath(p, root), st.st_mode, st.st_uid, st.st_gid, xa, tgt)
out = []
for d, dirs, files in os.walk(root):
    for n in dirs + files:
        out.append(line(os.path.join(d, n)))
print('\n'.join(sorted(out)))
