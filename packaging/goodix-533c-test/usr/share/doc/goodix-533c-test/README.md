# goodix-533c-test

**TEST / EXPERIMENTAL.** Standalone capture tool, not a driver you can log
in with. Full status, findings, and methodology:
https://github.com/daemonhorn/goodix-533c-re

## What this is

A packaged version of nikicat's `driver_53xc.py`
(https://github.com/goodix-fp-linux-dev/goodix-fp-dump/pull/75, unmerged
at the time of packaging) for the Goodix `27c6:533c` fingerprint sensor.
Confirmed against real hardware on two independent physical units: the
protocol, TLS-PSK handshake, and `DEVICE_CONFIG` all work identically
across both.

## What this is NOT

- **Not a libfprint driver.** It does not install into
  `/usr/lib/*/libfprint-2/`, is not discovered by `fprintd`, and will not
  appear as an enrollment option in GNOME Settings, KDE, or anywhere else.
- **Not wired into PAM, login, screen unlock, or sudo.** Installing this
  package changes nothing about how your system authenticates you.
- **Not guaranteed to produce a clearly readable fingerprint image on your
  hardware.** It was verified to run the full protocol correctly (TLS
  handshake, config upload, finger detection all confirmed working) on a
  second physical unit different from the original author's, but visible
  ridge detail in the output image did not reproduce as cleanly on that
  second unit across several attempts. See the project homepage for the
  current status of that investigation.

## Usage

```
goodix-533c-capture
```

Touch the sensor when prompted. Writes `fingerprint.pgm` to the current
directory (or `$GOODIX_533C_OUTDIR` if set).

Requires your user to be in the `plugdev` group:

```
sudo usermod -aG plugdev $USER
# then log out and back in
```

## Why this exists

To let more `27c6:533c`/`530c`/`538c` owners test the open-source
protocol reimplementation against their own hardware and report back --
more independent units tested is exactly what's needed to resolve the
open ridge-visibility question. Report findings (working or not) at
https://github.com/daemonhorn/goodix-533c-re/issues or on upstream PR #75.

## License

MIT. See `copyright` in this directory. Driver code is nikicat's, not
this package's author's -- see `copyright` for the exact attribution.
