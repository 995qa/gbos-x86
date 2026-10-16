#!/usr/bin/env python3
"""Self-test for fetch_google_parts.py: builds a small fake recovery.zip (GPT + liblp 'super' with two extents for
one partition and a zero-fill extent) and checks the extracted partition bytes. No network, a few MB."""
import hashlib, os, struct, subprocess, sys, tempfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
S = 512


def gpt_disk(total, super_off, super_len):
    d = bytearray(total)
    d[S:S + 8] = b'EFI PART'
    struct.pack_into('<QII', d, S + 72, 2, 128, 128)
    e = bytearray(128)
    struct.pack_into('<QQ', e, 32, super_off // S, (super_off + super_len) // S - 1)
    e[0:16] = b'\x01' * 16
    e[56:56 + 12] = 'super'.encode('utf-16-le')
    d[2 * S:2 * S + 128] = e
    return d


def liblp(base, d, parts):
    """parts: {name: [(target_sector_in_super, nsectors) or ('zero', nsectors)]}"""
    struct.pack_into('<III', d, base + 4096, 0x616C4467, 52, 0)
    struct.pack_into('<III', d, base + 4096 + 40, 65536, 1, 4096)
    ents, exts = b'', b''
    first = 0
    for name, rs in parts.items():
        ents += name.encode().ljust(36, b'\0') + struct.pack('<IIII', 0, first, len(rs), 0)
        for r in rs:
            exts += struct.pack('<QIQI', r[1], 0 if r[0] != 'zero' else 1, 0 if r[0] == 'zero' else r[0], 0)
        first += len(rs)
    p_sz, e_sz = 52, 24
    tables = ents + exts
    head = bytearray(128)
    struct.pack_into('<IHHI', head, 0, 0x414C5030, 10, 0, 128)
    struct.pack_into('<I', head, 44, len(tables))
    struct.pack_into('<12I', head, 80, 0, len(parts), p_sz, len(ents), first, e_sz, 0, 0, 0, 0, 0, 0)
    d[base + 4096 + 8192:base + 4096 + 8192 + len(head) + len(tables)] = bytes(head) + tables


def main():
    with tempfile.TemporaryDirectory() as t:
        total, sup_off, sup_len = 48 << 20, 1 << 20, 40 << 20
        d = gpt_disk(total, sup_off, sup_len)
        liblp(sup_off, d, {'system_a': [(2048, 2048), (8192, 1024)], 'vendor_a': [(4096, 512), ('zero', 512)], 'system_b': [(16384, 4096)]})
        rnd = os.urandom
        a1, a2, v1 = rnd(2048 * S), rnd(1024 * S), rnd(512 * S)
        d[sup_off + 2048 * S:sup_off + 4096 * S] = a1
        d[sup_off + 8192 * S:sup_off + 9216 * S] = a2
        d[sup_off + 4096 * S:sup_off + 4608 * S] = v1
        z = os.path.join(t, 'recovery.zip')
        with zipfile.ZipFile(z, 'w', zipfile.ZIP_DEFLATED) as zf:
            zf.writestr('disk.bin', bytes(d))
        subprocess.check_call([sys.executable, os.path.join(HERE, 'fetch_google_parts.py'), z, os.path.join(t, 'out'), 'system_a', 'vendor_a'])
        sa = open(os.path.join(t, 'out/system_a.img'), 'rb').read()
        va = open(os.path.join(t, 'out/vendor_a.img'), 'rb').read()
        assert sa == a1 + a2, 'system_a mismatch'
        assert va == v1 + bytes(512 * S), 'vendor_a mismatch'
        print('TEST PASS (system_a 2 extents, vendor_a with zero extent)', hashlib.sha256(sa).hexdigest()[:12])


main()
