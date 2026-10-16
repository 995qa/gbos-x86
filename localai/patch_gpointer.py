#!/usr/bin/env python3
"""Patch Google's Magic Pointer app (ContextualCursorPrebuilt.apk) so it works with a Gemini app that only offers text queries.

gPointer's ErrorsKt.<clinit> builds requiredCapabilities = [TEXT_QUERY_CAPABILITY, TEXT_QUERY_WITH_ATTACHMENTS_CAPABILITY] and
refuses to start ("RobinKit capability check failed ... Terminating immediately") unless the Gemini app lists both. Here only
TEXT_QUERY is offered. The patch changes the field loaded for the second entry from ...WITH_ATTACHMENTS to TEXT_QUERY (one byte,
sget-object field index 0x0814 -> 0x0812), so the required list becomes [TEXT_QUERY, TEXT_QUERY].

It is a local compatibility patch to the app's own check; it changes nothing the Gemini app or any server sees. Attachments
(screenshots) will not be offered to the Gemini app, since it doesn't offer them.

The APK is patched in place, same size: the dex's header checksum and SHA-1, and the zip CRC (local header + central directory),
are updated. Google's signature block is left untouched (it no longer verifies; whether the system accepts that is checked on the
device). Refuses to run unless the input is exactly the build this patch was made for.

Usage: patch_gpointer.py ORIGINAL.apk PATCHED.apk
"""
import hashlib
import shutil
import struct
import sys
import zlib

ORIGINAL_SHA256 = "ce8d7e3864905bd68b3398654f7d5be6e6d04ac252b1de8a0d2bc6c59251078e"
DEX_NAME = b"classes11.dex"
# Offset inside classes11.dex of: sget-object v1, RobinIntegrationCapability.<field 0x0814>  (62 01 14 08)
INSN_OFFSET = 0x289870
EXPECT = bytes.fromhex("62011408")
PATCHED = bytes.fromhex("62011208")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    got = sha256(src)
    if got != ORIGINAL_SHA256:
        sys.exit("refusing: %s is not the Magic Pointer build this patch was made for\n  sha256 %s\n  expected %s" % (src, got, ORIGINAL_SHA256))
    shutil.copyfile(src, dst)
    with open(dst, "r+b") as f:
        # The zip's index (EOCD + central directory) is at the end; read just enough of the file to locate the entry.
        f.seek(0, 2)
        size = f.tell()
        f.seek(size - (16 << 20))
        tail_base = size - (16 << 20)
        tail = f.read()
        # find_entry works on offsets relative to the buffer start, so rebase.
        eocd = tail.rfind(b"PK\x05\x06")
        n_entries, cd_size, cd_off = struct.unpack("<HII", tail[eocd + 10:eocd + 20])
        cd = tail[cd_off - tail_base:cd_off - tail_base + cd_size]
        lho = cdp = usize = None
        p = 0
        for _ in range(n_entries):
            flags, method = struct.unpack("<HH", cd[p + 8:p + 12])
            nlen, elen, clen = struct.unpack("<HHH", cd[p + 28:p + 34])
            if cd[p + 46:p + 46 + nlen] == DEX_NAME:
                if method != 0 or flags & 8:
                    sys.exit("classes11.dex is not a plainly stored entry")
                usize = struct.unpack("<I", cd[p + 24:p + 28])[0]
                lho = struct.unpack("<I", cd[p + 42:p + 46])[0]
                cdp = cd_off + p
                break
            p += 46 + nlen + elen + clen
        if lho is None:
            sys.exit("classes11.dex not found")
        f.seek(lho)
        lh = f.read(30)
        assert lh[:4] == b"PK\x03\x04", "bad local header"
        nlen, elen = struct.unpack("<HH", lh[26:30])
        data_off = lho + 30 + nlen + elen

        f.seek(data_off)
        dex = bytearray(f.read(usize))
        if bytes(dex[INSN_OFFSET:INSN_OFFSET + 4]) != EXPECT:
            sys.exit("unexpected bytes at the patch site: %s" % bytes(dex[INSN_OFFSET:INSN_OFFSET + 4]).hex())
        dex[INSN_OFFSET:INSN_OFFSET + 4] = PATCHED
        # dex header: checksum (adler32 of bytes 12..end) at 8, SHA-1 signature (of bytes 32..end) at 12.
        dex[12:32] = hashlib.sha1(bytes(dex[32:])).digest()
        struct.pack_into("<I", dex, 8, zlib.adler32(bytes(dex[12:])) & 0xFFFFFFFF)
        crc = zlib.crc32(bytes(dex)) & 0xFFFFFFFF

        f.seek(data_off)
        f.write(dex)
        f.seek(lho + 14)
        f.write(struct.pack("<I", crc))
        f.seek(cdp + 16)
        f.write(struct.pack("<I", crc))
    print("patched %s -> %s (classes11.dex: %d bytes at +0x%x, crc %08x)" % (src, dst, usize, INSN_OFFSET, crc))
    print("sha256 %s" % sha256(dst))


if __name__ == "__main__":
    main()
