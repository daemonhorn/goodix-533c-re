#!/bin/bash
# Builds a libfprint-2-2_<version>_amd64.deb from the vendor/libfprint-goodixtls
# submodule, with the full default driver set (all of Debian's own
# default_drivers) plus goodix533c -- so installing this doesn't regress
# support for any other fingerprint reader.
#
# This REPLACES the system libfprint-2-2 package (same package name), so
# fprintd/PAM actually use the new driver -- unlike packaging/build.sh's
# goodix-533c-test, which is a standalone diagnostic tool with no system
# integration.
#
# Requires: meson, ninja, a C/C++ toolchain, libopencv-dev (or the
# individual core/imgproc/features2d/flann -dev packages), libnss3-dev,
# libudev-dev, dpkg-dev, fakeroot. Debian trixie's `udev.pc` is provided
# under the name `libudev.pc` without the `udevdir` variable meson.build
# needs -- this script works around that with a local pkg-config shim
# rather than patching the submodule; see PKGCONFIG_SHIM below.
#
# Usage: bash packaging/build-libfprint-deb.sh [version-suffix]
#   version-suffix defaults to "goodix533c1".
#
#   Package version is derived from the CURRENTLY INSTALLED system
#   libfprint-2-2's epoch:upstream-version (via dpkg-query), not from this
#   submodule's own (older) meson.build version string -- e.g. if the
#   system has 1:1.94.9-1 installed, this builds 1:1.94.9-0<suffix>.
#   That's deliberate, not a typo: fprintd's own Depends: floor
#   (`libfprint-2-2 (>= 1:1.94.9)` on trixie) is versioned independently
#   of fprintd's own upstream version and of what this submodule reports,
#   so the package version has to satisfy *that* floor regardless of what
#   the actual driver code is based on -- using a lower version (e.g. the
#   submodule's own 1.94.5) breaks `apt` for every other package the
#   moment anything depends on a newer libfprint-2-2 than this submodule's
#   version claims, exactly as fprintd does here. The `-0<suffix>` Debian
#   revision (vs. the real package's `-1`) still sorts lower than the
#   actual distro package, so a plain `apt upgrade` reverts to it on its
#   own -- satisfying the floor and staying a "revert on upgrade" test
#   build are not in tension, they just both have to be checked.
#
#   Falls back to a hardcoded 1:1.94.9 if libfprint-2-2 isn't currently
#   installed (e.g. building in a container) -- check this still matches
#   your target system's actual reverse-dependency floors before relying
#   on that fallback; `apt-cache show fprintd | grep Depends` on the
#   target system is the authoritative check.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO_ROOT/vendor/libfprint-goodixtls"
OUT_DIR="$REPO_ROOT/packaging/out"
VERSION_SUFFIX="${1:-goodix533c1}"

if [ ! -f "$SRC/meson.build" ]; then
    echo "vendor/libfprint-goodixtls submodule not checked out." >&2
    echo "Run: git submodule update --init vendor/libfprint-goodixtls" >&2
    exit 1
fi

# Use apt-cache policy's Candidate line, not dpkg-query's Installed
# version -- if this system already has an earlier build of THIS package
# installed via `dpkg -i`, dpkg-query would just report that back
# (possibly itself too low), while Candidate reflects the actual
# highest-priority repo version regardless of what's force-installed
# locally.
CANDIDATE_FULL_VERSION=$(apt-cache policy libfprint-2-2 2>/dev/null \
    | sed -n 's/^  Candidate: //p')
if [ -n "$CANDIDATE_FULL_VERSION" ] && [ "$CANDIDATE_FULL_VERSION" != "(none)" ]; then
    # Strip the Debian revision (everything from the last '-' on), keep epoch:upstream.
    BASE_VERSION="${CANDIDATE_FULL_VERSION%-*}"
else
    echo "No repo candidate found for libfprint-2-2; falling back to a hardcoded" >&2
    echo "1:1.94.9 floor. Verify this against 'apt-cache show fprintd | grep Depends'" >&2
    echo "on the actual target system before trusting this build." >&2
    BASE_VERSION="1:1.94.9"
fi
PKG_VERSION="${BASE_VERSION}-0${VERSION_SUFFIX}"

# Guard against exactly the bug this versioning scheme exists to avoid:
# any currently-installed reverse-dependency's floor on libfprint-2-2
# that our computed version wouldn't satisfy. dpkg -s prints "ok" status
# lines like "install ok installed"; grep for that specifically so a
# purged/removed-but-config-remaining package doesn't false-positive.
for revdep in $(apt-cache rdepends --installed libfprint-2-2 2>/dev/null | tail -n +3); do
    floor=$(dpkg-query -W -f='${Depends}' "$revdep" 2>/dev/null \
        | grep -oP 'libfprint-2-2 \(>= \K[^)]*' || true)
    if [ -n "$floor" ] && ! dpkg --compare-versions "$PKG_VERSION" ge "$floor"; then
        echo "ERROR: computed version $PKG_VERSION does not satisfy" >&2
        echo "$revdep's floor of libfprint-2-2 (>= $floor) -- installing this" >&2
        echo "package would break apt exactly like the goodix533c1 build did." >&2
        exit 1
    fi
done

DEFAULT_DRIVERS=$(python3 - "$SRC/meson.build" << 'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"default_drivers = \[(.*?)\]", src, re.S)
names = re.findall(r"'([a-zA-Z0-9_]+)'", m.group(1))
print(",".join(names))
PYEOF
)
DRIVERS="${DEFAULT_DRIVERS},goodix533c"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# meson.build's dependency('udev') expects a pkg-config file literally
# named udev.pc with a `udevdir` variable; Debian trixie only ships
# libudev.pc (for linking against libudev, no udevdir variable). Shim it
# locally rather than touching the submodule.
PKGCONFIG_SHIM="$WORK/pkgconfig-shim"
mkdir -p "$PKGCONFIG_SHIM"
cat > "$PKGCONFIG_SHIM/udev.pc" << 'EOF'
udevdir=/usr/lib/udev
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib/x86_64-linux-gnu
includedir=/usr/include

Name: udev
Description: Library to access udev device information
Version: 257
Libs: -L${libdir} -ludev
Libs.private: -lrt -pthread
Cflags: -I${includedir}
EOF

BUILDDIR="$SRC/builddir-release"
rm -rf "$BUILDDIR"
cd "$SRC"
PKG_CONFIG_PATH="$PKGCONFIG_SHIM${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
meson setup "$BUILDDIR" \
    --prefix=/usr \
    --libdir=lib/x86_64-linux-gnu \
    --buildtype=release \
    -Ddrivers="$DRIVERS" \
    -Dudev_rules=enabled \
    -Dudev_hwdb=enabled \
    -Dintrospection=false \
    -Ddoc=false

ninja -C "$BUILDDIR"

DESTDIR="$WORK/pkg-root"
DESTDIR="$DESTDIR" ninja -C "$BUILDDIR" install

# Assemble the package tree scoped to runtime files only (matching
# Debian's own libfprint-2-2 -- headers/pkgconfig/.so symlink belong to
# libfprint-2-dev, not built or packaged here).
PKGDIR="$WORK/deb-final"
mkdir -p "$PKGDIR/DEBIAN"
mkdir -p "$PKGDIR/usr/lib/x86_64-linux-gnu" \
         "$PKGDIR/usr/lib/udev/rules.d" "$PKGDIR/usr/lib/udev/hwdb.d" \
         "$PKGDIR/usr/share/doc/libfprint-2-2"

strip --strip-unneeded -o "$PKGDIR/usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0" \
    "$DESTDIR/usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0"
ln -s libfprint-2.so.2.0.0 "$PKGDIR/usr/lib/x86_64-linux-gnu/libfprint-2.so.2"
cp "$DESTDIR/usr/lib/udev/rules.d/70-libfprint-2.rules" "$PKGDIR/usr/lib/udev/rules.d/"
cp "$DESTDIR/usr/lib/udev/hwdb.d/60-autosuspend-libfprint-2.hwdb" "$PKGDIR/usr/lib/udev/hwdb.d/"

cat > "$PKGDIR/usr/share/doc/libfprint-2-2/README.local-build" << EOF
This is a local test build of libfprint with a new native driver for the
Goodix 27c6:533c fingerprint sensor (GF5288 silicon, TLS-PSK transport),
built from branch goodix533c-open-capture at
https://github.com/daemonhorn/libfprint (PR:
https://github.com/goodix-fp-linux-dev/libfprint/pull/40).

Not an official Debian package. To revert to the distro package:
  sudo apt install --reinstall libfprint-2-2
EOF

cat > "$PKGDIR/usr/share/doc/libfprint-2-2/copyright" << 'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: libfprint
Upstream-Contact: fprint@lists.freedesktop.org
Source: https://github.com/goodix-fp-linux-dev/libfprint (branch goodixtls)
 and https://github.com/daemonhorn/libfprint (branch
 goodix533c-open-capture, this build's actual source)

Files: *
Copyright: 2007-2026 The Freedesktop.org libfprint contributors
License: LGPL-2.1

Files: sigfm/*
Copyright: AndyHazz and contributors to goodix53x5-libfprint
License: LGPL-2.1

License: LGPL-2.1
 This library is free software; you can redistribute it and/or modify it
 under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation; either version 2.1 of the License, or (at
 your option) any later version.
 .
 This library is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
 General Public License for more details.
 .
 On Debian systems, the complete text of the GNU Lesser General Public
 License version 2.1 can be found in
 "/usr/share/common-licenses/LGPL-2.1".
EOF

cat > "$WORK/changelog.Debian" << EOF
libfprint-2 (${PKG_VERSION}) local; urgency=low

  * Local test build adding a native driver for the Goodix 27c6:533c
    fingerprint sensor. Not an official Debian package.
  * Source: https://github.com/daemonhorn/libfprint, branch
    goodix533c-open-capture. Submitted upstream as
    https://github.com/goodix-fp-linux-dev/libfprint/pull/40

 -- $(git -C "$REPO_ROOT" config user.name 2>/dev/null || echo "local build") <$(git -C "$REPO_ROOT" config user.email 2>/dev/null || echo "local@localhost")>  $(date -R)
EOF
gzip -9 -n -c "$WORK/changelog.Debian" > "$PKGDIR/usr/share/doc/libfprint-2-2/changelog.Debian.gz"

cat > "$PKGDIR/DEBIAN/shlibs" << 'EOF'
libfprint-2 2 libfprint-2-2 (>= 1.94.5)
EOF

cat > "$PKGDIR/DEBIAN/triggers" << 'EOF'
activate-noawait ldconfig
EOF

cat > "$PKGDIR/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e

if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm hwdb --update 2>/dev/null || true
    udevadm trigger --subsystem-match=usb 2>/dev/null || true
fi

if command -v deb-systemd-invoke >/dev/null 2>&1; then
    deb-systemd-invoke try-restart fprintd.service || true
fi

exit 0
EOF

# Compute the real Depends: line from the actual linked libraries rather
# than hand-maintaining it (OpenCV/SIGFM's transitive deps in particular
# change across versions).
mkdir -p "$WORK/shlibdeps-ctx/debian"
cp -a "$PKGDIR/usr" "$WORK/shlibdeps-ctx/"
echo "Source: libfprint-2" > "$WORK/shlibdeps-ctx/debian/control"
echo >> "$WORK/shlibdeps-ctx/debian/control"
echo "Package: libfprint-2-2" >> "$WORK/shlibdeps-ctx/debian/control"
echo "Architecture: amd64" >> "$WORK/shlibdeps-ctx/debian/control"
echo "Depends: \${shlibs:Depends}" >> "$WORK/shlibdeps-ctx/debian/control"
DEPENDS_LINE=$(cd "$WORK/shlibdeps-ctx" && \
    dpkg-shlibdeps -O usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0 \
    | sed -n 's/^shlibs:Depends=//p')
# VAR=$(cmd) doesn't trip `set -e` on cmd's own failure (a classic bash
# gotcha), so check explicitly rather than silently package a broken
# Depends: line.
if [ -z "$DEPENDS_LINE" ]; then
    echo "ERROR: dpkg-shlibdeps produced no shlibs:Depends output -- see" >&2
    echo "the dpkg-shlibdeps error above." >&2
    exit 1
fi
DEPENDS_LINE="${DEPENDS_LINE}, init-system-helpers (>= 1.54~)"

cat > "$PKGDIR/DEBIAN/control" << EOF
Package: libfprint-2-2
Version: ${PKG_VERSION}
Architecture: amd64
Maintainer: $(git -C "$REPO_ROOT" config user.name 2>/dev/null || echo "local build") <$(git -C "$REPO_ROOT" config user.email 2>/dev/null || echo "local@localhost")>
Section: libs
Priority: optional
Depends: ${DEPENDS_LINE}
Description: async fingerprint library of fprint project, shared libraries
 Local test build of libfprint including a new native driver for the
 Goodix 27c6:533c fingerprint sensor. NOT an official Debian package.
 Version is deliberately lower than the distro package so a normal
 \`apt upgrade\` will revert to it automatically.
 .
 Source: https://github.com/daemonhorn/libfprint (branch
 goodix533c-open-capture), submitted upstream as
 https://github.com/goodix-fp-linux-dev/libfprint/pull/40
EOF

find "$PKGDIR" -type f -not -path "*/DEBIAN/*" -exec chmod 644 {} \;
find "$PKGDIR" -type d -exec chmod 755 {} \;
chmod 644 "$PKGDIR/DEBIAN/control" "$PKGDIR/DEBIAN/triggers" "$PKGDIR/DEBIAN/shlibs"
chmod 755 "$PKGDIR/DEBIAN/postinst"

mkdir -p "$OUT_DIR"
# Debian package filenames conventionally omit the epoch (and a literal
# ':' is awkward in filenames/URLs regardless) -- keep it in the control
# file's Version: field (already written above) but strip it here.
FILENAME_VERSION="${PKG_VERSION#*:}"
DEB_OUT="$OUT_DIR/libfprint-2-2_${FILENAME_VERSION}_amd64.deb"
fakeroot dpkg-deb --build --root-owner-group "$PKGDIR" "$DEB_OUT"

echo "Built: $DEB_OUT"
if command -v lintian >/dev/null 2>&1; then
    lintian "$DEB_OUT" || true
fi
