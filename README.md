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

Early reconnaissance. See [`NOTES.md`](NOTES.md) for the running log.

**Confirmed:**
- `27c6:533c` is a Goodix **GTLS** (encrypted, match-on-host, raw-image)
  sensor — not the plaintext match-on-chip (`goodixmoc`) family already
  upstream in `libfprint`.
- No existing open-source work covers this PID group. `goodix-fp-dump`
  issue [#31](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/issues/31)
  (538c) was closed `wontfix`; `goodix-firmware` has no `53xc` directory.
- The generic GTLS wire protocol (`goodix.py` in `goodix-fp-dump`) is
  shared across 8 sibling model families — only a handful of
  model-specific constants (firmware name, 96-byte white-box PSK, sensor
  config blob, image dimensions) are missing for `53xc`.

## Scope

Target deliverable: a working Python capture tool (`goodix-fp-dump`-style)
that pulls a raw fingerprint image off the real sensor, proving the
protocol and producing the constants a future `libfprint` C driver would
need. Writing that C driver is a distinct, later project — see `NOTES.md`.

## Layout

- `NOTES.md` — RE log: findings, evidence, confidence levels, dead ends.
- `driver_53xc.py` — (WIP) `goodix-fp-dump`-style capture script for this
  PID group, built against a local clone of `goodix-fp-dump` (not vendored
  here — see NOTES for setup).
- No proprietary binaries or extracted vendor driver files are committed
  to this repo (see `.gitignore`) — only original analysis and open code.
