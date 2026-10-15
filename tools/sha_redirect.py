#!/usr/bin/env python3
"""Redirect SHA-NI SHA-256 block functions to their scalar siblings (same ABI: rdi=state, rsi=data, rdx=nblocks).

  sha_redirect.py IN OUT          patch one ELF; exit 0 if patched or nothing to do, 3 if SHA-NI found but unmatched
  sha_redirect.py --scan IN       report only

OpenSSL/BoringSSL layout: the shaext function starts `lea K256(%rip),%rcx; movdqu (%rdi),%xmm1; movdqu 16(%rdi),%xmm2`
and the scalar one (`sha256_block_data_order_nohw`) starts `mov %rsp,%rax; push rbx,rbp,r12-r15; shl $4,%rdx;
sub $0x60,%rsp; lea (%rsi,%rdx,4),%rdx; and $-64,%rsp`. Every SHA-NI instruction must lie inside a function we
redirect, otherwise the file is reported unmatched and left alone.
"""
import re, shutil, struct, subprocess, sys

OBJDUMP = '/usr/bin/objdump'
SHA_RE = re.compile(r'\bsha(1rnds4|1nexte|1msg1|1msg2|256rnds2|256msg1|256msg2)\b')
# entry of shaext: lea disp32(%rip),%rcx ; movdqu (%rdi),%xmm1 ; movdqu 0x10(%rdi),%xmm2
FAMILIES = {
    # name: (shaext prologue, scalar prologue)
    '256': (re.compile(rb'\x48\x8d\x0d....\xf3\x0f\x6f\x0f\xf3\x0f\x6f\x57\x10', re.S),
            bytes.fromhex('4889e0' '53' '55' '4154' '4155' '4156' '4157' '48c1e204' '4883ec60' '488d1496' '4883e4c0')),
    # sha1: movdqu (%rdi),%xmm0 ; movd 0x10(%rdi),%xmm1
    '1': (re.compile(rb'\xf3\x0f\x6f\x07\x66\x0f\x6e\x4f\x10', re.S),
          bytes.fromhex('4889e0' '53' '55' '4154' '4155' '4156' '4989f8' '4883ec48' '4989f1' '4883e4c0' '4989d2')),
}


def load_segments(d):
    phoff, = struct.unpack_from('<Q', d, 0x20)
    es, n = struct.unpack_from('<HH', d, 0x36)
    segs = []
    for i in range(n):
        t, fl, off, va, _, fs, ms, _ = struct.unpack_from('<IIQQQQQQ', d, phoff + i * es)
        if t == 1:
            segs.append((off, va, fs, fl))
    return segs


def sha_addrs(path):
    out = subprocess.run([OBJDUMP, '-d', '--no-show-raw-insn', path], capture_output=True, text=True, errors='replace').stdout
    addrs = []
    for line in out.splitlines():
        if SHA_RE.search(line):
            m = re.match(r'\s*([0-9a-f]+):', line)
            if m:
                addrs.append((int(m.group(1), 16), '1' if 'sha1' in line else '256'))
    return addrs


def plan(path):
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fELF' or d[4] != 2:
        return d, [], [], 'not-elf64'
    segs = load_segments(d)
    addrs = sha_addrs(path)
    if not addrs:
        return d, [], [], 'none'

    def v2o(va):
        for off, sva, fs, fl in segs:
            if sva <= va < sva + fs:
                return off + va - sva
        return None
    entries = {}
    unmatched = []
    for a, fam in addrs:
        o = v2o(a)
        # nearest shaext prologue before the instruction, within 0x1000 bytes
        best = None
        for m in FAMILIES[fam][0].finditer(d, max(0, o - 0x1000), o):
            best = m.start()
        if best is None:
            unmatched.append(a)
        else:
            entries[best] = fam
    patches = []
    for eo in sorted(entries):
        # scalar sibling: last occurrence of the prologue before eo, within 0x8000
        lo = max(0, eo - 0x8000)
        so = d.rfind(FAMILIES[entries[eo]][1], lo, eo)
        if so < 0:
            unmatched.append(eo)
            continue
        patches.append((eo, so))
    return d, patches, unmatched, 'ok'


def main():
    if sys.argv[1] == '--scan':
        _, patches, un, st = plan(sys.argv[2])
        print(st, 'patches=%d unmatched=%d' % (len(patches), len(un)))
        return 0
    src, dst = sys.argv[1:3]
    d, patches, un, st = plan(src)
    if st != 'ok':
        if src != dst:
            shutil.copyfile(src, dst)
        return 0
    d = bytearray(d)
    for eo, so in patches:
        d[eo:eo + 5] = b'\xe9' + struct.pack('<i', so - (eo + 5))
    open(dst, 'wb').write(d)
    shutil.copymode(src, dst)
    print('%s: redirected %d shaext function(s)%s' % (src, len(patches), ', %d UNMATCHED' % len(un) if un else ''))
    return 3 if un else 0


sys.exit(main())
