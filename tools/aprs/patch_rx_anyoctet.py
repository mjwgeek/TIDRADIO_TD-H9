#!/usr/bin/env python3
"""TD-H9 APRS V1.0.15 receive admission patch, exact-base only.

Extends the previously hardware-used MIN17 branch trampoline to admit any
FCS-valid frame with at least one data octet (3 bytes including FCS).
It does NOT bypass FCS, hardware buffer bounds or the main radio's parser.
"""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path

STOCK_SHA = "1dbbc10425f186f22a4d82d73f139f1e3cc3388931b73eb8ed18b6e3087ccd33"
KNOWN_GOOD_SHA = "f781878a3e7cd8fe8c0eea64ae3db91349138d695e4b194e82b88fe372d1c8b0"
EXPECTED_SIZE = 17304
# The 6-byte trampoline sits in unused bytes immediately before RX parser.
# 0x080051F6: cmp r0,#17 / blo reject / b original CRC gate.
STUB_OFFSET = 0x31F6
STUB_OLD = bytes.fromhex("11 28 1D D3 10 E0")
STUB_NEW = bytes.fromhex("03 28 1D D3 10 E0")
# The stock RX gate remains cmp r0,#18, but its short-frame branch targets stub.
BRANCH_OFFSET = 0x321A
BRANCH_BYTES = bytes.fromhex("12 28 EB D3")


def patch(raw: bytes) -> bytes:
    if len(raw) != EXPECTED_SIZE:
        raise ValueError(f"Wrong firmware size {len(raw)}, expected {EXPECTED_SIZE}")
    digest = hashlib.sha256(raw).hexdigest()
    if digest != KNOWN_GOOD_SHA:
        raise ValueError(f"Unrecognized firmware SHA-256 {digest}; exact MIN17 branch-stub base required")
    if raw[STUB_OFFSET:STUB_OFFSET+len(STUB_OLD)] != STUB_OLD:
        raise ValueError("MIN17 receive trampoline does not match expected machine code")
    if raw[BRANCH_OFFSET:BRANCH_OFFSET+len(BRANCH_BYTES)] != BRANCH_BYTES:
        raise ValueError("Receive completion branch does not match previously verified branch")
    out = bytearray(raw)
    out[STUB_OFFSET:STUB_OFFSET+len(STUB_NEW)] = STUB_NEW
    result = bytes(out)
    changes = [(i, old, new) for i, (old, new) in enumerate(zip(raw, result)) if old != new]
    if changes != [(STUB_OFFSET, 0x11, 0x03)]:
        raise AssertionError(f"Unexpected modifications: {changes}")
    assert len(result) == EXPECTED_SIZE
    assert result[BRANCH_OFFSET:BRANCH_OFFSET+4] == BRANCH_BYTES
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path, help='Exact known-good APRS-1.0.15-MIN17-BRANCH-STUB-DIAG.bin')
    parser.add_argument('output', type=Path, help='Output patched APRS image')
    opts = parser.parse_args()
    raw = opts.baseline.read_bytes()
    result = patch(raw)
    if opts.output.resolve() == opts.baseline.resolve():
        parser.error('Refusing to overwrite input firmware')
    opts.output.write_bytes(result)
    assert opts.output.read_bytes() == result
    print('Base SHA-256 :', hashlib.sha256(raw).hexdigest())
    print('Output SHA256:', hashlib.sha256(result).hexdigest())
    print('Changed byte : 0x31F6  11 -> 03')
    print('RX rule      : 3..792 bytes incl FCS; requires 0xF0B8 residue')
    print('Main MCU     : unchanged; short-frame forward not guaranteed')

if __name__ == '__main__':
    main()