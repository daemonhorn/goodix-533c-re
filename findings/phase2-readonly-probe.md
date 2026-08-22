# Phase 2 — Read-only live probe against real 27c6:533c hardware

Ran `probe_533c.py` (this repo) against the real device on the dev host.
Restricted deliberately to non-mutating protocol operations — no
`preset_psk_write`, no `upload_config_mcu`, no `reset`/`erase` — per the
plan's safety gate ("confirm before writing any PSK to the device").

## Result: the shared `goodix.py` wire protocol works against 533c unmodified

Only change from `driver_53xd.py`'s pattern: `PRODUCT_ID = 0x533C`. No
protocol/framing changes were needed. `nop()` got a correct ACK — this
confirms 533c speaks the exact same low-level packet framing
(`encode_message_pack`/`encode_message_protocol`, `COMMAND_ACK`, CRC) as
the other GTLS sibling models. This closes out the last real doubt about
family identification from earlier in the session.

## Live data recovered

| Item | Value | Notes |
|---|---|---|
| Firmware version | `GF5288_GM168SEC_APP_13020` | Confirms the Phase 1 static hypothesis (`GF5288_GM168SEC_APP_13016`, found in the closed blob's `.rodata`) was the right chip/firmware family — only the trailing build number differs (13016 vs 13020), which is completely expected (this unit's firmware build vs. whatever build the blob shipped support for). **The firmware-name gap flagged as "statically unresolvable" in `SUMMARY.md` is now resolved from the live device.** |
| Chip ID (`read_sensor_register(0x0000, 4)`) | `00000400` | New data point. Not yet cross-referenced against the 6 remaining `DEVICE_CONFIG` variant names (MilanF/MilanFn/MilanG/MilanH/MilanL/ChicagoHS) from `device-config.md` — next step if pursuing that gap further. |
| OTP (`read_otp()`) | `68c6266b542c1efa686ab40202081a58da189a5f70a5aa9d7092a500e0b0f5e1` (32 bytes) | New data point, not yet interpreted. |
| Live PMK hash (`preset_psk_read(0xbb020001, 32, 0)`) | `0b0c8d3ab390790823e519a4b5a7671c1e7081fc5512073d8761d968205711d` | Does **not** match `sha256(candidate PSK_WHITE_BOX)`. |

## Important correction to the probe's own framing

The probe script compares the device's *current* PMK hash against
`sha256(candidate PSK_WHITE_BOX)` and reports a mismatch. **This mismatch
is not evidence the candidate is wrong.** Re-reading `driver_53xd.py`'s
flow: `check_psk()` (the hash comparison) is only meaningful *after*
`write_psk()` has run — before that, the device's live PSK is whatever
unique factory-programmed secret was set at manufacturing, which is
expected to differ from the shared white-box constant on every unit until
a driver deliberately overwrites it. Reading the factory PSK hash first
was a legitimate, safe thing to do (now recorded above for reference), but
it doesn't confirm or refute the `PSK_WHITE_BOX` candidate one way or the
other. The real test requires calling `write_psk()` (a mutating operation)
and then re-reading — which is exactly the step the plan's safety gate
asks to pause on. See README/plan for the Windows-Hello-enrollment check
that should happen before that.

## Housekeeping note

`device.disconnect()` raised `TimeoutError` at the very end of the run —
this is benign: `protocol.py`'s `disconnect()` polls waiting for the
device to drop off the USB bus, which normally only happens after a
`reset()`/firmware-update cycle. Since this probe never resets the device,
it never re-enumerates, so the poll always times out. All reads had
already completed successfully before this. `probe_533c.py` now catches
this specific `TimeoutError` around `disconnect()`.

## Updated status

- Family/framing: **fully confirmed** against real hardware (was: strong
  static hypothesis).
- Firmware string: **confirmed** (was: "not resolvable statically").
- Chip ID / OTP: **captured**, not yet interpreted.
- `PSK_WHITE_BOX` candidate: **still unconfirmed** — the meaningful test
  (`write_psk()` then re-read) has not been attempted, pending the
  Windows-Hello-enrollment check called for in the plan.
- `DEVICE_CONFIG` variant: **still unresolved** among 6 candidates —
  chip ID `00000400` is a new lead but not yet cross-referenced.
- `SENSOR_WIDTH`/`SENSOR_HEIGHT`: still not resolved; per the plan, these
  are expected to come from the raw image payload size once capture is
  attempted, not from further static analysis.
