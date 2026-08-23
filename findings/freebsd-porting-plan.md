# FreeBSD Porting Plan: goodix533c libfprint Driver

Status: research/planning document, no code changes. Written 2026-08-23 from a Linux
development machine with no FreeBSD hardware available for testing.

## Summary

Porting is plausible on paper: the driver's protocol/crypto/matching logic is plain
C/C++ with no OS dependency, its USB path goes exclusively through libfprint's own
`fpi_usb_transfer_*` / GUsb abstraction (no raw Linux ioctls, no udev/sysfs reads, no
Linux-only headers), and every non-libfprint dependency it pulls in (GLib, OpenSSL,
OpenCV, Meson/Ninja) is packaged and apparently current on FreeBSD today, with
upstream libfprint itself packaged at a recent version (1.94.10) and building without
udev. The realistic blockers are not "will it compile" but "will it run against the
actual sensor," and that cannot be answered from this session: **nobody on this
project has a FreeBSD machine with a 27c6:533c device attached**, and a historical
GUsb bug (`g_usb_device_get_parent()` returning `NULL` on FreeBSD) that broke
libfprint device detection there was only fixed upstream in FreeBSD's base libusb
around mid-2025 — recent enough that its reach into what most users are actually
running is unverified. Effort shape: the build-system and dependency-verification
phases (0–2 below) are a few days of work for someone with FreeBSD familiarity and
could largely be done without the physical sensor; everything past that (Phase 3
onward) is gated on hardware access and is unbounded until that gate clears.

---

## 1. Driver code inventory — what's actually Linux-specific

Read directly from the submodule (not modified) at
`/home/dhorn/goodix/goodix-533c-re/vendor/libfprint-goodixtls/`:

- `libfprint/drivers/goodix533c/goodix533c.c`, `.h`, `-private.h`, `-enroll.c/.h`,
  `-auth.c/.h`, `-match.c/.h`, `capture_test.c`
- `libfprint/drivers/goodixtls/` (shared TLS-PSK server + wire codec, reused unmodified
  by goodix533c per the header comment in `goodix533c.h`)
- `meson.build` (top level) and `libfprint/meson.build`

### USB transport

All USB I/O goes through libfprint's own transfer abstraction:
`fpi_usb_transfer_new`, `fpi_usb_transfer_fill_bulk[_full]`, `fpi_usb_transfer_submit[_sync]`,
`fpi_usb_transfer_unref` (see `goodix533c.c` lines ~330–397). The only points where the
driver reaches past that abstraction are two direct GUsb calls:

```
libfprint/drivers/goodix533c/goodix533c.c:2012:  g_usb_device_claim_interface (fpi_device_get_usb_device (dev), ...)
libfprint/drivers/goodix533c/goodix533c.c:2083:  g_usb_device_release_interface (fpi_device_get_usb_device (dev), ...)
```

(and the same pattern in the sibling `goodixtls/goodix.c:1197,1232`, not part of this
driver but built alongside it as a shared helper). `claim_interface` /
`release_interface` are ordinary, well-supported GUsb entry points — not the specific
`g_usb_device_get_parent()` call that has a known FreeBSD history (see §3/§4 below).
Whether libfprint's *own* core (device enumeration in `fpi-context.c`, not this driver)
calls `get_parent()` somewhere on the open path was not traced in this session — flagged
as unverified in §7.

`libfprint/meson.build` declares `gusb_dep = dependency('gusb', version: '>= 0.2.0')` as
a hard dependency of libfprint core, confirming `fpi_usb_transfer_*` is a wrapper over
GUsb (which itself wraps libusb-1.0), not a Linux-specific transport.

### Non-USB OS dependencies

`grep -rniE "linux/|sys/ioctl|usbdevice_fs|udev|systemd|/proc/|/sys/|pthread"` across
`drivers/goodix533c/` and `drivers/goodixtls/` found:

- `goodixtls/goodixtls.c` and `goodixtls/goodix.c`: `#include <pthread.h>`,
  `<sys/socket.h>`, `<arpa/inet.h>`, `<netinet/in.h>`, `<poll.h>`, `<signal.h>` — used
  to run the embedded TLS-PSK server on a background thread talking to itself over a
  loopback socket. All of these are standard POSIX/BSD-sockets APIs present on FreeBSD
  (`pthread_create`/`pthread_join`, BSD sockets are FreeBSD's native socket API, not a
  Linux borrowing). No Linux-only headers (`<linux/...>`), no `ioctl()`-based device
  control, no `/proc` or `/sys` reads, no udev/libudev/systemd calls anywhere in either
  directory.
- `goodix533c.c` includes `<openssl/ssl.h>` directly; `goodixtls.c` pulls in
  `<openssl/crypto.h>`, `<openssl/err.h>`, `<openssl/ssl.h>`, `<openssl/tls1.h>` — a
  portable OpenSSL API surface, nothing Linux-specific.
- `goodix533c-match.c` includes `sigfm/sigfm.hpp` (the project's SIGFM wrapper around
  OpenCV) with no OS-specific includes of its own.
- `capture_test.c` (the project's own standalone test harness) includes only
  `<errno.h> <stdio.h> <string.h> <glib.h>` plus libfprint headers — no Linux-only
  tooling baked into the harness itself. (Protocol-capture *development* tooling like
  usbmon/Wireshark, used earlier in this project's RE work, is separate from this file
  and is addressed in §5.)

**Conclusion: nothing in the goodix533c driver's own source is Linux-specific.** Every
OS-facing call is either POSIX (pthread, BSD sockets) or routed through GUsb.

### udev at the build level

Confirmed directly in `meson.build` (top level): the `driver_helper_mapping` table maps
`'goodix533c' : [ 'goodixtls', 'sigfm' ]` — no `'udev'` helper. Only `elanspi` maps to
`'udev'` (SPI enumeration genuinely needs it). `udev_rules`/`udev_hwdb` are both
`feature` options defaulting to `'auto'`, so a plain `meson setup -Dudev_hwdb=disabled
-Dudev_rules=disabled` build (the option pair the project's own history already
identified) skips udev entirely for a `-Ddrivers=goodix533c` (or default-drivers) build.
This still holds against the current tree.

### The OpenCV/SIGFM build path (device-specific but worth flagging)

The top-level `meson.build`'s `sigfm` branch (lines ~256–292) is written defensively for
portability already: it tries `opencv5` then falls back to `opencv4` via pkg-config,
links only `opencv_core`, `opencv_features2d` (falling back to `opencv_features` for the
OpenCV 5 rename), `opencv_flann`, `opencv_imgproc` — not the full OpenCV surface — and
only makes OpenCV a dependency at all when a driver that needs it (currently just
`goodix533c`) is actually enabled. This is favorable for FreeBSD: FreeBSD's OpenCV port
is currently at 4.13.0 (see §4), i.e. `opencv4`, which the existing fallback logic
already targets without modification.

### State of the tree at read time

Two other agents were noted to be working concurrently in this submodule (SIGFM
matching wiring, a test harness). At the time of reading, `goodix533c-match.c`,
`-enroll.c`, `-auth.c` were present and wired into `libfprint/meson.build`'s
`driver_sources['goodix533c']` list; `goodix533c.c` itself (2179 lines) reads as a
complete open()/capture pipeline (reset → PSK check → TLS handshake → config upload →
FDT baseline → reference frame → finger wait → live frame → flat-field), not a stub.
No half-finished `#if 0` blocks or obvious merge conflict markers were seen in the
portions read. This is a snapshot, not a guarantee the tree stayed in this state —
re-read before acting on file-line specifics if time has passed.

---

## 2. obiw.ac/fprint — required reading, reviewed

This is **a personal technical blog post/guide** by an individual FreeBSD user
(username/handle "obiw.ac"), not an official FreeBSD project, a package, or a fork of
libfprint — closer to a HOWTO than documentation for a maintained artifact. Published
2024-12-10, with at least one later inline edit noting the FreeBSD `libfprint` port had
since been updated and "patches were upstreamed," so parts of the article describe
workarounds that were current at publish time but are now stated by the author to be
obsolete. It was not possible in this session to fully separate original-2024 content
from later edits beyond that one quoted note — treat the article's currency as mixed,
not uniformly up to date.

What it covers, per two independent fetches of the live page:

- **Context at publish time**: "the `security/libfprint` port in FreeBSD is very
  outdated, and doesn't support the 2nd version of the API or any new fingerprint
  scanners (including the Framework ones). I'm working on a new port..." The author was
  building libfprint from a personal GitLab branch
  (`gitlab.freedesktop.org/JohnAZoidberg/libfprint`, `freebsd-usb` branch) rather than
  using the FreeBSD package.
- **The GUsb bug, stated explicitly**: "the next thing you'll run into is that
  `libfprint` won't detect any scanners. This is because it uses the
  `g_usb_device_get_parent` function from `devel/libgusb`, which always returns `NULL`
  on FreeBSD" — because that GUsb call depends on `libusb_get_parent()`, which FreeBSD's
  base-system libusb didn't implement at the time. See §4 for the fix status.
- **Build invocation quoted**: `meson -Dudev_rules=disabled -Dudev_hwdb=disabled build`
  for libfprint, and for fprintd: `meson -Dlibsystemd=basu -Dsystemd=false
  -Dopenpam=true -Dpam_modules_dir=/usr/local/lib build` — substituting `basu` for
  libsystemd and OpenPAM for Linux-PAM. This matches, independently, what the current
  FreeBSD ports Makefiles for both packages actually use (§3).
  - **This is the same `-Dudev_rules=disabled -Dudev_hwdb=disabled` pairing this
    project's own history already identified** — independent confirmation from a
    different source that it's the correct minimal-build incantation, not something
    specific to this driver.
- **PAM setup**: adds `auth sufficient /usr/local/lib/security/pam_fprintd.so` to
  `/etc/pam.d/system`, alongside the existing `pam_unix.so` line — standard fprintd/PAM
  wiring, FreeBSD path conventions (`/usr/local/...` instead of `/etc/...` or
  `/lib/...`).
- **No mention of devfs.rules, devfs.conf, or a group-based device-permission recipe
  anywhere on the page** — the article covers software build/config, not USB device
  node permissions. §4 below covers what to actually do for that gap, sourced
  elsewhere.
- **No mention of Goodix devices, or any specific sensor family, anywhere on the
  page.** The scanners discussed are generic/Framework-laptop-oriented; the article is
  about getting the libfprint/fprintd stack itself running, not about any specific
  driver's hardware quirks.
- **Maintenance signal**: the author states intent to keep it updated ("I will keep
  this article up to date as I work on the new `libfprint` and `fprintd` ports"), and
  the one dated internal note about the port being fixed/upstreamed suggests at least
  one later pass. Beyond that, there's no visible changelog, version history, or last-
  modified stamp separate from the original publish date — actively maintained in
  intent, but its update cadence and last-touched date could not be independently
  confirmed from the fetched content.

**Bottom line on obiw.ac**: it's real, relevant, and corroborates two important facts
(the GUsb bug's existence and mechanism, and the correct meson invocation) but it is
a single unaffiliated author's personal notes, predates this project's driver by well
over a year, doesn't touch Goodix at all, and doesn't address device permissions. It's
useful as corroboration, not as a ready-made porting guide for this specific driver.

---

## 3. libfprint/fprintd upstream FreeBSD status

Contrary to the "very outdated" framing obiw.ac opened with in 2024, the FreeBSD ports
for both packages currently look actively maintained and reasonably current:

- **`security/libfprint`**: packaged at **1.94.10_1** (per the port's own `Makefile`,
  fetched via `cgit.freebsd.org/ports/plain/security/libfprint/Makefile`), maintained by
  `danfe@FreeBSD.org`. FreshPorts shows the package last touched **2026-07-14**, with a
  recent commit adding Focaltech MOC PID support as an "upstream-pending patch" —
  meaning the FreeBSD port maintainer is actively tracking upstream libfprint driver
  changes, not just doing periodic version bumps.
  ([cgit.freebsd.org/ports/tree/security/libfprint](https://cgit.freebsd.org/ports/tree/security/libfprint),
  [freshports.org/security/libfprint](https://www.freshports.org/security/libfprint/))
  - Build args confirmed in the port Makefile: `-Dinstalled-tests=`,
    `-Dudev_hwdb=disabled`, `-Dudev_rules=disabled` — the same pairing referenced above.
  - `LIB_DEPENDS` includes `libgusb.so:devel/libgusb` and `libpixman-1.so:x11/pixman`,
    confirming GUsb (not raw libusb) is what the packaged build actually links.
  - **This package does not, and cannot, include the `goodix533c` driver** — that driver
    only exists in this project's fork of libfprint, not upstream. The packaged port is
    useful evidence that the *dependency graph* resolves and libfprint's *core* builds
    cleanly on FreeBSD; it does not mean this project's fork can be `pkg install`ed. A
    from-source build of this project's fork (with `-Ddrivers=goodix533c` or an
    equivalent driver list) is still required — see Phase 1–2.
- **`security/fprintd`**: packaged at **1.94.4**, maintainer `danfe@FreeBSD.org`, last
  updated per FreshPorts around **2025-10-04** (a commit removing a libtool dependency
  and fixing FreeBSD 14 build compatibility). Build args confirmed:
  `-Dlibsystemd=basu -Dsystemd=false`, dependencies include `devel/basu` (a lightweight
  libsystemd-compatible D-Bus/sd-bus shim) and `sysutils/polkit`.
  ([freshports.org/security/fprintd](https://www.freshports.org/security/fprintd/))
  - Historical note found in search results: fprintd was reportedly *removed* from
    FreeBSD ports around mid-2022 when upstream was believed to require systemd
    outright, then *restored* in December 2022 once upstream adopted `basu` as a
    systemd-optional shim. Worth knowing as context for how fragile this integration
    point has been historically, even though it's currently packaged and apparently
    working.
- **General ecosystem state**: there is a real, if small, community actively pushing on
  FreeBSD fingerprint-reader support — the obiw.ac author, the
  `JohnAZoidberg/libfprint` `freebsd-usb` GitLab branch referenced by that article, and
  the FreeBSD ports maintainer(s) tracking upstream libfprint driver additions. This is
  meaningfully more infrastructure than "nothing exists," but it is still a niche
  corner of FreeBSD desktop support, not a first-class, heavily tested target the way
  Linux is for libfprint.

---

## 4. Dependency layer verification

| Dependency | FreeBSD status | Source | Risk |
|---|---|---|---|
| GLib / GObject | Packaged (`devel/glib`), long-established, foundational to much of the FreeBSD desktop stack (GNOME on FreeBSD depends on it). No FreeBSD-specific caveats found. | general knowledge, corroborated by libfprint's own port depending on it without incident | Low |
| GUsb (wraps libusb-1.0) | Packaged (`devel/libgusb`), and is what the FreeBSD `libfprint` port itself links against (`LIB_DEPENDS: libgusb.so:devel/libgusb`) — i.e., GUsb builds and links on FreeBSD today, as part of a package that's actively updated. **However**: GUsb's `g_usb_device_get_parent()` historically returned `NULL` on FreeBSD because the underlying `libusb_get_parent()` wasn't implemented in FreeBSD's base-system libusb (tracked as FreeBSD PR [224454](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=224454), fixed by [D46992](https://reviews.freebsd.org/D46992) "libusb: implement `libusb_get_parent`", committed to FreeBSD `main` per the commit mail on [lists.freebsd.org, 2025-06](https://lists.freebsd.org/archives/dev-commits-src-main/2025-June/032708.html)). This driver's own code never calls `get_parent()` — it only calls `g_usb_device_claim_interface`/`release_interface` — but **whether libfprint's core device-matching path calls `get_parent()` internally was not traced in this session**, and even if it doesn't block *this* driver, a `NULL`-returning `get_parent()` broke detection for *some* libfprint devices historically per obiw.ac's account, so the underlying fix landing matters for the ecosystem this driver sits in. The June 2025 fix is in FreeBSD `main` (HEAD) — **whether it has been merged back to a released stable/13 or stable/14 branch, and thus reaches ordinary `pkg`-based or GENERIC-kernel FreeBSD installs rather than only `-CURRENT`, is unverified.** No independent confirmation was found in this session that anyone has specifically exercised GUsb device *detection* (as opposed to just linking) against real hardware on FreeBSD post-fix. | mixed: port dependency confirmed working at link/package level; the specific historical bug and its fix are documented; live post-fix device-detection testing is not | **Medium** — the fix appears real and merged upstream, but its reach into what a typical FreeBSD install is running, and confirmation it actually resolves real-device detection (vs. just compiling), are both open questions |
| OpenSSL | FreeBSD has shipped a base-system OpenSSL (historically an older/LibreSSL-flavored branch depending on release) and/or the `security/openssl` port for a fully current version; either way OpenSSL is deeply embedded in the FreeBSD base and ports ecosystem. No FreeBSD-specific build issues surfaced in any source consulted. This driver's OpenSSL usage (`<openssl/ssl.h>`, `<openssl/crypto.h>`, `<openssl/err.h>`, `<openssl/tls1.h>`) is a standard, portable subset of the API. | general knowledge; not independently re-verified against a current FreeBSD release's exact OpenSSL version/ABI in this session | Low, but pin down which OpenSSL (base vs. port) the build will actually link against in Phase 1 — a version/ABI mismatch between base and ports OpenSSL is a known general FreeBSD gotcha, not specific to this driver |
| OpenCV (core, imgproc, features2d/features, flann) | Packaged as `graphics/opencv`, currently **4.13.0_8** per FreshPorts (checked 2026-08-18), maintained by `desktop@FreeBSD.org`, all core/imgproc/features2d/flann-equivalent modules included in one unified package (no separate sub-packages to chase). This driver's `meson.build` `sigfm` branch already tries `opencv5` then falls back to `opencv4` via pkg-config — FreeBSD's current 4.13.0 package is exactly the `opencv4` case this fallback already targets, so no build-file changes should be needed here. Recent FreeBSD-specific OpenCV port issues found (KleidiCV breaking aarch64 builds, PowerPC64LE definitions) are architecture-specific and irrelevant to a standard x86_64 FreeBSD desktop target. | [freshports.org/graphics/opencv](https://www.freshports.org/graphics/opencv/) | Low, contingent on targeting x86_64 |
| Meson / Ninja | Both packaged (`devel/meson`, `devel/ninja`), and are exactly what the FreeBSD `libfprint`/`fprintd` ports themselves use to build (confirmed in both ports' ecosystem via `USES=... meson`). | corroborated by libfprint/fprintd port Makefiles | Low |
| USB device permissions (devfs) | FreeBSD has no udev-rules equivalent; the analogous mechanism is `devfs.rules(5)` plus optionally `devfs.conf(5)`, activated via `devfs_system_ruleset` in `/etc/rc.conf`. The common community pattern for USB device classes generally (webcams, generic USB tools) is a rule like `add path 'usb/*' mode 0660 group <group>` (commonly `operator`, `usb`, or a purpose-made group such as `webcamd`'s convention), applied via a named ruleset, plus adding the relevant user to that group with `pw groupmod`. **This is a real, concrete gap for this specific driver**: `devfs.rules` path patterns match device *nodes* (`usb/*`, `ugen*`) by bus/topology, not by USB vendor:product ID the way a udev rule can match `ATTR{idVendor}=="27c6" ATTR{idProduct}=="533c"`. A broad `usb/*` rule would grant access to *all* USB devices under that group, which is coarser than the Linux udev-hwdb-driven per-device rule this project may be used to; a narrower rule tied specifically to this sensor's bus/port would not survive a replug to a different port. No FreeBSD-native equivalent of udev's attribute-matching was found. **Whether the FreeBSD `fprintd` port simply runs its daemon as root (sidestepping this entirely, the way many rc.d services do) rather than relying on devfs permissions was not verified in this session** — that would be the simplest path if true, and should be checked directly against the port's `rc.d` script in Phase 1. | community forum consensus + `devfs.rules(5)` man page, no FreeBSD-fingerprint-specific precedent found | Medium — solvable, but "figure this out later" is not acceptable per the task; §6 Phase 3 proposes the concrete starting point above and flags what needs checking first |

---

## 5. Portable-as-is vs. needs-real-work

**Portable as-is, no OS dependency at all:**
- The Goodix wire protocol codec (`goodix_proto.c/.h`) — pure byte-level
  framing/checksum logic.
- The embedded TLS-PSK server logic itself (the OpenSSL calls, the PSK
  callback/handshake state machine) — OS-independent aside from the pthread/socket
  scaffolding noted above, which is POSIX, not Linux-only.
- The SIGFM/OpenCV fingerprint-matching math (`sigfm/sigfm.cpp`, `goodix533c-match.c`'s
  logic) — pure C++/OpenCV, no OS calls.
- The frame decode/flat-field/squash math in `goodix533c.c` (`decode_frame`,
  `squash_frame_linear`, `flat_field_squash`, `compute_clipped_fraction`) — pure
  arithmetic over `guint16`/`double` buffers.

All of the above should port to FreeBSD with **zero source changes**, contingent only
on the toolchain (a C99/C++17 compiler — FreeBSD's base `clang` handles both) and the
libraries in §4 being present.

**Part of libfprint itself, whatever portability libfprint core has generally:**
- GObject/GLib plumbing: `FpiSsm` state machines, `G_DEFINE_TYPE`/`G_DECLARE_FINAL_TYPE`
  class registration, `FpDevice` vfunc wiring (`goodix533c_open`, `class_init`, etc.).
  This driver doesn't add anything new at this layer beyond what any other libfprint
  driver does — its portability rides entirely on libfprint core's, which §3 shows is
  actively packaged and maintained on FreeBSD today.
- `fpi_usb_transfer_*` itself — implemented once, in libfprint core
  (`fpi-usb-transfer.c`, not touched by this driver), as a wrapper over GUsb. If
  libfprint core builds and its GUsb dependency resolves on FreeBSD (§3/§4 say yes, with
  the `get_parent()` caveat noted), this layer needs no driver-specific porting work.

**Needs real, concrete porting work — not a recompile:**
- USB device access permissions (devfs.rules vs. udev rules) — §4/§6 Phase 3.
- Verifying the two direct `g_usb_device_claim_interface`/`release_interface` calls and
  the interaction with the historical `get_parent()` bug actually work end-to-end
  against real hardware — cannot be verified without a FreeBSD box + the sensor (§7).
- Anything in the build files (`meson.build`) that assumes a Linux-flavored default —
  none were found that are actually Linux-conditional (no `host_machine.system() ==
  'linux'` branches in either `meson.build` read), but this should be re-verified once
  `meson setup` is actually run on FreeBSD, since a configure-time failure is cheap to
  fix and easy to miss by reading alone.

**Development/debugging tooling, not the driver itself:**
- This project's own USB-protocol-capture workflow during RE relied on Linux's
  `usbmon` + Wireshark. FreeBSD has different packet-capture tooling for USB — the
  native mechanism is `usbdump(8)` / the base-system's USB packet capture via
  `ugen`/`usbdump`, and Wireshark on FreeBSD can read `usbdump`-format captures the same
  way it reads `usbmon` captures on Linux, though the capture-side tooling and syntax
  differ. This only matters if someone needs to re-verify wire-level behavior on FreeBSD
  hardware (e.g., debugging a FreeBSD-specific transfer failure) — it does not affect
  the driver's portability, only how someone would *debug* it there. Not independently
  verified against a current FreeBSD release in this session; flagged as a direction to
  check, not a confirmed recipe.

---

## 6. Phased plan

**Phase 0 — Confirm libfprint core actually builds on FreeBSD, before touching this driver.**
Stand up a FreeBSD VM or use existing FreeBSD hardware (no sensor needed yet). Either
`pkg install libfprint` (validates the packaged 1.94.10 build works at all — cheap
sanity check) or, more usefully, clone upstream `gitlab.freedesktop.org/libfprint/libfprint`
and run `meson setup -Ddrivers=default -Dudev_hwdb=disabled -Dudev_rules=disabled build`
to confirm a from-source build succeeds with the same flags this project's fork will
need. This isolates "does libfprint's core + GUsb + build system work on FreeBSD at
all" from "does this specific driver work," so a failure here is diagnosed against
upstream libfprint, not against this fork.

**Phase 1 — Dependency/build-system verification for this fork.**
On the same FreeBSD box, install `devel/glib`, `devel/libgusb`, `security/openssl` (or
confirm base OpenSSL is adequate), `graphics/opencv`, `devel/meson`, `devel/ninja`.
Clone this project's fork (the `goodix533c-open-capture` branch) and run `meson setup`
with `-Ddrivers=goodix533c` (or `default`, since `goodix533c` is already in
`default_drivers` per the top-level `meson.build`) and the same
`-Dudev_hwdb=disabled -Dudev_rules=disabled` pair. Goal: get meson to finish
*configuring* — i.e., every `dependency(...)` call in `meson.build` resolves — without
compiling anything yet. Also directly inspect the FreeBSD `fprintd` port's `rc.d`
script here to answer the "does fprintd run as root" question flagged in §4, since it
affects how much Phase 3 work is actually necessary.

**Phase 2 — Build this specific driver; catalog compile errors.**
Run the actual `ninja`/`meson compile` build. Predicted likely failure categories,
none confirmed since this couldn't be run in this session:
- GNU-specific compiler flags in `meson.build`'s `common_cflags`/`c_cflags` lists
  (things like `-Wlogical-op`, `-Wnested-externs`) that GCC supports but Clang doesn't
  — meson's `cc.get_supported_arguments()` calls already guard these by probing the
  compiler first, so this is more likely a silent flag-drop than a hard failure, but
  worth double-checking the resulting flag set on FreeBSD's base Clang.
- Possible symbol/header differences in less-common libc areas — nothing in this
  driver's own includes looks exotic (§1), so this is a low-probability guess, not a
  specific known issue.
- OpenCV pkg-config naming/module linkage — the driver's own `meson.build` fallback
  logic (`opencv5` → `opencv4`, `opencv_features2d` → `opencv_features`) was written
  defensively enough that it should already handle FreeBSD's current `opencv4`
  4.13.0 package, but this needs to be exercised, not just read.
This phase's output should be a concrete list of actual compiler/linker errors (or
confirmation of a clean build) — that list doesn't exist yet.

**Phase 3 — Device access / permissions.**
Contingent on Phase 1's finding about whether `fprintd` runs as root:
- If `fprintd` runs as root: little to do beyond confirming the device node appears
  (`usbconfig list` / `/dev/usb/...`) when the sensor is plugged in.
- If not: write a `devfs.rules(5)` ruleset scoping access to USB device nodes (starting
  point: `add path 'usb/*' mode 0660 group <group>`, activated via
  `devfs_system_ruleset` in `/etc/rc.conf`, with the daemon's user added to `<group>`
  via `pw groupmod`), accepting the coarser-than-udev granularity noted in §4 as a known
  limitation rather than trying to replicate udev's per-VID:PID matching, which
  `devfs.rules` doesn't support.
- Either way, add the PAM stanza obiw.ac quotes (`auth sufficient
  /usr/local/lib/security/pam_fprintd.so` in `/etc/pam.d/system`) for the login-integration
  path, and confirm `polkit` policy files needed by `fprintd` install correctly from the
  FreeBSD port.

**Phase 4 — Runtime testing. The hard, non-negotiable bottleneck.**
Requires: a FreeBSD machine, physically attached to a real 27c6:533c sensor, with
Phases 0–3 already done. This is the phase that actually validates the `g_usb_device_
claim_interface`/`release_interface` calls, the TLS-PSK handshake against real
hardware, image capture, and SIGFM matching — none of which can be exercised through
static analysis, and none of which was possible in this research session. If the
`get_parent()` fix's reach into the target FreeBSD release (§4) turns out not to have
landed, this is also where device detection itself could fail before anything
driver-specific is even reached. **This phase cannot start until someone acquires the
hardware/OS combination** — flagged again in §7 as the single largest open risk.

**Phase 5 — Upstreaming/packaging considerations, if Phase 4 succeeds.**
Only relevant after real-hardware validation. Would involve: deciding whether to
propose the `get_parent()`-adjacent findings or any FreeBSD-specific driver
`meson.build` fixes back to this project's own fork vs. upstream libfprint; whether the
FreeBSD ports maintainer (`danfe@FreeBSD.org`, per §3, actively tracking new libfprint
driver PIDs) would be a plausible contact for eventually getting `goodix533c` support
into the FreeBSD package once/if it's upstreamed to libfprint proper (this project's own
upstreaming plans are out of scope for this document). Not detailed further here since
it's contingent on multiple earlier phases succeeding first.

---

## 7. Risks and unknowns, stated plainly

- **No FreeBSD hardware with this sensor exists in this project, as far as this session
  could determine.** This is the single biggest risk and the actual reason this plan
  stops being verifiable past Phase 2. Everything in Phases 0–2 is desk-checkable by
  someone with FreeBSD familiarity; nothing from Phase 3 onward is, without acquiring
  the hardware/OS combination.
- **GUsb on FreeBSD**: confirmed to build and link (it's what the FreeBSD `libfprint`
  package itself depends on), and the specific historical `get_parent()` NULL-return bug
  has an upstream FreeBSD fix (D46992, June 2025) — but no source found in this session
  confirms anyone has specifically exercised GUsb *device detection* against real
  hardware on FreeBSD after that fix landed, as opposed to just confirming the package
  builds. Treat "GUsb device detection is known-good on FreeBSD" as **not established**,
  only "GUsb links and libfprint packages against it."
- **Fix reach**: the `get_parent()` fix landing in FreeBSD `main` (HEAD) in June 2025
  does not by itself establish it's in any released `stable/13` or `stable/14` branch,
  or in the `libusb` version a typical `pkg`-installed FreeBSD system is running today
  (2026-08-23). Unverified in this session — needs a direct check (`freebsd-version`,
  `pkg info libusb`, or checking the relevant `stable/*` branch's commit log) once a
  target FreeBSD release is chosen.
- **obiw.ac currency**: the article is over a year old at the time of this research,
  covers general libfprint/fprintd bring-up (not Goodix, not this driver), and its
  claim that FreeBSD package patches were "upstreamed" could only be confirmed
  secondhand via one edited note in the article itself plus this session's own
  independent check of the current port Makefiles (§3) — which did corroborate current,
  reasonably fresh packages. Treat the corroboration as real but the article itself as
  a starting point, not a maintained reference to keep returning to.
- **devfs permission model**: no FreeBSD-native equivalent of udev's per-VID:PID
  attribute matching was found; the proposed `devfs.rules` approach in Phase 3 is a
  reasonable, commonly-used pattern for USB device classes generally, but has **not**
  been found applied specifically to a fingerprint reader or to this sensor anywhere in
  this session's research. It's an inference from general FreeBSD USB-device practice,
  not a confirmed recipe for this use case.
- **Compile-error predictions in Phase 2 are exactly that — predictions, not findings.**
  This session had no FreeBSD compiler available to actually attempt the build. The
  categories listed are informed by reading the `meson.build` files and driver source,
  not by running anything.
- **This driver's own source audit (§1) is thorough but not exhaustive** — it covers
  `goodix533c*` and `goodixtls*` directly, and confirms no `#if`/`#ifdef` branches on
  `linux`/`__linux__` were seen, but a full grep across every header this driver
  transitively includes from libfprint core itself was not performed; if libfprint core
  has any Linux-conditional code paths relevant to this driver's usage pattern, that
  would only surface in Phase 0/1, not from this file-level read.
