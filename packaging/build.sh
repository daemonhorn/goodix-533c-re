#!/bin/sh
# Builds goodix-533c-test_<version>_all.deb from packaging/goodix-533c-test/
# plus the driver source vendored at vendor/goodix-fp-dump-nikicat.
#
# Requires: dpkg-deb, fakeroot. Run from the repo root:
#   sh packaging/build.sh
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO_ROOT/vendor/goodix-fp-dump-nikicat"
PKG="$REPO_ROOT/packaging/goodix-533c-test"
OUT_DIR="$REPO_ROOT/packaging/out"

if [ ! -f "$SRC/driver_53xc.py" ]; then
    echo "vendor/goodix-fp-dump-nikicat submodule not checked out." >&2
    echo "Run: git submodule update --init vendor/goodix-fp-dump-nikicat" >&2
    exit 1
fi

VERSION=$(grep -m1 '^Version:' "$PKG/DEBIAN/control" | cut -d' ' -f2)

mkdir -p "$PKG/usr/share/goodix-533c-test"
cp "$SRC/driver_53xc.py" "$SRC/goodix.py" "$SRC/protocol.py" "$SRC/tool.py" \
    "$PKG/usr/share/goodix-533c-test/"
cp "$SRC/LICENSE" "$PKG/usr/share/doc/goodix-533c-test/LICENSE.upstream"

find "$PKG" -type f -exec chmod 644 {} \;
chmod 755 "$PKG/usr/bin/goodix-533c-capture" "$PKG/DEBIAN/postinst"
find "$PKG" -type d -exec chmod 755 {} \;

mkdir -p "$OUT_DIR"
fakeroot dpkg-deb --build --root-owner-group "$PKG" \
    "$OUT_DIR/goodix-533c-test_${VERSION}_all.deb"

echo "Built: $OUT_DIR/goodix-533c-test_${VERSION}_all.deb"
