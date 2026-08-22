# Installing goodix-533c-test on Debian 13

**TEST / EXPERIMENTAL.** This is a standalone capture tool, not a driver
that logs you in. Read this whole page before installing.

## What you get

`goodix-533c-capture` — a command-line tool that talks to the real
`27c6:533c` sensor using an open-source reimplementation of its USB
protocol, and writes a raw `.pgm` image file. That's it.

## What you do NOT get

- No `fprintd` integration. The sensor will not show up in GNOME
  Settings, KDE System Settings, or any login/unlock screen.
- No PAM wiring. Installing this package does not change how `sudo`,
  login, or screen unlock authenticate you, at all.
- No guarantee of a clean, ridge-visible image on your specific hardware.
  Confirmed working (including visible ridge detail) on the original
  driver author's unit; on a second independent unit, the protocol and
  config all matched exactly, but the resulting image didn't show clear
  ridge detail across several attempts — see
  [`NOTES.md`](NOTES.md#cross-validating-75-on-this-hardware) for the
  current status of that investigation. Yours may vary either way.

## Install

Download the `.deb` from the
[Releases page](https://github.com/daemonhorn/goodix-533c-re/releases)
(look for the release tagged `test`), then:

```sh
sudo apt install ./goodix-533c-test_0.0.1~test1_all.deb
```

This pulls in `python3`, `python3-usb`, `python3-pycryptodome`, `openssl`,
and `udev` (all in stock Debian 13 repos — no third-party sources needed),
and installs a udev rule granting the `plugdev` group access to the
sensor.

Add yourself to `plugdev` if you aren't already a member, then log out
and back in for the group change to take effect:

```sh
sudo usermod -aG plugdev $USER
```

## Use

```sh
goodix-533c-capture
```

Touch the sensor firmly and hold when it prints "Waiting for finger".
Writes `fingerprint.pgm` to your current directory (override with
`GOODIX_533C_OUTDIR=/some/path`).

To view it, most image viewers choke on the non-standard PGM header this
tool (inherited from upstream) produces — see
[`findings/image-capture-success.md`](findings/image-capture-success.md)
for a note on that quirk and how to work around it if your viewer fails.

## Uninstall

```sh
sudo apt remove goodix-533c-test
```

## Reporting results

Whether it works cleanly, partially, or not at all on your unit, please
report back — more independently-tested units is exactly what's needed
to resolve the open image-quality question. Open an issue on this repo,
or comment on
[upstream PR #75](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/pull/75),
which is where the underlying driver code comes from (unmerged at the
time of this packaging).

## Building it yourself

```sh
git clone --recurse-submodules https://github.com/daemonhorn/goodix-533c-re.git
cd goodix-533c-re
sudo apt install dpkg-dev fakeroot
sh packaging/build.sh
```

Produces `packaging/out/goodix-533c-test_<version>_all.deb`. The driver
source (`driver_53xc.py`, `goodix.py`, `protocol.py`, `tool.py`) is
vendored as the `vendor/goodix-fp-dump-nikicat` submodule, pinned to the
commit used for each release — see `packaging/goodix-533c-test/` for the
wrapper script, udev rule, and Debian control files.
