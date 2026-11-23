#!/usr/bin/env python3
"""Generate patch variants of tailscale-ipn.exe for bisecting the crash."""
import os
import re
import struct
import sys

SRC = r"C:\Program Files\Tailscale\tailscale-ipn.exe"
OUT = r"D:\tailscale\work\variants"


def load():
    return bytearray(open(SRC, "rb").read())


def patch_pe(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    opt = pe + 24
    assert struct.unpack_from("<H", data, opt)[0] == 0x20B
    struct.pack_into("<H", data, opt + 40, 6)
    struct.pack_into("<H", data, opt + 42, 1)
    struct.pack_into("<H", data, opt + 48, 6)
    struct.pack_into("<H", data, opt + 50, 1)
    struct.pack_into("<I", data, opt + 64, 0)


def patch_nops(data):
    wingoes = re.compile(
        rb"\x83\x78\x04\x0a\x0f\x85....\x83\x78\x08\x00\x0f\x85....", re.S)
    hits = list(wingoes.finditer(data))
    assert len(hits) == 1, len(hits)
    off = hits[0].start()
    data[off + 4:off + 10] = b"\x90" * 6
    data[off + 14:off + 20] = b"\x90" * 6


def patch_flags(data):
    rt_flag = bytes.fromhex("48c78424c000000000080000")
    rt_hits = [m.start() for m in re.finditer(re.escape(rt_flag), data)]
    assert len(rt_hits) == 2, len(rt_hits)
    rt_off = rt_hits[0] + 8
    data[rt_off:rt_off + 4] = b"\x00\x0a\x00\x00"

    sys_flag = bytes.fromhex("48c744243000080000")
    sys_hits = [m.start() for m in re.finditer(re.escape(sys_flag), data)]
    assert len(sys_hits) == 1, len(sys_hits)
    sys_off = sys_hits[0] + 5
    data[sys_off:sys_off + 4] = b"\x00\x0a\x00\x00"


def patch_rename(data):
    old = b"bcryptprimitives.dll"
    new = b"tsbcryptprng_win.dll"
    assert len(old) == len(new)
    pad = len(old) - len(new)

    utf16_old = b"".join(bytes((c, 0)) for c in old)
    utf16_new = b"".join(bytes((c, 0)) for c in new) + b"\0\0" * pad
    uthits = [m.start() for m in re.finditer(re.escape(utf16_old), data)]
    assert len(uthits) == 1, len(uthits)
    data[uthits[0]:uthits[0] + len(utf16_old)] = utf16_new

    ahits = [m.start() for m in re.finditer(re.escape(old), data)]
    marker = b"goroutine stacks:"
    cands = [h for h in ahits
             if data[h + len(old):h + len(old) + len(marker)] == marker]
    assert len(cands) == 1, len(cands)
    data[cands[0]:cands[0] + len(old)] = new + b"\0" * pad


def main():
    os.makedirs(OUT, exist_ok=True)
    variants = {
        "v0_stock": [],
        "v1_pe": [patch_pe],
        "v2_pe_nop": [patch_pe, patch_nops],
        "v3_pe_nop_flags": [patch_pe, patch_nops, patch_flags],
        "v4_pe_nop_flags_rename": [patch_pe, patch_nops, patch_flags, patch_rename],
        "v5_pe_rename": [patch_pe, patch_rename],
        "v6_nop": [patch_nops],
        "v7_flags": [patch_flags],
        "v8_rename": [patch_rename],
    }
    for name, fns in variants.items():
        data = load()
        for fn in fns:
            fn(data)
        path = os.path.join(OUT, name + ".exe")
        open(path, "wb").write(data)
        print(name, len(data), "->", path)


if __name__ == "__main__":
    main()
