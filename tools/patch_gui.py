#!/usr/bin/env python3
"""Patch tailscale-ipn.exe (Tailscale 1.104.7) for Windows 7/8.

Three changes:
  1. PE optional-header OS/subsystem version 10.0 -> 6.1 (Windows 7).
  2. wingoes (*osVersionInfo).init: NOP the two "not Windows 10" panic
     branches so the normal version struct is built instead.
  3. Rename the bcryptprimitives.dll lookups (runtime UTF-16 array and the
     internal/syscall/windows ASCII string) to tsbcryptprng.dll, a shim that
     falls back to RtlGenRandom on Windows 7.

Usage: patch_gui.py <input.exe> <output.exe>
"""
import re
import struct
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, "rb").read())

    # --- PE header -------------------------------------------------------
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise SystemExit("not a PE file")
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    if magic != 0x20B:
        raise SystemExit(f"expected PE32+, got magic {magic:#x}")

    def u16(off):
        return struct.unpack_from("<H", data, off)[0]

    print("PE optional header at file offset %#x" % opt)
    print("  OS  %d.%d -> 6.1" % (u16(opt + 40), u16(opt + 42)))
    print("  SUB %d.%d -> 6.1" % (u16(opt + 48), u16(opt + 50)))
    struct.pack_into("<H", data, opt + 40, 6)
    struct.pack_into("<H", data, opt + 42, 1)
    struct.pack_into("<H", data, opt + 48, 6)
    struct.pack_into("<H", data, opt + 50, 1)
    struct.pack_into("<I", data, opt + 64, 0)  # checksum

    # --- wingoes version panic ------------------------------------------
    # cmp dword [rax+4], 10 ; jne panic
    # cmp dword [rax+8], 0  ; jne panic
    wingoes = re.compile(
        rb"\x83\x78\x04\x0a\x0f\x85....\x83\x78\x08\x00\x0f\x85....",
        re.S,
    )
    hits = list(wingoes.finditer(data))
    if len(hits) != 1:
        raise SystemExit(f"wingoes pattern: expected 1 match, got {len(hits)}")
    m = hits[0]
    off = m.start()
    print("wingoes version check at file offset %#x" % off)
    print("  NOP jne at %#x and %#x" % (off + 4, off + 14))
    data[off + 4:off + 10] = b"\x90" * 6
    data[off + 14:off + 20] = b"\x90" * 6

    # --- DLL search flags: allow the app-local shim ---------------------
    # The runtime loads bcryptprimitives with LOAD_LIBRARY_SEARCH_SYSTEM32.
    # Add LOAD_LIBRARY_SEARCH_APPLICATION_DIR (0x200) to the first call only,
    # so the shim can live next to tailscale-ipn.exe.
    rt_flag = bytes.fromhex("48c78424c000000000080000")
    rt_hits = [m.start() for m in re.finditer(re.escape(rt_flag), data)]
    if len(rt_hits) != 2:
        raise SystemExit(f"runtime 0x800 flags: expected 2 matches, got {len(rt_hits)}")
    rt_off = rt_hits[0] + 8
    print("runtime bcrypt load flags at file offset %#x: 0x800 -> 0xa00" % rt_off)
    data[rt_off:rt_off + 4] = b"\x00\x0a\x00\x00"

    # syscall.loadsystemlibrary does the same for NewLazySystemDLL.
    sys_flag = bytes.fromhex("48c744243000080000")
    sys_hits = [m.start() for m in re.finditer(re.escape(sys_flag), data)]
    if len(sys_hits) != 1:
        raise SystemExit(f"syscall 0x800 flags: expected 1 match, got {len(sys_hits)}")
    sys_off = sys_hits[0] + 5
    print("syscall loadsystemlibrary flags at file offset %#x: 0x800 -> 0xa00" % sys_off)
    data[sys_off:sys_off + 4] = b"\x00\x0a\x00\x00"

    # --- bcryptprimitives.dll -> tsbcryptprng.dll ------------------------
    old = b"bcryptprimitives.dll"
    new = b"tsbcryptprng_win.dll"
    if len(old) != len(new):
        raise SystemExit("replacement DLL name must match the original length")
    pad = len(old) - len(new)

    utf16_old = b"".join(bytes((c, 0)) for c in old)
    utf16_new = b"".join(bytes((c, 0)) for c in new) + b"\0\0" * pad
    uthits = [m.start() for m in re.finditer(re.escape(utf16_old), data)]
    if len(uthits) != 1:
        raise SystemExit(f"UTF-16 dll name: expected 1 match, got {len(uthits)}")
    print("runtime UTF-16 dll name at file offset %#x" % uthits[0])
    data[uthits[0]:uthits[0] + len(utf16_old)] = utf16_new

    ahits = [m.start() for m in re.finditer(re.escape(old), data)]
    marker = b"goroutine stacks:"
    cands = [h for h in ahits
             if data[h + len(old):h + len(old) + len(marker)] == marker]
    if len(cands) != 1:
        raise SystemExit(f"ASCII dll name: expected 1 match, got {len(cands)}")
    print("syscall ASCII dll name at file offset %#x" % cands[0])
    data[cands[0]:cands[0] + len(old)] = new + b"\0" * pad

    open(dst, "wb").write(data)
    print("wrote %s (%d bytes)" % (dst, len(data)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
