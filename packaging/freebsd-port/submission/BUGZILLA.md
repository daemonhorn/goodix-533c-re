# Submitting this port

Ready to file at https://bugs.freebsd.org/submit/. This is a manual,
public action — nothing here files it for you.

- **Product:** Ports & Packages
- **Component:** Individual Port(s)
- **Summary:** `[NEW PORT] security/libfprint-goodix533c: Library for fingerprint reader devices, with Goodix 533c support`
- **Description:**

  > New port building a variant of libfprint with a native, from-scratch
  > `FpDeviceClass` driver for the Goodix `27c6:533c` fingerprint sensor
  > (the "53xc"/GTLS encrypted match-on-host family), from
  > https://github.com/daemonhorn/libfprint (branch
  > `goodix533c-open-capture`, pinned commit `9484a83`). Not yet merged
  > upstream — tracked as
  > https://github.com/goodix-fp-linux-dev/libfprint/pull/40.
  >
  > `CONFLICTS_INSTALL` with `security/libfprint` since it replaces the
  > same `libfprint-2.so.2` SONAME; this means `security/fprintd` won't
  > pick it up automatically (its `LIB_DEPENDS` pins the stock port by
  > origin). This port is for the driver and library, not yet
  > `fprintd`/PAM login integration.
  >
  > Includes a local patch (`files/patch-libfprint_fpi-spi-transfer.c`,
  > generated with `make makepatch`) fixing a real portability bug in
  > upstream libfprint's core: `fpi-spi-transfer.c` unconditionally
  > includes Linux's `<linux/spi/spidev.h>` even when no SPI-based
  > driver is enabled, breaking the build on any non-Linux target. Since
  > only the Linux-only `elanspi` driver ever exercises that code path,
  > and it's excluded from this port's driver list anyway (it needs the
  > `udev` build helper, unavailable on FreeBSD), the fix stubs out
  > `transfer_chunk()` on non-Linux rather than touching driver
  > behavior.
  >
  > Tested against real `27c6:533c` hardware on FreeBSD 15.1-RELEASE via
  > QEMU USB passthrough: `configure`/`build`/`stage`/`check-plist`/
  > `package` all succeed, `portlint -A -c` reports no issues, and the
  > driver's own hardware test (`goodix533c-capture-test`) opens the
  > device and captures a real, non-degenerate 108x88 reference frame
  > through the full reset/TLS-PSK/config-upload/FDT sequence.
  >
  > Maintainer intends to keep tracking upstream PR #40 and update this
  > port accordingly (or retire it) once that lands.

- **Attachment:** `libfprint-goodix533c.diff` (this directory) — a
  `git format-patch` of one commit, adding `security/libfprint-goodix533c/`
  plus the `security/Makefile` `SUBDIR` entry.

## Before filing, re-verify against a fresh ports tree

This diff was generated against a ports tree snapshot from 2026-08-23.
If time has passed, `git pull` the tree, rebase the
`add-libfprint-goodix533c` branch, re-run `portlint -A -c` and the
`configure`/`build`/`stage`/`check-plist`/`package` cycle once more
(see `vm/freebsd/build-and-test-in-vm.sh` for the harness that already
does this against real hardware), and regenerate the diff if anything
moved — `security/Makefile`'s `SUBDIR` list in particular is a common
merge-conflict point since it churns constantly.
