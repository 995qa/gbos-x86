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
device).

The patch site is found by structure, not by address, so it survives a new Google build: in every stored classes*.dex it
looks for the class ...ErrorsKt, its <clinit>, and the one `sget-object` there that loads the field named
TEXT_QUERY_WITH_ATTACHMENTS_CAPABILITY (an enum constant of RobinIntegrationCapability); that index is replaced by the index of the
TEXT_QUERY_CAPABILITY constant of the same class. It refuses to patch unless there is exactly one such site. The sha256 below is only
the build the patch was first made on (reported, no longer required).

Usage: patch_gpointer.py ORIGINAL.apk PATCHED.apk
       patch_gpointer.py --check ORIGINAL.apk       report the patch site, change nothing
"""
import hashlib
import re
import shutil
import struct
import sys
import zlib

KNOWN_SHA256 = "ce8d7e3864905bd68b3398654f7d5be6e6d04ac252b1de8a0d2bc6c59251078e"   # first build (classes11.dex +0x289870)
HOLDER_CLASS = b"ErrorsKt;"
FIELD_ATT = b"TEXT_QUERY_WITH_ATTACHMENTS_CAPABILITY"
FIELD_TEXT = b"TEXT_QUERY_CAPABILITY"
SGET_OBJECT = 0x62


def uleb(d, p):
    r = s = 0
    while True:
        b = d[p]
        p += 1
        r |= (b & 0x7F) << s
        if not b & 0x80:
            return r, p
        s += 7


def find_site(dex):
    """-> (offset of the sget-object instruction, field index to load instead), or None if this dex has no such site."""
    if dex[:4] != b"dex\n":
        return None
    u32 = lambda o: struct.unpack_from("<I", dex, o)[0]
    n_str, o_str, n_typ, o_typ, _, _, n_fld, o_fld, n_mth, o_mth, n_cls, o_cls = struct.unpack_from("<IIIIIIIIIIII", dex, 0x38)

    def string(i):
        p = u32(o_str + 4 * i)
        _, p = uleb(dex, p)
        return bytes(dex[p:dex.index(b"\0", p)])

    def type_name(i):
        return string(u32(o_typ + 4 * i))
    fields = [struct.unpack_from("<HHI", dex, o_fld + 8 * i) for i in range(n_fld)]   # class_idx, type_idx, name_idx
    att = [i for i, f in enumerate(fields) if string(f[2]) == FIELD_ATT]
    if not att:
        return None
    sites = []
    for ci in range(n_cls):
        cdef = struct.unpack_from("<IIIIIIII", dex, o_cls + 32 * ci)
        if not type_name(cdef[0]).endswith(HOLDER_CLASS) or not cdef[6]:
            continue
        p = cdef[6]
        n_sf, n_if, n_dm, n_vm = [0] * 4
        n_sf, p = uleb(dex, p)
        n_if, p = uleb(dex, p)
        n_dm, p = uleb(dex, p)
        n_vm, p = uleb(dex, p)
        for _ in range(n_sf + n_if):
            _, p = uleb(dex, p)
            _, p = uleb(dex, p)
        midx = 0
        for _ in range(n_dm + n_vm):
            d, p = uleb(dex, p)
            _, p = uleb(dex, p)
            code_off, p = uleb(dex, p)
            midx += d
            if not code_off:
                continue
            mname = string(struct.unpack_from("<HHI", dex, o_mth + 8 * midx)[2])
            if mname != b"<clinit>":
                continue
            insns_size = u32(code_off + 12)
            base = code_off + 16
            for u in range(0, insns_size * 2 - 3, 2):
                if dex[base + u] == SGET_OBJECT and struct.unpack_from("<H", dex, base + u + 2)[0] in att:
                    sites.append(base + u)
    if not sites:
        return None
    if len(sites) != 1:
        raise ValueError("%d candidate sites in one dex" % len(sites))
    off = sites[0]
    fidx = struct.unpack_from("<H", dex, off + 2)[0]
    cls = fields[fidx][0]
    text = [i for i, f in enumerate(fields) if f[0] == cls and string(f[2]) == FIELD_TEXT]
    if len(text) != 1:
        raise ValueError("expected one %s field next to %s, found %d" % (FIELD_TEXT.decode(), FIELD_ATT.decode(), len(text)))
    return off, text[0]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def zip_entries(f):
    """-> [(name, local header offset, central dir entry offset, method, flags, size)] from the zip index at the end of the file."""
    f.seek(0, 2)
    size = f.tell()
    tail_base = max(0, size - (16 << 20))
    f.seek(tail_base)
    tail = f.read()
    eocd = tail.rfind(b"PK\x05\x06")
    n_entries, cd_size, cd_off = struct.unpack("<HII", tail[eocd + 10:eocd + 20])
    cd = tail[cd_off - tail_base:cd_off - tail_base + cd_size]
    out, p = [], 0
    for _ in range(n_entries):
        flags, method = struct.unpack("<HH", cd[p + 8:p + 12])
        usize, = struct.unpack("<I", cd[p + 24:p + 28])
        nlen, elen, clen = struct.unpack("<HHH", cd[p + 28:p + 34])
        lho, = struct.unpack("<I", cd[p + 42:p + 46])
        out.append((cd[p + 46:p + 46 + nlen], lho, cd_off + p, method, flags, usize))
        p += 46 + nlen + elen + clen
    return out


def locate(f):
    """-> (dex name, data offset, dex bytes, insn offset, new field index, local header offset, central entry offset)."""
    found = []
    for name, lho, cdp, method, flags, usize in zip_entries(f):
        if not re.fullmatch(rb"classes\d*\.dex", name):
            continue
        if method != 0 or flags & 8:
            sys.exit("%s is not a plainly stored entry (compressed dex: not supported)" % name.decode())
        f.seek(lho)
        lh = f.read(30)
        assert lh[:4] == b"PK\x03\x04", "bad local header"
        nlen, elen = struct.unpack("<HH", lh[26:30])
        data_off = lho + 30 + nlen + elen
        f.seek(data_off)
        dex = f.read(usize)
        try:
            site = find_site(dex)
        except ValueError as e:
            sys.exit("%s: %s" % (name.decode(), e))
        if site:
            found.append((name.decode(), data_off, dex, site[0], site[1], lho, cdp))
    if len(found) != 1:
        sys.exit("expected exactly one %s load in a %s.<clinit>, found it in %d dex files. The Magic Pointer changed: look at\n"
                 "  ErrorsKt.requiredCapabilities in jadx and extend find_site()" % (FIELD_ATT.decode(), HOLDER_CLASS.decode(), len(found)))
    return found[0]


def main():
    check = len(sys.argv) == 3 and sys.argv[1] == "--check"
    if not check and len(sys.argv) != 3:
        sys.exit(__doc__)
    src = sys.argv[2] if check else sys.argv[1]
    known = " (the build this patch was first made on)" if sha256(src) == KNOWN_SHA256 else ""
    with open(src, "rb") as f:
        name, data_off, dex, off, fidx, lho, cdp = locate(f)
    old = bytes(dex[off:off + 4])
    new = old[:2] + struct.pack("<H", fidx)
    print("%s%s: patch site %s +0x%x  %s -> %s" % (src, known, name, off, old.hex(), new.hex()))
    if check:
        return
    dst = sys.argv[2]
    shutil.copyfile(src, dst)
    dex = bytearray(dex)
    dex[off:off + 4] = new
    # dex header: checksum (adler32 of bytes 12..end) at 8, SHA-1 signature (of bytes 32..end) at 12.
    dex[12:32] = hashlib.sha1(bytes(dex[32:])).digest()
    struct.pack_into("<I", dex, 8, zlib.adler32(bytes(dex[12:])) & 0xFFFFFFFF)
    crc = zlib.crc32(bytes(dex)) & 0xFFFFFFFF
    with open(dst, "r+b") as f:
        f.seek(data_off)
        f.write(dex)
        f.seek(lho + 14)
        f.write(struct.pack("<I", crc))
        f.seek(cdp + 16)
        f.write(struct.pack("<I", crc))
    print("patched %s -> %s (%s: %d bytes, crc %08x)" % (src, dst, name, len(dex), crc))
    print("sha256 %s" % sha256(dst))


if __name__ == "__main__":
    main()
