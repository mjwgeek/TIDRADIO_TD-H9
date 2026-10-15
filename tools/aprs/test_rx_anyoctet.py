#!/usr/bin/env python3
"""Deterministic software tests for TD-H9 APRS short-frame acceptance and octets.

These validate framing rules and exact byte patch, not RF transmit/receive.
"""
import hashlib
import random
import unittest
from pathlib import Path
from patch_rx_anyoctet import patch, STUB_OFFSET, BRANCH_OFFSET, STUB_NEW, BRANCH_BYTES

BASE_DIR = Path(__file__).resolve().parent
BASE = BASE_DIR / 'APRS-1.0.15-MIN17-BRANCH-STUB-DIAG.bin'


def crc_update(byte, crc):
    crc ^= byte
    for _ in range(8):
        crc = (crc >> 1) ^ (0x8408 if (crc & 1) else 0)
    return crc & 0xffff


def make_wire_frame(payload):
    crc = 0xffff
    for b in payload:
        crc = crc_update(b, crc)
    crc ^= 0xffff
    frame = bytes(payload) + crc.to_bytes(2, 'little')
    assert check_fcs(frame)
    return frame


def check_fcs(frame):
    crc = 0xffff
    for b in frame:
        crc = crc_update(b, crc)
    return crc == 0xf0b8


def receive(frame, min_including_fcs=3):
    """Recovered RX completion predicate, without emulating ARM peripherals."""
    if len(frame) < min_including_fcs or len(frame) > 792 or not check_fcs(frame):
        return None
    # Stock forwarding callback guards total length >2, removes two-byte FCS.
    return frame[:-2] if len(frame) > 2 else None


def kiss_encode(frame):
    out = bytearray([0xc0, 0x00])
    for b in frame:
        if b == 0xc0:
            out.extend((0xdb,0xdc))
        elif b == 0xdb:
            out.extend((0xdb,0xdd))
        else:
            out.append(b)
    out.append(0xc0)
    return bytes(out)


def kiss_decode(frame):
    assert frame[:2] == b'\xc0\x00' and frame[-1] == 0xc0
    body = bytearray()
    j = 2
    while j < len(frame)-1:
        c = frame[j]
        if c == 0xdb:
            j += 1
            c = {0xdc:0xc0,0xdd:0xdb}[frame[j]]
        body.append(c)
        j += 1
    return bytes(body)

class Tests(unittest.TestCase):
    def test_patch_exact(self):
        if not BASE.exists():
            self.skipTest('Base image not present; supply separately for binary validation')
        baseline = BASE.read_bytes()
        out = patch(baseline)
        diff = [i for i,(x,y) in enumerate(zip(baseline,out)) if x != y]
        self.assertEqual(diff,[0x31f6])
        self.assertEqual(out[STUB_OFFSET:STUB_OFFSET+6], STUB_NEW)
        self.assertEqual(out[BRANCH_OFFSET:BRANCH_OFFSET+4], BRANCH_BYTES)
        with self.assertRaises(ValueError):
            patch(baseline[:100])
        with self.assertRaises(ValueError):
            patch(out)

    def test_rx_minimum(self):
        self.assertIsNone(receive(make_wire_frame(b'')))   # Cannot forward empty AX.25 body
        self.assertEqual(receive(make_wire_frame(b'X')), b'X')
        for n in range(1,32):
            payload = bytes(range(n))
            self.assertEqual(receive(make_wire_frame(payload)),payload)
            old_result = receive(make_wire_frame(payload), 18)
            self.assertEqual(old_result, payload if n+2 >= 18 else None)

    def test_all_256_octets(self):
        payload = bytes(range(256))
        frame = make_wire_frame(payload)
        self.assertEqual(receive(frame),payload)
        self.assertEqual(kiss_decode(kiss_encode(receive(frame))),payload)

    def test_sabm_ua_i_and_binary(self):
        address = bytes.fromhex('ae8e6a8a8a96e4ae8e6a8a8a9663')
        for info in (b'\x3f',b'\x73',b'\x53',b'\x00\xf0TEST',b'\x03\xf0\xc0\xdb\x7e\x7f\x1b\x00\xff'):
            data=address+info
            self.assertEqual(receive(make_wire_frame(data)),data)
            self.assertEqual(kiss_decode(kiss_encode(data)),data)

    def test_crc_and_capacity(self):
        for n in (1,2,15,16,17,18,100,256,789,790):
            body = bytes((i*101 + 53) % 256 for i in range(n))
            wire = make_wire_frame(body)
            self.assertEqual(receive(wire),body)
            bad = bytearray(wire)
            bad[-1] ^= 0x01
            self.assertIsNone(receive(bytes(bad)))
        self.assertIsNone(receive(make_wire_frame(bytes(791))))

    def test_random_round_trips(self):
        rng = random.Random(0x54444839)
        for _ in range(1000):
            n = rng.randint(1,790)
            body = rng.randbytes(n)
            self.assertEqual(kiss_decode(kiss_encode(receive(make_wire_frame(body)))), body)

if __name__ == '__main__':
    unittest.main(verbosity=2)