# TD-H9 APRS 1.0.15: any-octet RX candidate

**Experimental and not radio-validated.** 15 October 2026.

## What this actually patches

The `APRS-1.0.15-RX-ANYOCTET-FCS.bin` candidate is based on the exact prior MIN17 *branch-stub* image, not the problematic one-byte change in the stock comparison. The parent MIN17 image has SHA-256 `f781878a3e7cd8fe8c0eea64ae3db91349138d695e4b194e82b88fe372d1c8b0`.

At file offset `0x31F6` (runtime `0x080051F6`), the existing `cmp r0,#17` is changed to `cmp r0,#3` (byte `11` to `03`). The existing short-frame branch and the original `cmp r0,#18` remain unchanged. A completed frame can now reach the original CRC check when the total received size (including two FCS bytes) is **3 through 792 bytes**.

- Retains original CRC/FCS residue gate `0xF0B8`, frame completion, 792-byte bound, HDLC decoder and UART/KISS framing.
- Handles all 256 octet values in the raw binary body. KISS escapes C0 and DB; internal HDLC FIFO escapes 7E, 7F and 1B.
- Supports a **one-octet data body**, as required by the downstream callback, which returns nothing for lengths <= 2 including FCS.
- For AX.25-valid two-address control-only SABM/UA, the 15-octet body + 2-byte FCS is accepted by the new receive length gate.
- Does **not** bypass CRC, increase the buffer, fix radio hardware, improve RF frame timing, or alter the main JieLi radio firmware. Invalid arbitrary byte streams are not guaranteed to be forwarded.
- Ordinary AX.25 frames need valid address/control structure; this modem will allow shorter-than-AX.25 binary diagnostic frames, but the main CPU may reject them.

Binary checks:

- Baseline firmware size: 17,304 bytes.
- Baseline stock v1.0.15 checksum: `1dbbc10425f186f22a4d82d73f139f1e3cc3388931b73eb8ed18b6e3087ccd33` (not patch input).
- Required *MIN17 branch stub* checksum: `f781878a3e7cd8fe8c0eea64ae3db91349138d695e4b194e82b88fe372d1c8b0`.
- **Patched candidate checksum:** `878971a096fa5d48a4ad76c4ce4a6693bf7e49312561ea6a219479545e51b12c`.
- Exactly one byte differs from the required MIN17 baseline: `0x31F6: 11 -> 03`.

## Reproducible build and test

On a machine with Python 3.8+ and the known-good MIN17 baseline in this directory:

```bash
python patch_rx_anyoctet.py APRS-1.0.15-MIN17-BRANCH-STUB-DIAG.bin APRS-1.0.15-RX-ANYOCTET-FCS.bin
python test_rx_anyoctet.py
```

The tests cover the changed binary offset, corrupted FCS rejection, every octet 00..FF, KISS C0/DB escaping, control-only SABM/UA, 1..790 byte bodies, 791-byte overflow, 1000 random round trips. They exercise a software model of recovered receive logic, **not original ARM execution, RF modulation, main-radio parsing, or radio flashing**.

## Where a real end-to-end fix still needs work

Per the [TD-H9 packet-modem analysis](https://github.com/zardoz99/TD-H9-Packet-Modem-Analysis):

1. The modem already preserves control/PID on raw transmit; a short KISS payload reaches the original modem serializer in emulation.
2. The main TD-H9 JieLi firmware has *separate* control/PID parsing, packet rebuilding and forwarding rules. Those may discard or transform valid packets before/after they touch this APRS module.
3. Earlier on-radio experiments with 15-byte clean SABM produced no usable receive report despite an audible TX frame. A receive length patch alone is **not sufficient evidence** that TX is clean or that the receiver decoded a CRC-valid packet.

**Bench test**: Keep a confirmed working main firmware on both radios. Flash this image to the RX radio's *APRS coprocessor only* using the established APRS recovery/update method. Leave the TX APRS image known-good. First verify a normal, longer APRS UI arrives. Then transmit one previously proven good long SABM and finally a clean 15-byte SABM; check direct AF02 KISS output. If ordinary longer APRS UI no longer arrives, revert immediately to MIN17/stock. No OTA success or RF tests have been performed on this new binary.

The production-ready goal should be byte-transparent host forwarding in the JieLi main firmware, plus measured clean 15-byte transmitter RF; don't loosen FCS validation or copy arbitrary memory to fix the symptom.