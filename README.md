# TIDRADIO TD-H9 Experimental Firmware

Experimental firmware work for the **TIDRADIO TD-H9**, based on the official **v1.0.33** firmware.

The current build extends the UHF tuning range to 928 MHz and bypasses the firmware's final PTT frequency-validation rejection so the radio can enter transmit above the stock ~599 MHz cutoff while preserving the normal TX initialization path.

## ⚠️ Amateur-radio / regulatory warning

This project is intended for **licensed amateur-radio experimentation, bench testing, research, and education**.

- You are responsible for knowing and following the laws, band plans, license privileges, power limits, emission requirements, and equipment rules that apply in your country or jurisdiction.
- A frequency being selectable or the radio entering transmit **does not mean transmission there is legal**.
- Do not transmit on public-safety, aviation, cellular, satellite, military, commercial, or other services for which you are not authorized.
- Modified firmware can enable operation outside the manufacturer's intended limits. RF output power, spectral purity, harmonics, spurious emissions, PLL lock, filtering, and PA behavior may be poor or unpredictable outside the radio's original design range.
- For out-of-band or newly unlocked ranges, test into a **dummy load** with suitable RF test equipment before connecting an antenna.
- Firmware modification and flashing can brick or damage a radio. Keep a known-good official firmware image available for recovery.

**Use at your own risk.**

This repository is an independent community project and is **not affiliated with, endorsed by, or supported by TIDRADIO**.

## Current experimental build

`TD-H9-V1.0.33-928-PTT-VALIDATOR-BYPASS.fw`

Base firmware: **TD-H9 v1.0.33**

SHA-256:

```
0fe4ef048da811408dfad588e517d987203159a7bc633a2c63cdf88f21173c7f
```

### What changed

The successful build keeps the radio's normal transmit setup intact and applies four targeted changes to `app.bin`:

- UHF upper-limit constant: **520 MHz → 928 MHz**
- 400 MHz classifier span widened so the extended UHF range survives the normal range classifier
- UHF range-table upper limit: **520 MHz → 928 MHz**
- The final PTT rejection branch following the TX-frequency validator is replaced with a Pi32v2 NOP

The important TX patch is at:

```text
app + 0x5B608   call app+0x56D46   ; validator remains intact
app + 0x5B60C   jz   TX_REJECT    ; stock
                ↓
app + 0x5B60C   nop               ; modified
```

This is deliberately different from replacing the validator or TX setup functions themselves. Earlier experiments that forced returns or changed the 600 MHz setup threshold disabled normal transmission because those routines have required setup/state side effects.

See [PATCH_NOTES.md](PATCH_NOTES.md) for the byte-level details.

## Flashing

Use the **original, unmodified TIDRADIO USB-C firmware updater**.

The firmware file in this repository has a correctly rebuilt JieLi UFW container and CRC chain. Patched updater executables are neither required nor recommended.

1. Keep a copy of the official v1.0.33 firmware for recovery.
2. Load the experimental `.fw` file in the original updater.
3. Flash normally.
4. Verify ordinary 2 m / 70 cm operation first.
5. Bench-test newly unlocked frequencies into a dummy load before using an antenna.

## Tested behavior

The working patch was developed by tracing the stock TD-H9 v1.0.33 firmware and iteratively testing on real hardware.

Normal amateur-band TX continues to work with the successful PTT-validator-bypass build, and the firmware no longer applies the stock final PTT rejection above the original ~599 MHz ceiling.

**RF performance is not guaranteed across the expanded range.** Treat every newly unlocked frequency range as experimental until output level, spectral purity, harmonics, spurious emissions, and synthesizer lock have been measured.

## Recovery

If an experimental build behaves unexpectedly, re-flash the **official TD-H9 v1.0.33 firmware** with the original updater.

## Credits / prior art

Reverse-engineering work benefited from public JieLi/pi32v2 research and tooling, including:

- `kagaimiq/jl-misctools`
- `quarkslab/ghidra-jieli`
- `nicsure/TD-H8-Engineering`
- `yobabyte/tid_umod`

The original firmware and trademarks belong to their respective owners.
