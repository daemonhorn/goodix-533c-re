#!/bin/bash
# Boots the provisioned FreeBSD VM (see provision.sh) with the real
# 27c6:533c sensor passed through via QEMU usb-host, builds this project's
# packaging/freebsd-port/security/libfprint-goodix533c port against it, and
# runs the driver's own hardware-in-the-loop test (goodix533c-capture-test)
# against the real device.
#
# Mirrors vm/usbmon-capture-in-vm.sh's shape (cleanup trap, SSH-poll,
# scp-results-back) but targets a FreeBSD guest and a port build+capture
# test instead of a Linux usbmon capture.
#
# Runs with -snapshot: the VM disk is never modified, safe to interrupt or
# re-run. All expensive provisioning (pkg deps, the ports tree clone) must
# already be baked into freebsd-base.qcow2 by provision.sh -- this script
# does not install anything.
#
# Usage: vm/freebsd/build-and-test-in-vm.sh
# Requires: real 27c6:533c hardware attached (temporarily unusable on the
# host for the duration -- QEMU claims it directly via usb-host passthrough).
# Stop any host process that might grab the device first (e.g. fprintd):
#   sudo systemctl stop fprintd

set -uo pipefail

VMDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$VMDIR/.." && pwd)"
SSH_PORT=2223
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o IdentitiesOnly=yes -i "$VMDIR/vm_key" -p "$SSH_PORT")
SCP_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -i "$VMDIR/vm_key" -P "$SSH_PORT")
SSH_HOST=localhost
OUTDIR="$VMDIR/results"
PORT_SRC="$REPO/packaging/freebsd-port/security/libfprint-goodix533c"
PORT_DST=/usr/ports/security/libfprint-goodix533c

VENDOR_ID=27c6
PRODUCT_ID=533c

if ! lsusb -d ${VENDOR_ID}:${PRODUCT_ID} >/dev/null 2>&1; then
    echo "No ${VENDOR_ID}:${PRODUCT_ID} device found on the host -- is it plugged in?" >&2
    exit 1
fi
if pgrep -x fprintd >/dev/null 2>&1; then
    echo "fprintd is running on the host and may grab the device -- stop it first:" >&2
    echo "  sudo systemctl stop fprintd" >&2
    exit 1
fi

mkdir -p "$OUTDIR"
: > "$VMDIR/serial.log"

echo "Starting QEMU (snapshot mode, USB passthrough, SSH on localhost:$SSH_PORT)..."
qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 2 -m 2048 \
    -drive file="$VMDIR/freebsd-base.qcow2",if=virtio,snapshot=on \
    -cdrom "$VMDIR/seed.iso" \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -device qemu-xhci,id=xhci \
    -device usb-host,bus=xhci.0,vendorid=0x${VENDOR_ID},productid=0x${PRODUCT_ID} \
    -display none -serial file:"$VMDIR/serial.log" \
    -daemonize -pidfile "$VMDIR/qemu.pid"

cleanup() {
    if [[ -f "$VMDIR/qemu.pid" ]]; then
        QPID="$(cat "$VMDIR/qemu.pid" 2>/dev/null)"
        if [[ -n "${QPID:-}" ]] && kill -0 "$QPID" 2>/dev/null; then
            echo "Shutting down VM (pid $QPID)..."
            kill "$QPID" 2>/dev/null
            for _ in $(seq 1 20); do kill -0 "$QPID" 2>/dev/null || break; sleep 0.5; done
            kill -9 "$QPID" 2>/dev/null || true
        fi
        rm -f "$VMDIR/qemu.pid"
    fi
}
trap cleanup EXIT

echo "Waiting for SSH..."
SSH_UP=0
for _ in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" true 2>/dev/null; then SSH_UP=1; break; fi
    sleep 2
done
if [[ $SSH_UP -ne 1 ]]; then
    echo "SSH never came up -- check $VMDIR/serial.log" >&2
    exit 1
fi
echo "SSH is up."

echo "Confirming device visible inside guest (generic ugen(4), no driver conflict expected)..."
ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" "usbconfig list" | tee "$OUTDIR/usbconfig-list.txt"

echo "Syncing the port into the guest's ports tree..."
ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" "mkdir -p $PORT_DST"
scp "${SCP_OPTS[@]}" -r "$PORT_SRC"/* "root@$SSH_HOST:$PORT_DST/"

echo "Building the port (configure -> build -> stage -> check-plist -> package)..."
ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" "
    set -e
    cd $PORT_DST
    make clean
    make configure
    make build
    make stage
    make check-plist
    make package
    echo BUILD_OK
" | tee "$OUTDIR/build.log"
grep -q BUILD_OK "$OUTDIR/build.log" || { echo "Port build failed -- see $OUTDIR/build.log" >&2; exit 1; }

BUILDDIR_REL="work/$(ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" "ls $PORT_DST/work | grep '^libfprint-'")/_build"
echo "Running the hardware capture test from the build tree ($BUILDDIR_REL)..."
echo "(reference frame only is automated; a finger-present '-live' capture needs a"
echo " human to actually touch the sensor within the timeout -- not attempted here.)"
ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" "
    cd $PORT_DST/$BUILDDIR_REL
    LD_LIBRARY_PATH=libfprint timeout 60 ./libfprint/goodix533c-capture-test /root/out.pgm
    echo 'capture_test exit:' \$?
" | tee "$OUTDIR/capture-test.log"

echo "Pulling results back..."
scp "${SCP_OPTS[@]}" "root@$SSH_HOST:/root/out.pgm" "$OUTDIR/freebsd-reference.pgm" 2>&1 || true

echo
echo "Results in $OUTDIR:"
ls -la "$OUTDIR"
echo "done"
