#!/usr/bin/env python3
"""Builds synthetic commercial-header N64 test ROMs (.z64, .v64, .n64, and 64 MiB .z64)
from `n64_guest_rom.bin` (`0x8000_0400`) with Cartridge ID `N3DE` (16 Kbit EEPROM in n64savedb.txt)."""

import struct
import sys


def rom_pat(off: int) -> int:
    return (0x9E3779B9 ^ off ^ (((off >> 11) * 0x045D9F3B) & 0xFFFFFFFF)) & 0xFFFFFFFF


def build_z64(guest_bin: bytes, total_size: int, is_64mb: bool) -> bytearray:
    buf = bytearray(total_size)
    # Standard .z64 big-endian header:
    # 0x00: 0x80371240, 0x08: entry 0x80000400, 0x10: boot_len (for Libdragon banner if used)
    struct.pack_into(">IIII", buf, 0x00, 0x80371240, 0x0000000F, 0x80000400, 0x00001444)
    title = b"GAMEBUB N64 TEST    "
    buf[0x20:0x34] = title[:20]
    # Cartridge ID at 0x3B..0x3E = "N3DE" (matches `N3D? eeprom16k` in assets/n64savedb.txt!), rev 0 at 0x3F
    buf[0x3B:0x3F] = b"N3DE"
    buf[0x3F] = 0
    # Open-source IPL3 banner at 0x40 so n64rt copies exact guest size cleanly (or 1 MiB)
    banner = b" Libdragon IPL3  Coded by Rasky "
    buf[0x40:0x60] = banner
    guest_padded_len = (len(guest_bin) + 15) & ~15
    struct.pack_into(">I", buf, 0x10, guest_padded_len)
    buf[0x1000 : 0x1000 + len(guest_bin)] = guest_bin

    # Marker word at 0x0001FFF0 indicating 64 MiB ROM test mode
    struct.pack_into(">I", buf, 0x0001FFF0, 0x644D4221 if is_64mb else 0x00024D42)

    # Populate deterministic verification pattern at key regions:
    # - 0x00020000 .. 0x00030000 (64 KiB resident L1/L2 cache region)
    # - if 64 MiB: 0x032FF000 .. 0x03302000 (51 MiB resident/paged boundary) and 0x03F80000 .. 0x03F82000 (63.5 MiB tail)
    ranges = [(0x00020000, min(total_size, 0x00030000))]
    if is_64mb:
        ranges.append((0x032FF000, 0x03302000))
        ranges.append((0x03F80000, 0x03F82000))
    for lo, hi in ranges:
        for off in range(lo, hi, 4):
            struct.pack_into(">I", buf, off, rom_pat(off))
    return buf


def to_v64(z64: bytes) -> bytes:
    out = bytearray(len(z64))
    out[0::2] = z64[1::2]
    out[1::2] = z64[0::2]
    return bytes(out)


def to_n64(z64: bytes) -> bytes:
    out = bytearray(len(z64))
    out[0::4] = z64[3::4]
    out[1::4] = z64[2::4]
    out[2::4] = z64[1::4]
    out[3::4] = z64[0::4]
    return bytes(out)


def main() -> None:
    guest_path, out_prefix = sys.argv[1], sys.argv[2]
    guest = open(guest_path, "rb").read()

    rom_2m = build_z64(guest, 2 * 1024 * 1024, is_64mb=False)
    open(out_prefix + ".z64", "wb").write(rom_2m)
    open(out_prefix + ".v64", "wb").write(to_v64(rom_2m))
    open(out_prefix + ".n64", "wb").write(to_n64(rom_2m))

    if "--with-64mb" in sys.argv:
        rom_64m = build_z64(guest, 64 * 1024 * 1024, is_64mb=True)
        open(out_prefix + "_64m.z64", "wb").write(rom_64m)


if __name__ == "__main__":
    main()
