# Submitting this port

Ready to file at https://bugs.freebsd.org/submit/. This is a manual,
public action — nothing here files it for you.

- **Product:** Ports & Packages
- **Component:** Individual Port(s)
- **CC:** danfe@FreeBSD.org (maintainer of `security/libfprint` and
  `security/fprintd`, both affected by this submission — see below)
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
  > **Effects on the existing `security/libfprint`/`security/fprintd`
  > install, stated plainly:**
  > - `CONFLICTS_INSTALL` both ways with `security/libfprint` (this diff
  >   also adds the reciprocal `CONFLICTS_INSTALL` to
  >   `security/libfprint`'s own Makefile, mirroring the
  >   `www/nginx`/`www/nginx-devel` pattern) — the two cannot be
  >   installed together.
  > - Installing this port makes `fprintd`/PAM fingerprint login
  >   **entirely unavailable** until this driver is upstreamed:
  >   `security/fprintd`'s `LIB_DEPENDS` pulls in `security/libfprint`
  >   by port origin, which then conflicts outright.
  > - This is also a version **downgrade** of the base library while
  >   installed: the fork this port builds is `libfprint` 1.94.5;
  >   `security/libfprint` is currently 1.94.10_1 — five releases
  >   ahead, including its own newer driver additions (e.g. Focaltech
  >   MOC, itself carried as an unmerged-upstream patch on the
  >   canonical port — the same situation this submission is in, just
  >   solved differently here because of the added OpenCV dependency).
  >
  > Given all of that, this port is for validating the driver against
  > real hardware and for anyone who wants this sensor working *now* at
  > the cost of fprintd/PAM integration — not a drop-in upgrade path.
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
  > **Not verified**: enroll/verify/identify (the OpenCV/SIGFM matching
  > path) against a real fingerprint on FreeBSD — only sensor open() and
  > the no-finger reference capture were hardware-tested.
  >
  > Maintainer intends to keep tracking upstream PR #40 and update this
  > port accordingly (or retire it) once that lands.

- **Attachment:** `libfprint-goodix533c.diff` (this directory) — a
  `git format-patch` of two commits: (1) adds
  `security/libfprint-goodix533c/` plus the `security/Makefile`
  `SUBDIR` entry, (2) adds the reciprocal `CONFLICTS_INSTALL` to
  `security/libfprint/Makefile`.

## Before filing, re-verify against a fresh ports tree

This diff was generated against a ports tree snapshot from 2026-08-23.
If time has passed, `git pull` the tree, rebase the
`add-libfprint-goodix533c` branch, re-run `portlint -A -c` on both
`security/libfprint-goodix533c` (new port) and `security/libfprint`
(`portlint -C -c`, existing port) plus the
`configure`/`build`/`stage`/`check-plist`/`package` cycle once more
(see `vm/freebsd/build-and-test-in-vm.sh` for the harness that already
does this against real hardware), and regenerate the diff if anything
moved — `security/Makefile`'s `SUBDIR` list and `security/libfprint`'s
own `DISTVERSION` in particular are common merge-conflict points since
both churn.
