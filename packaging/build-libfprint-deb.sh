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
#   version-suffix defaults to "goodix533c1". Full package version is
#   "<libfprint's own meson.build version>-0<version-suffix>", e.g.
#   1.94.5-0goodix533c1 -- deliberately lower than the distro package
#   (currently 1:1.94.9-1) so a plain `apt upgrade` reverts to the
#   official package on its own.

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

UPSTREAM_VERSION=$(grep -m1 "version: '" "$SRC/meson.build" | sed "s/.*version: '\([^']*\)'.*/\1/")
PKG_VERSION="${UPSTREAM_VERSION}-0${VERSION_SUFFIX}"

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
echo "Package: libfprint-2-2" > "$WORK/shlibdeps-ctx/debian/control"
echo "Depends: \${shlibs:Depends}" >> "$WORK/shlibdeps-ctx/debian/control"
DEPENDS_LINE=$(cd "$WORK/shlibdeps-ctx" && \
    dpkg-shlibdeps -O usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0 2>/dev/null \
    | sed -n 's/^shlibs:Depends=//p')
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
DEB_OUT="$OUT_DIR/libfprint-2-2_${PKG_VERSION}_amd64.deb"
fakeroot dpkg-deb --build --root-owner-group "$PKGDIR" "$DEB_OUT"

echo "Built: $DEB_OUT"
if command -v lintian >/dev/null 2>&1; then
    lintian "$DEB_OUT" || true
fi
