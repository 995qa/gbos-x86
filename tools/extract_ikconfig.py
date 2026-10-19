#!/usr/bin/env python3
"""Extract the .config embedded in a kernel image (CONFIG_IKCONFIG=y).

The config is a gzip stream inside the kernel's ".kernel_config_data" section. In a bzImage that
section is inside the compressed payload, so the LZ4-compressed kernel is unpacked first (the
kernel's own legacy LZ4 format: 4-byte magic, then blocks with a 4-byte header whose top bit marks
an uncompressed block).

  tools/extract_ikconfig.py KERNEL_IMAGE > config
"""
import struct
import sys
import zlib

MAGIC = b"IKCFG_ST"
LZ4_MAGIC = b"\x02\x21\x4c\x18"  # the kernel's legacy LZ4 frame magic


def lz4_block(src: bytes) -> bytes:
    """One LZ4 block (the format the kernel's bzImage uses)."""
    dst = bytearray()
    i = 0
    n = len(src)
    while i < n:
        token = src[i]
        i += 1
        lit = token >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        dst += src[i:i + lit]
        i += lit
        if i >= n:
            break
        offset = src[i] | (src[i + 1] << 8)
        i += 2
        match = token & 0xF
        if match == 15:
            while True:
                b = src[i]
                i += 1
                match += b
                if b != 255:
                    break
        match += 4
        start = len(dst) - offset
        for j in range(match):
            dst.append(dst[start + j])
    return bytes(dst)


def lz4_payload(data: bytes) -> bytes:
    """Unpack the kernel's LZ4-compressed payload (the bzImage's last bytes).

    The format is the one the kernel's own unlz4 reads (lib/decompress_unlz4.c): the magic, then
    chunks (a 4-byte size and the compressed data, each chunk up to 8 MB uncompressed), and the
    total uncompressed size in the last 4 bytes.
    """
    start = data.find(LZ4_MAGIC)
    if start < 0:
        return b""
    out = bytearray()
    i = start + 4
    while i + 4 <= len(data):
        size = struct.unpack_from("<I", data, i)[0]
        if size == 0 or size == 0x184C2102:  # end of the archive / a repeated magic
            i += 4 if size == 0x184C2102 else 0
            if size == 0:
                break
            continue
        if i + 4 + size > len(data):  # the trailing 4 bytes are the uncompressed size
            break
        i += 4
        out += lz4_block(data[i:i + size])
        i += size
    return bytes(out)


def gunzip_at(data: bytes, off: int) -> bytes:
    """The first 4 MB of the gzip stream at off (or whatever could be decompressed)."""
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        return d.decompress(data[off:], 4 << 20)
    except zlib.error:
        return b""


def find_config(data: bytes) -> bytes:
    """The config, in one of the two layouts the kernel uses:

    * "IKCFG_ST" followed by the gzip stream (this kernel: the marker is outside the stream), or
    * a gzip stream whose *content* starts with "IKCFG_ST" (older kernels).
    """
    idx = 0
    while True:
        idx = data.find(MAGIC, idx)
        if idx < 0:
            break
        dec = gunzip_at(data, idx + len(MAGIC))
        if dec.startswith(MAGIC):
            end = dec.find(b"IKCFG_ED", len(MAGIC))
            return dec[len(MAGIC):end if end > 0 else None]
        if dec.startswith(b"#") and b"CONFIG_" in dec[:4096]:
            return dec
        idx += 1
    idx = 0
    while True:
        idx = data.find(b"\x1f\x8b\x08", idx)
        if idx < 0:
            return b""
        dec = gunzip_at(data, idx)
        if dec.startswith(MAGIC):
            end = dec.find(b"IKCFG_ED", len(MAGIC))
            return dec[len(MAGIC):end if end > 0 else None]
        idx += 1


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: extract_ikconfig.py KERNEL_IMAGE", file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    cfg = find_config(data)
    if not cfg:
        # the config sits in the compressed payload
        payload = lz4_payload(data)
        if payload:
            cfg = find_config(payload)
    if not cfg:
        print("no embedded config found", file=sys.stderr)
        return 1
    sys.stdout.write(cfg.decode("utf-8", "replace"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
