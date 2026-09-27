# TD-H9 v1.0.33 Patch Notes

These notes document the experimentally verified firmware changes used by this repository.

## Base image

- Radio: TIDRADIO TD-H9
- Firmware: v1.0.33
- Stock inner `flash.bin` SHA-256:
  `d0df607441a44765127cd5f00e34398f5866712dff3dfb17dc6f1fbf81118dc0`

The patcher is deliberately version-specific and refuses to modify an input whose embedded flash image does not match that SHA-256.

## Frequency representation

The application commonly stores radio frequency values in 10 Hz units. For example:

- 136 MHz = 13,600,000
- 400 MHz = 40,000,000
- 520 MHz = 52,000,000
- 928 MHz = 92,800,000

## Working range changes

All offsets below are relative to the start of `app.bin`.

| Offset | Stock value | Patched value | Purpose |
| --- | ---: | ---: | --- |
| `0x72FF8` | 52,000,000 | 92,800,000 | UHF upper limit |
| `0x8306A` | 120,000,010 | 528,000,010 | widen the 400 MHz classifier span |
| `0xCDCBC` | 52,000,000 | 92,800,000 | UHF range-table upper limit |

These changes allow the VFO/range logic to extend through 928 MHz.

## Working TX change

The successful TX patch does **not** replace the TX setup routine and does **not** replace the validator.

The normal transmit path reaches:

```text
app+0x5B608  call app+0x56D46
app+0x5B60C  jz   TX_REJECT
```

The call to `app+0x56D46` remains untouched. The two-byte conditional reject at `app+0x5B60C` is changed from:

```text
00 50    ; jz rejection path
```

to:

```text
00 00    ; Pi32v2 NOP
```

This preserves the stock transmit setup and side effects but prevents this final validator result from canceling PTT.

## Failed experiments worth preserving

These failures helped identify which code must remain intact:

- Replacing the routine at `app+0x5B50E` with a forced return value disabled normal TX.
- Both forced return values were tested; both broke ordinary TX, showing that routine is not a safe boolean-only gate and performs required work.
- Changing the executable 600 MHz value at `app+0x57232` to 928 MHz disabled TX globally. That value participates in a required TX/RF setup calculation and must remain stock.
- Changing the 600 MHz RF-table value at `app+0xCF598` to 928 MHz did not enable >599 MHz TX.

Do not carry those experiments into release builds.

## JieLi container/checksum chain

The official USB-C `.fw` is a JieLi UFW package containing the inner firmware image.

For a modified image to be accepted by the original updater, the patcher rebuilds:

1. app.bin data CRC
2. app.bin header CRC
3. app MD5 record and its CRC/header CRC
4. parent app-area CRC/header CRC
5. outer `flash.bin` CRC
6. encrypted UFW entry-list CRC
7. UFW header CRC

The original, unmodified TIDRADIO updater can then flash the resulting package.

## Safety / RF testing

Unlocking a software transmit check does not establish that the radio is electrically suitable for a frequency.

When evaluating a newly unlocked range:

- use a dummy load or otherwise contained RF test setup first;
- measure output power and PLL lock;
- inspect harmonics and spurious products with appropriate test equipment;
- do not connect an antenna and radiate outside frequencies where you are authorized to transmit.

The PA, matching network, filters, and synthesizer may behave very differently outside the manufacturer's intended range.
