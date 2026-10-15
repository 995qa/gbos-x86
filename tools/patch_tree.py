#!/usr/bin/env python3
"""patch_tree.py TREE : apply the Skylake-compat rewrites in place to every x86-64 ELF under TREE.

Currently: SHA-NI SHA-1/SHA-256 block functions -> scalar siblings (tools/sha_redirect.py).
Run on a tree extracted with xattrs/ownership intact (see tools/repack_erofs.sh).
"""
import os, re, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
SHA_BYTES = re.compile(rb'\x0f\x38[\xc8-\xcd]|\x0f\x3a\xcc')


def is_elf64_x86(p):
    try:
        with open(p, 'rb') as f:
            h = f.read(20)
    except OSError:
        return False
    return h[:4] == b'\x7fELF' and h[4] == 2 and h[18:20] == b'\x3e\x00'


def main():
    tree = sys.argv[1]
    n = patched = bad = 0
    for d, _, names in os.walk(tree):
        for name in names:
            p = os.path.join(d, name)
            rel = os.path.relpath(p, tree)
            if rel.startswith('etc/vm/'):    # signed guest payloads (Trusty), not host userspace
                continue
            if os.path.islink(p) or not os.path.isfile(p) or not is_elf64_x86(p):
                continue
            n += 1
            data = open(p, 'rb').read()
            if not SHA_BYTES.search(data):
                continue
            r = subprocess.run([sys.executable, '-I', os.path.join(here, 'sha_redirect.py'), p, p + '.new'],
                               capture_output=True, text=True)
            if os.path.exists(p + '.new'):
                new = open(p + '.new', 'rb').read()
                os.remove(p + '.new')
                if new != data:                  # overwrite in place: keeps inode, owner, mode and xattrs
                    with open(p, 'r+b') as f:
                        f.write(new)
            if r.stdout.strip():
                print(os.path.relpath(p, tree), '->', r.stdout.strip().split(': ', 1)[-1])
                patched += 1
            if r.returncode == 3:
                bad += 1
    print('scanned %d ELF files, patched %d, with unmatched SHA-NI: %d' % (n, patched, bad))


if __name__ == '__main__':
    main()
