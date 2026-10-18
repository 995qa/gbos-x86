#!/usr/bin/env python3
"""Make libkm_compat serve its software KeyMint for every security level.

  patch_km_compat.py IN OUT     patch (exit 0 if patched or already patched, 3 if the pattern is not found)
  patch_km_compat.py --check IN report only

Trusty/StrongBox KeyMint need Google's security chip, so keystore2 must get a software KeyMint for every level it asks
for. KeystoreCompatService::getKeyMintDevice(SecurityLevel level, shared_ptr<IKeyMintDevice>*) is exported, and the first
thing it does with `level` (edx) is copy it into a callee-saved register:

    push rbp ... sub $0x58,%rsp ; mov %rcx,-0x80(%rbp)
    mov  %edx,%r15d                   <- 41 89 d7   (this build)

The copy becomes `xor %r15d,%r15d` (SecurityLevel::SOFTWARE = 0), same length, so every later use of the level sees
SOFTWARE. The register depends on the compiler's allocation, so the patch looks for *the first* `mov %edx,%reg32` in the
function's prologue instead of fixed bytes, and anchors on the exported symbol instead of an address. Failing to find
exactly one such copy exits 3: look at `objdump -d` of the function and extend the pattern.
"""
import re, shutil, struct, sys

SYM = re.compile(rb'^_ZN21KeystoreCompatService16getKeyMintDeviceE')
WINDOW = 0x60                                   # bytes of prologue searched
# mov %edx,%r8d-r15d : 41 89 (d0|d8|..|d7+8 -> modrm 0xd0+rm), mov %edx,%eax-%edi : 89 (d0+rm)
MOV_R8 = re.compile(rb'\x41\x89([\xd0-\xd7])')
MOV_LO = re.compile(rb'(?<![\x40-\x4f])\x89([\xd0-\xd7])')


def elf_symbols(d):
    """-> [(name, file offset)] for defined dynamic function symbols."""
    if d[:4] != b'\x7fELF' or d[4] != 2 or d[18:20] != b'\x3e\x00':
        raise ValueError('not an x86-64 ELF')
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum = struct.unpack_from('<HH', d, 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    out = []
    for name, typ, flags, addr, off, size, link, info, align, entsize in secs:
        if typ != 11:                           # SHT_DYNSYM
            continue
        stroff = secs[link][4]
        for i in range(size // 24):
            st_name, st_info, _, st_shndx, st_value, st_size = struct.unpack_from('<IBBHQQ', d, off + i * 24)
            if st_shndx == 0 or (st_info & 0xf) != 2:
                continue
            end = d.index(b'\0', stroff + st_name)
            out.append((bytes(d[stroff + st_name:end]), st_value, st_size))
    return out, secs


def va_to_off(d, secs, va):
    for name, typ, flags, addr, off, size, *_ in secs:
        if typ == 1 and flags & 4 and addr <= va < addr + size:    # PROGBITS + EXECINSTR
            return off + va - addr
    raise ValueError('symbol address %#x is not in an executable section' % va)


def find(d):
    """-> (offset, patched?, length, new bytes). Raises ValueError unless there is exactly one candidate."""
    syms, secs = elf_symbols(d)
    fns = [(n, v) for n, v, _ in syms if SYM.match(n)]
    if len(fns) != 1:
        raise ValueError('expected one KeystoreCompatService::getKeyMintDevice symbol, found %d' % len(fns))
    start = va_to_off(d, secs, fns[0][1])
    win = bytes(d[start:start + WINDOW])
    cands = []
    for m in MOV_R8.finditer(win):
        reg = 8 + (m.group(1)[0] & 7)
        cands.append((m.start(), 3, bytes([0x45, 0x31, 0xc0 | ((reg & 7) << 3) | (reg & 7)])))
    for m in MOV_LO.finditer(win):
        reg = m.group(1)[0] & 7
        cands.append((m.start(), 2, bytes([0x31, 0xc0 | (reg << 3) | reg]) ))
    cands.sort()
    if cands:
        pos, n, new = cands[0]
        if n == 2:
            new += b'\x90'
        return start + pos, False, 3 if n == 3 else 2, new
    # already patched: the first thing after the prologue is an xor of a register with itself
    for m in re.finditer(rb'\x45\x31([\xc0\xc9\xd2\xdb\xe4\xed\xf6\xff])', win):
        return start + m.start(), True, 3, bytes(m.group(0))
    raise ValueError('no `mov %edx,%reg` in the first %#x bytes of getKeyMintDevice' % WINDOW)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == '--check':
        try:
            off, done, n, new = find(open(sys.argv[2], 'rb').read())
            print('%s at file offset %#x' % ('patched' if done else 'unpatched', off))
            return 0
        except ValueError as e:
            print('no match:', e)
            return 3
    src, dst = sys.argv[1:3]
    d = bytearray(open(src, 'rb').read())
    try:
        off, done, n, new = find(bytes(d))
    except ValueError as e:
        print('%s: %s' % (src, e), file=sys.stderr)
        return 3
    if done:
        print('%s: already patched' % src)
    else:
        print('%s: getKeyMintDevice level copy at %#x: %s -> %s' % (src, off, bytes(d[off:off + n]).hex(), new.hex()))
        d[off:off + n] = new
    open(dst, 'wb').write(d)
    shutil.copymode(src, dst)
    return 0


if __name__ == '__main__':
    sys.exit(main())
