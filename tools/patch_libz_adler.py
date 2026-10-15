#!/usr/bin/env python3
"""Make libz's adler32_z always use its scalar path.

  patch_libz_adler.py IN OUT     patch (exit 0 if patched or already patched, 3 if the pattern is not found)
  patch_libz_adler.py --check IN report only

This libz was built with an AVX-VNNI baseline: adler32_z calls an auto-vectorized helper that uses
`{vex} vpdpwssd`, which the i5-8365U traps (about half of all emulated instructions in boot-22).
adler32_z picks the helper like this (Chromium zlib's x86_cpu_enable_simd gate, set from cpuid):

    cmp  $0x40,%rdx ; jae L1                      ; len >= 64
    ...
    L1: cmpl $0,x86_cpu_enable_simd(%rip)         ; 83 3d <disp32> 00
        je   SCALAR                               ; 0f 84 <rel32>      <- the 6 bytes we change
        call HELPER                               ; e8 <rel32>
        mov  %eax,%eax ; jmp RET                  ; 89 c0 eb xx
    SCALAR: mov %edi,%eax ; shr $16,%eax ; movzwl %di,%ecx ; ...      (the plain loop, any length)

The `je` becomes `nop ; jmp SCALAR` (same length, same rel32), so the helper is never called.
"""
import re, shutil, struct, sys

# cmp $0x40,%rdx ; jae rel32 | ... | cmpl $0,disp(%rip) ; je rel32 ; call rel32 ; mov %eax,%eax ; jmp rel8
GATE = re.compile(rb'\x83\x3d....\x00(\x0f\x84(....))(\xe8....)\x89\xc0\xeb.', re.S)
SCALAR_ENTRY = bytes.fromhex('89f8' 'c1e810' '0fb7cf')    # mov %edi,%eax; shr $16,%eax; movzwl %di,%ecx


def load_segments(d):
    phoff, = struct.unpack_from('<Q', d, 0x20)
    es, n = struct.unpack_from('<HH', d, 0x36)
    segs = []
    for i in range(n):
        t, fl, off, va, _, fs, ms, _ = struct.unpack_from('<IIQQQQQQ', d, phoff + i * es)
        if t == 1:
            segs.append((off, va, fs))
    return segs


def va_to_off(segs, va):
    for off, sva, fs in segs:
        if sva <= va < sva + fs:
            return off + va - sva
    return None


def find(d):
    """-> (file offset of the je, state) ; state is 'unpatched' or 'patched' ; raises ValueError if not exactly one gate."""
    if d[:4] != b'\x7fELF' or d[4] != 2 or d[18:20] != b'\x3e\x00':
        raise ValueError('not an x86-64 ELF')
    segs = load_segments(d)
    hits = []
    for m in GATE.finditer(d):
        je = m.start(1)
        rel, = struct.unpack('<i', m.group(2))
        # the call must be preceded (within 0x100 bytes) by `cmp $0x40,%rdx; jae`, i.e. this is adler32_z's >=64 gate
        if d.rfind(b'\x48\x83\xfa\x40\x0f\x83', max(0, je - 0x100), je) < 0:
            continue
        # and the je target must be the scalar entry
        va_next = None
        for off, sva, fs in segs:
            if off <= je < off + fs:
                va_next = sva + (je + 6 - off)
        tgt = va_to_off(segs, va_next + rel) if va_next is not None else None
        if tgt is None or d[tgt:tgt + len(SCALAR_ENTRY)] != SCALAR_ENTRY:
            continue
        hits.append(je)
    # already patched: nop ; jmp rel32 in the same place
    pat = re.compile(rb'\x83\x3d....\x00\x90(\xe9(....))(\xe8....)\x89\xc0\xeb.', re.S)
    done = [m.start(1) - 1 for m in pat.finditer(d)
            if d.rfind(b'\x48\x83\xfa\x40\x0f\x83', max(0, m.start(1) - 0x100), m.start(1)) >= 0]
    if len(hits) == 1 and not done:
        return hits[0], 'unpatched'
    if len(done) == 1 and not hits:
        return done[0], 'patched'
    raise ValueError('expected exactly one adler32_z gate, found %d unpatched / %d patched' % (len(hits), len(done)))


def main():
    if sys.argv[1] == '--check':
        try:
            off, st = find(open(sys.argv[2], 'rb').read())
            print('%s gate at file offset %#x' % (st, off))
            return 0
        except ValueError as e:
            print('no match:', e)
            return 3
    src, dst = sys.argv[1:3]
    d = bytearray(open(src, 'rb').read())
    try:
        off, st = find(bytes(d))
    except ValueError as e:
        print('%s: %s' % (src, e), file=sys.stderr)
        return 3
    if st == 'unpatched':
        assert d[off:off + 2] == b'\x0f\x84'
        d[off:off + 2] = b'\x90\xe9'          # nop ; jmp rel32  (rel32 bytes unchanged: the je ended where the jmp now ends)
        print('%s: adler32_z gate at %#x -> nop; jmp scalar' % (src, off))
    else:
        print('%s: already patched' % src)
    open(dst, 'wb').write(d)
    shutil.copymode(src, dst)
    return 0


sys.exit(main())
