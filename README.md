# goodix-533c-re

Reverse-engineering notes and tooling to bring open-source fingerprint
support to the Goodix `27c6:533c` sensor (also covering sibling PIDs
`530c`/`538c` — the "53xc" group) on Linux/Debian.

## Why

Debian ships no closed-source TOD blobs and no native driver for this
device. The only working driver anywhere is Canonical/Goodix's proprietary
`libfprint-tod-goodix-53xc` blob (Ubuntu-only). This project aims to
reproduce what that blob does — using only open, black-box observation and
static analysis of the binary for interoperability — so this hardware can
work on Debian and be upstreamed into
[`goodix-fp-linux-dev/goodix-fp-dump`](https://github.com/goodix-fp-linux-dev/goodix-fp-dump)
and eventually `libfprint` itself.

## Status

**Done: real image capture confirmed working against real `27c6:533c`
hardware**, using only an open-source protocol reimplementation (no
vendor blob involved at runtime). See [`NOTES.md`](NOTES.md) for the full
running log and `findings/image-capture-success.md` for the final
root-cause writeup.

**Confirmed:**
- `27c6:533c` is a Goodix **GTLS** (encrypted, match-on-host, raw-image)
  sensor — not the plaintext match-on-chip (`goodixmoc`) family already
  upstream in `libfprint`.
- No existing open-source work covered this PID group before this
  project. `goodix-fp-dump` issue
  [#31](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/issues/31)
  (538c) was closed `wontfix`; `goodix-firmware` has no `53xc` directory.
- The generic GTLS wire protocol (`goodix.py` in `goodix-fp-dump`) is
  shared across 8 sibling model families — this project recovered the
  handful of `53xc`-specific pieces that were missing: PSK provisioning
  state, the `DEVICE_CONFIG` sensor-init blob (the "MilanFn" variant,
  checksum-corrected), sensor dimensions (108x88, shape-corroborated), and
  a device-specific USB response-ordering quirk affecting several
  commands.
- End-to-end flow (`nop → reset → PSK check → TLS-PSK handshake →
  upload_config_mcu → mcu_switch_to_fdt_mode → write_sensor_register →
  mcu_get_image`) runs against real hardware and decodes to a real,
  non-degenerate image.
- Upstreamed: [PR #76](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/pull/76)
  against `goodix-fp-dump` adds `driver_53xc.py`/`run_533c.py` for this
  PID.

**Deferred / not done:**
- PSK *writing* for this chip (not needed — this unit's PSK was already
  correctly provisioned from the factory; its success-response convention
  was also found to be inverted relative to every other model in
  `goodix-fp-dump`, documented in the driver for whoever needs it).
- `530c`/`538c` (same firmware/command-set per static analysis, but
  untested — no hardware to test against).
- OTP-derived calibration patching into `DEVICE_CONFIG` (a checksum fix
  alone was sufficient for a working capture; calibration quality with an
  actual finger present is unverified).
- A `libfprint` C driver — explicitly out of scope for this project (see
  `NOTES.md`); this project's deliverable is the working Python capture
  tool + recovered constants a future C driver would need.
- A `goodix-firmware` PR — that repo wants raw chip firmware dumps, which
  this project never had (only the closed shared library was available,
  not a firmware image); not applicable given what was extracted here.

## Layout

- `NOTES.md` — RE log: findings, evidence, confidence levels, dead ends.
- `findings/` — Phase 1 static-analysis writeups and Phase 2 live-capture
  analyses, in chronological order; `findings/image-capture-success.md`
  is the final result.
- `vendor/goodix-fp-dump/` — git submodule of the upstream project,
  checked out to the `add-53xc-533c-support` branch on
  [daemonhorn's fork](https://github.com/daemonhorn/goodix-fp-dump), which
  carries `driver_53xc.py`/`run_533c.py` (submitted upstream as PR #76).
- `capture_full_milanfn.py`, `capture_image_533c.py`,
  `capture_image_milanfn.py`, `probe_533c.py`, `write_psk_533c*.py` — the
  session's own working/debugging scripts, kept for history; `driver_53xc.py`
  in the submodule is the consolidated, cleaned-up result of these.
- No proprietary binaries or extracted vendor driver files are committed
  to this repo (see `.gitignore`) — only original analysis and open code.
