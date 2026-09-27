#!/usr/bin/env python3
"""
Patch TIDRADIO TD-H9 v1.0.33 USB-C firmware for the experimental
928 MHz / PTT-validator-bypass build.

This script is intentionally version-specific. It refuses to patch an input
whose embedded flash image does not match the known stock v1.0.33 SHA-256.

No third-party Python modules are required.
"""

from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

STOCK_FLASH_SHA256 = "d0df607441a44765127cd5f00e34398f5866712dff3dfb17dc6f1fbf81118dc0"
EXPECTED_OUTPUT_SHA256 = "0fe4ef048da811408dfad588e517d987203159a7bc633a2c63cdf88f21173c7f"

UFW_KEY = 0xF181
CHIP_KEY = 0xF181
APP_AREA_BASE = 0x5000
APP_HEADER = 0x5020
APP_BASE = 0x5100
APP_SIZE = 0xCF5EC
APP_AREA_DATA = 0x5020
APP_AREA_DATA_SIZE = 0xCF6CC
MD5_HEADER = 0xD50E2
MD5_DATA = 0xD5102

RANGE_PATCHES = (
    (0x72FF8, 52_000_000, 92_800_000, "UHF upper limit"),
    (0x8306A, 120_000_010, 528_000_010, "400 MHz classifier span"),
    (0xCDCBC, 52_000_000, 92_800_000, "UHF upper range table"),
)

PTT_REJECT_APP_OFFSET = 0x5B60C
PTT_REJECT_STOCK_WORD = 0x5000
PTT_REJECT_PATCH_WORD = 0x0000


def crc16(data: bytes | bytearray, crc: int = 0) -> int:
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = (((crc << 1) ^ (0x1021 if crc & 0x8000 else 0)) & 0xFFFF)
    return crc


def jl_enc(buf: bytearray, off: int, size: int, key: int) -> None:
    for i in range(size):
        buf[off + i] ^= key & 0xFF
        key = ((key << 1) ^ (0x1021 if key & 0x8000 else 0)) & 0xFFFF


def decrypt_app_area(inner: bytes) -> bytearray:
    dec = bytearray(inner)
    for off in range(APP_AREA_BASE, len(dec), 32):
        size = min(32, len(dec) - off)
        key = CHIP_KEY ^ ((off - APP_AREA_BASE) >> 2)
        jl_enc(dec, off, size, key)
    return dec


def parse_ufw_header(fw: bytearray):
    if len(fw) < 0x200:
        raise ValueError("Input is too small to be a TD-H9 UFW file")

    hdr = bytearray(fw[:0x200])
    jl_enc(hdr, 0, 0x40, UFW_KEY)

    hdr_crc, list_crc, image_size, num_entries, unknown, header_size, chip = \
        struct.unpack_from("<HHIHHI48s", hdr, 0)

    if crc16(hdr[2:0x40]) != hdr_crc:
        raise ValueError("UFW header CRC mismatch")
    if header_size != 0x200:
        raise ValueError(f"Unexpected UFW header size 0x{header_size:X}")
    if num_entries <= 0 or 0x40 + num_entries * 0x50 > len(hdr):
        raise ValueError("Invalid UFW entry count")
    if chip.split(b"\0", 1)[0] != b"AC695X":
        raise ValueError("This does not look like the expected AC695X package")

    encrypted_entries = hdr[0x40:0x40 + num_entries * 0x50]
    if crc16(encrypted_entries) != list_crc:
        raise ValueError("UFW entry-list CRC mismatch")

    for off in range(0x40, 0x40 + num_entries * 0x50, 0x50):
        jl_enc(hdr, off, 0x50, UFW_KEY)

    return hdr, num_entries


def patch_firmware(stock_fw: bytes) -> tuple[bytes, dict[str, str]]:
    fw = bytearray(stock_fw)
    hdr, num_entries = parse_ufw_header(fw)

    flash_record = None
    for off in range(0x40, 0x40 + num_entries * 0x50, 0x50):
        rec = struct.unpack_from("<HHHHIII44s16s", hdr, off)
        etype, eindex, edcrc, ewa1, eoffset, esize, esize2, ewa2, ename = rec
        name = ename.split(b"\0", 1)[0]
        if etype == 0 and name == b"flash.bin":
            flash_record = (off, eoffset, esize, edcrc)
            break

    if flash_record is None:
        raise ValueError("flash.bin entry not found")

    rec_off, flash_off, flash_size, stored_flash_crc = flash_record
    if flash_off + flash_size > len(fw):
        raise ValueError("flash.bin extends past end of UFW file")

    inner = bytearray(fw[flash_off:flash_off + flash_size])
    inner_sha = hashlib.sha256(inner).hexdigest()
    if inner_sha != STOCK_FLASH_SHA256:
        raise ValueError(
            "Refusing to patch: embedded flash image is not the known stock "
            f"TD-H9 v1.0.33 image.\nExpected: {STOCK_FLASH_SHA256}\nGot:      {inner_sha}"
        )
    if crc16(inner) != stored_flash_crc:
        raise ValueError("Stock flash.bin CRC does not match its UFW entry")

    stock_dec = decrypt_app_area(inner)
    new_dec = bytearray(stock_dec)
    app = bytearray(new_dec[APP_BASE:APP_BASE + APP_SIZE])

    stock_app_md5 = hashlib.md5(app).hexdigest()
    if stock_app_md5 != "1ed6fe7f07c165e307677972b2853b59":
        raise ValueError(
            "Unexpected app.bin MD5; firmware layout/version is not the tested stock v1.0.33"
        )

    for off, old, new, desc in RANGE_PATCHES:
        got = struct.unpack_from("<I", app, off)[0]
        if got != old:
            raise ValueError(f"{desc}: expected {old} at app+0x{off:X}, got {got}")
        struct.pack_into("<I", app, off, new)

    got = struct.unpack_from("<H", app, PTT_REJECT_APP_OFFSET)[0]
    if got != PTT_REJECT_STOCK_WORD:
        raise ValueError(
            f"PTT reject branch mismatch at app+0x{PTT_REJECT_APP_OFFSET:X}: "
            f"expected 0x{PTT_REJECT_STOCK_WORD:04X}, got 0x{got:04X}"
        )
    struct.pack_into("<H", app, PTT_REJECT_APP_OFFSET, PTT_REJECT_PATCH_WORD)

    new_dec[APP_BASE:APP_BASE + APP_SIZE] = app

    app_crc = crc16(app)
    struct.pack_into("<H", new_dec, APP_HEADER + 2, app_crc)
    app_header_crc = crc16(new_dec[APP_HEADER + 2:APP_HEADER + 32])
    struct.pack_into("<H", new_dec, APP_HEADER, app_header_crc)

    app_md5_text = hashlib.md5(app).hexdigest().encode("ascii")
    new_dec[MD5_DATA:MD5_DATA + 32] = app_md5_text
    md5_crc = crc16(app_md5_text)
    struct.pack_into("<H", new_dec, MD5_HEADER + 2, md5_crc)
    md5_header_crc = crc16(new_dec[MD5_HEADER + 2:MD5_HEADER + 32])
    struct.pack_into("<H", new_dec, MD5_HEADER, md5_header_crc)

    area_crc = crc16(new_dec[APP_AREA_DATA:APP_AREA_DATA + APP_AREA_DATA_SIZE])
    struct.pack_into("<H", new_dec, APP_AREA_BASE + 2, area_crc)
    area_header_crc = crc16(new_dec[APP_AREA_BASE + 2:APP_AREA_BASE + 32])
    struct.pack_into("<H", new_dec, APP_AREA_BASE, area_header_crc)

    new_inner = bytearray(inner)
    for i, (old_plain, new_plain) in enumerate(zip(stock_dec, new_dec)):
        if old_plain != new_plain:
            new_inner[i] ^= old_plain ^ new_plain

    fw[flash_off:flash_off + flash_size] = new_inner

    flash_crc = crc16(new_inner)
    struct.pack_into("<H", hdr, rec_off + 4, flash_crc)

    entry_bytes = bytearray(hdr[0x40:0x40 + num_entries * 0x50])
    for rel in range(0, len(entry_bytes), 0x50):
        jl_enc(entry_bytes, rel, 0x50, UFW_KEY)
    hdr[0x40:0x40 + len(entry_bytes)] = entry_bytes

    list_crc = crc16(entry_bytes)
    struct.pack_into("<H", hdr, 2, list_crc)

    header_crc = crc16(hdr[2:0x40])
    struct.pack_into("<H", hdr, 0, header_crc)

    jl_enc(hdr, 0, 0x40, UFW_KEY)
    fw[:0x200] = hdr

    output_sha = hashlib.sha256(fw).hexdigest()
    info = {
        "input_flash_sha256": inner_sha,
        "output_sha256": output_sha,
        "app_md5": app_md5_text.decode("ascii"),
        "app_crc16": f"{app_crc:04X}",
        "app_area_crc16": f"{area_crc:04X}",
        "outer_flash_crc16": f"{flash_crc:04X}",
        "outer_list_crc16": f"{list_crc:04X}",
        "outer_header_crc16": f"{header_crc:04X}",
    }
    return bytes(fw), info


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Patch official TD-H9 v1.0.33 USB-C .fw into the experimental 928 MHz PTT-validator-bypass build"
    )
    ap.add_argument("input", type=Path, help="Official TD-H9 v1.0.33 .fw file")
    ap.add_argument(
        "-o", "--output", type=Path,
        default=Path("TD-H9-V1.0.33-928-PTT-VALIDATOR-BYPASS.fw"),
        help="Output .fw path"
    )
    args = ap.parse_args()

    patched, info = patch_firmware(args.input.read_bytes())
    args.output.write_bytes(patched)

    print(f"Wrote: {args.output}")
    print(f"Input flash SHA-256: {info['input_flash_sha256']}")
    print(f"Output SHA-256:      {info['output_sha256']}")
    print(f"App MD5:             {info['app_md5']}")
    print(f"App CRC16:           {info['app_crc16']}")
    print(f"App-area CRC16:      {info['app_area_crc16']}")
    print(f"Outer flash CRC16:   {info['outer_flash_crc16']}")
    print(f"Outer list CRC16:    {info['outer_list_crc16']}")
    print(f"Outer header CRC16:  {info['outer_header_crc16']}")

    if info["output_sha256"] != EXPECTED_OUTPUT_SHA256:
        raise SystemExit(
            "ERROR: generated file does not match the known-good output SHA-256. "
            "Do not flash it."
        )

    print("Verified: output matches the known-good tested build.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
