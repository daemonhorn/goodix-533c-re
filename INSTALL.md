# Installing on Debian 13

Two separate test packages exist, from two different points in this
project. Pick the one that matches what you want:

- **[libfprint-2-2 driver build](#libfprint-2-2-driver-build-real-fprintdpam-integration)**
  — the real thing. A full `libfprint` build with a native `goodix533c`
  driver, matched with SIGFM host-side matching. Replaces your system
  `libfprint-2-2`; `fprintd`/PAM actually use it. This is what you want
  if you want your `27c6:533c` sensor working for real login/`sudo`/unlock.
- **[goodix-533c-test capture tool](#goodix-533c-test-standalone-capture-tool)**
  — an earlier, standalone diagnostic tool that only proves the wire
  protocol works and dumps a raw image. No `fprintd`/PAM integration at
  all. Superseded by the driver build above for anyone who just wants
  fingerprint auth working; still useful for low-level protocol
  debugging.

---

## `libfprint-2-2` driver build (real fprintd/PAM integration)

**TEST build, not an official Debian package.** Read this whole section
before installing — it replaces your system `libfprint-2-2`.

### What you get

A `libfprint-2-2` build from
[`daemonhorn/libfprint`](https://github.com/daemonhorn/libfprint) branch
`goodix533c-open-capture` (submitted upstream as
[goodix-fp-linux-dev/libfprint#40](https://github.com/goodix-fp-linux-dev/libfprint/pull/40)),
including:

- A native `goodix533c` driver: `FpDeviceClass`-based, real TLS-PSK
  transport, SIGFM (SIFT+CLAHE) host-side matching. `enroll`/`verify`/
  `identify` all wired in and verified against real hardware.
- All of Debian's other default drivers, unchanged — installing this does
  not remove support for any other fingerprint reader.

This **does** integrate with `fprintd`, PAM, and (depending on your
desktop) login/unlock screens, exactly like the stock package — it's a
drop-in replacement, not a side-by-side tool.

### Install

Download the `.deb` from the
[Releases page](https://github.com/daemonhorn/goodix-533c-re/releases)
(tag `libfprint-<version>`), then:

```sh
sudo dpkg -i libfprint-2-2_<version>_amd64.deb
```

The postinst reloads udev rules/hwdb and restarts `fprintd` if it's
already running — no reboot or logout needed.

**The package's epoch:upstream-version matches whatever the current
Debian package's is** (e.g. `1:1.94.9`, not this submodule's own older
`1.94.5`) **— only the Debian revision is lower** (e.g. `-0goodix533c1`
vs. the distro's `-1`). This is deliberate, not a typo: some reverse
dependencies (`fprintd`, notably) declare a `Depends: libfprint-2-2 (>=
...)` floor independently of their own version number, and installing
anything below that floor breaks `apt` for every other package until
manually fixed — an earlier release of this package got this wrong
(built as plain `1.94.5-0goodix533c1`) and did exactly that; see
`packaging/build-libfprint-deb.sh`'s comments for the full explanation.
Matching the epoch:upstream-version while keeping a lower revision
satisfies every current floor *and* still reverts to the official
package on a plain `apt upgrade` — this is a test build, not meant to
quietly stick around forever.

### Use

```sh
fprintd-enroll
```

Touch and lift the sensor for each of the (up to 8) prompted stages,
lifting your finger fully between touches — a finger still resting on
the sensor when the next stage starts will corrupt that stage's capture.

```sh
fprintd-verify
```

Should report a match against a fresh touch. From here, anything that
already uses `fprintd`/`libpam-fprintd` on your system (GNOME/KDE
fingerprint settings, `pam_fprintd` for `sudo`, etc.) should pick up the
enrolled print normally.

### Pin it (optional — keep it past the next `apt upgrade`)

By design, a plain `apt upgrade` will revert this package to the official
one on its own (see "Install" above) — that's usually what you want for a
test build. If you want to keep testing longer without that happening,
pin it:

```sh
sudo tee /etc/apt/preferences.d/libfprint-2-2-goodix533c-pin << 'EOF'
Package: libfprint-2-2
Pin: version 1.94.9-0goodix533c1
Pin-Priority: 1001
EOF
```

Match `version` to whatever's actually in `apt-cache policy
libfprint-2-2`'s `Installed:` line for your build. **Priority has to be
greater than 1000** — that's the specific threshold `apt_preferences(5)`
documents as letting apt select a version even when it's lower than the
repo candidate (anything ≤1000 still won't override apt's normal
"never auto-downgrade" behavior).

Verify with `apt-cache policy libfprint-2-2` — the currently-installed
version should show priority `1001`. To stop pinning and let the next
`apt upgrade` revert to the official package as originally intended:

```sh
sudo rm /etc/apt/preferences.d/libfprint-2-2-goodix533c-pin
```

### Roll back

```sh
sudo apt install --reinstall libfprint-2-2
```

Reinstalls the official Debian package over this one. Your enrolled
prints are stored separately (per-user, under
`~/.var/lib/fprint` or similar, managed by `fprintd`) and aren't affected
by swapping the library.

### Building it yourself

```sh
git clone git@github.com:daemonhorn/libfprint.git
cd libfprint
git checkout goodix533c-open-capture
meson setup builddir --prefix=/usr --libdir=lib/x86_64-linux-gnu \
    --buildtype=release -Dudev_rules=enabled -Dudev_hwdb=enabled \
    -Dintrospection=false -Ddoc=false \
    -Ddrivers=<full driver list -- see meson.build's default_drivers,
               plus goodix533c>
ninja -C builddir
```

Needs `libopencv-dev` (or the individual `opencv4`-providing `-dev`
packages: core/imgproc/features2d/flann) for SIGFM, on top of libfprint's
normal build dependencies. See `packaging/build-libfprint-deb.sh` in this
repo for the exact commands used to produce the release `.deb`
(dependency resolution via `dpkg-shlibdeps`, package layout, etc.).

---

## `goodix-533c-test` (standalone capture tool)

**TEST / EXPERIMENTAL.** This is a standalone capture tool, not a driver
that logs you in. Read this whole page before installing.

### What you get

`goodix-533c-capture` — a command-line tool that talks to the real
`27c6:533c` sensor using an open-source reimplementation of its USB
protocol, and writes a raw `.pgm` image file. That's it.

### What you do NOT get

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

### Install

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

### Use

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

### Uninstall

```sh
sudo apt remove goodix-533c-test
```

### Reporting results

Whether it works cleanly, partially, or not at all on your unit, please
report back — more independently-tested units is exactly what's needed
to resolve the open image-quality question. Open an issue on this repo,
or comment on
[upstream PR #75](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/pull/75),
which is where the underlying driver code comes from (unmerged at the
time of this packaging).

### Building the capture tool yourself

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
