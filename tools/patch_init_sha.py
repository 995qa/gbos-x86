#!/usr/bin/env python3
"""Redirect init's SHA-NI SHA-256 block function to the scalar one with the same signature.

  patch_init_sha.py IN OUT

Both take (state=rdi, data=rsi, nblocks=rdx); the scalar one is never called directly in this
build, and every SHA-NI instruction in the binary lives inside the shaext function.
"""
import struct, sys

SHAEXT = 0x28e880   # sha256 block fn using sha256rnds2 (entry: lea K-table(%rip), %rcx)
SCALAR = 0x28d700   # same-signature scalar fn (entry: mov %rsp,%rax; push %rbx)
EXPECT_SHAEXT = bytes.fromhex('488d0d')            # leaq disp32(%rip), %rcx
EXPECT_SCALAR = bytes.fromhex('4889e0' '53' '55')  # mov %rsp,%rax; push %rbx; push %rbp


def v2o(data, va):
    phoff, = struct.unpack_from('<Q', data, 0x20)
    phentsize, phnum = struct.unpack_from('<HH', data, 0x36)
    for i in range(phnum):
        t, _, off, vaddr, _, filesz, _, _ = struct.unpack_from('<IIQQQQQQ', data, phoff + i * phentsize)
        if t == 1 and vaddr <= va < vaddr + filesz:
            return off + va - vaddr
    raise SystemExit('vaddr %#x not in any PT_LOAD' % va)


def main():
    src, dst = sys.argv[1:3]
    d = bytearray(open(src, 'rb').read())
    a, b = v2o(d, SHAEXT), v2o(d, SCALAR)
    assert d[a:a + 3] == EXPECT_SHAEXT, d[a:a + 8].hex()
    assert d[b:b + 5] == EXPECT_SCALAR, d[b:b + 8].hex()
    rel = SCALAR - (SHAEXT + 5)
    d[a:a + 5] = b'\xe9' + struct.pack('<i', rel)
    open(dst, 'wb').write(d)
    print('patched %#x -> jmp %#x (file off %#x)' % (SHAEXT, SCALAR, a))


main()
