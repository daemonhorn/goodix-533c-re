#!/bin/bash
# Boots the existing goodix-re-vm (Ubuntu 20.04 cloud image, already
# provisioned with tshark/usbmon/wireshark-group via cloud-init), passes
# the real 27c6:533c sensor through via QEMU usb-host, and runs the
# finger-absent capture_fixture_session.py *inside the guest* while
# capturing usbmon there.
#
# Why: the host kernel has lockdown=confidentiality active, which makes
# usbmon redact all bulk-IN payload data (confirmed: binary interface
# reports correct URB lengths but always 0 captured bytes; text interface
# returns EPERM even as root) -- this is intentional kernel behavior
# (LOCKDOWN_USB), not fixable via capture tool choice. The guest VM has
# its own unmodified, non-Secure-Boot kernel with no lockdown, so the
# same capture works there. This mirrors the approach already used
# successfully earlier in this project for a different capture -- see
# findings/vm-capture-analysis.md.
#
# Runs with -snapshot: the VM disk image is never modified, so this is
# safe to interrupt or re-run. Everything of value is pulled back to the
# host over scp before the VM is torn down. Trade-off: every run
# reinstalls python3-usb/pip/pycryptodome/python-periphery/spidev from
# scratch (~10 apt packages plus a spidev source build) since none of it
# persists. If you're iterating on this script rather than doing a single
# capture, drop `snapshot=on` from the -drive line and boot once first to
# bake those deps into the base image -- saves several minutes per run.
#
# Usage: vm/usbmon-capture-in-vm.sh
# Requires: real 27c6:533c hardware attached (temporarily unusable on the
# host for the duration -- QEMU claims it directly via usb-host passthrough).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMDIR="$REPO/vm"
SSH_PORT=2222
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -i "$VMDIR/vm_key" -p "$SSH_PORT")
SCP_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -i "$VMDIR/vm_key" -P "$SSH_PORT")
SSH_USER=re
SSH_HOST=localhost
OUTDIR="$VMDIR/usbmon-diag-out"

VENDOR_ID=27c6
PRODUCT_ID=533c

if ! lsusb -d ${VENDOR_ID}:${PRODUCT_ID} >/dev/null 2>&1; then
    echo "No ${VENDOR_ID}:${PRODUCT_ID} device found on the host -- is it plugged in?" >&2
    exit 1
fi

mkdir -p "$OUTDIR"
: > "$VMDIR/serial.log"

echo "Starting QEMU (snapshot mode, USB passthrough, SSH on localhost:$SSH_PORT)..."
qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 2 -m 2048 \
    -drive file="$VMDIR/focal-server-cloudimg-amd64.img",if=virtio,snapshot=on \
    -cdrom "$VMDIR/seed.iso" \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -device qemu-xhci,id=xhci \
    -device usb-host,bus=xhci.0,vendorid=0x${VENDOR_ID},productid=0x${PRODUCT_ID} \
    -display none -serial file:"$VMDIR/serial.log" \
    -daemonize -pidfile "$VMDIR/qemu.pid"

QEMU_STATUS=$?
if [[ $QEMU_STATUS -ne 0 ]]; then
    echo "qemu-system-x86_64 failed to start (exit $QEMU_STATUS)" >&2
    exit 1
fi

cleanup() {
    if [[ -f "$VMDIR/qemu.pid" ]]; then
        QPID="$(cat "$VMDIR/qemu.pid" 2>/dev/null)"
        if [[ -n "${QPID:-}" ]] && kill -0 "$QPID" 2>/dev/null; then
            echo "Shutting down VM (pid $QPID)..."
            kill "$QPID" 2>/dev/null
            for _ in $(seq 1 20); do
                kill -0 "$QPID" 2>/dev/null || break
                sleep 0.5
            done
            kill -9 "$QPID" 2>/dev/null || true
        fi
        rm -f "$VMDIR/qemu.pid"
    fi
}
trap cleanup EXIT

echo "Waiting for SSH..."
SSH_UP=0
for _ in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" true 2>/dev/null; then
        SSH_UP=1
        break
    fi
    sleep 2
done

if [[ $SSH_UP -ne 1 ]]; then
    echo "SSH never came up -- check $VMDIR/serial.log" >&2
    exit 1
fi
echo "SSH is up."

echo "Confirming device visible inside guest..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "lsusb -d ${VENDOR_ID}:${PRODUCT_ID}"

echo "Copying capture script + driver into guest..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "mkdir -p ~/goodix-capture/driver"
scp "${SCP_OPTS[@]}" "$REPO/capture_fixture_session.py" "$SSH_USER@$SSH_HOST:~/goodix-capture/"
scp "${SCP_OPTS[@]}" "$REPO/vendor/goodix-fp-dump-nikicat/driver_53xc.py" \
    "$REPO/vendor/goodix-fp-dump-nikicat/goodix.py" \
    "$REPO/vendor/goodix-fp-dump-nikicat/tool.py" \
    "$REPO/vendor/goodix-fp-dump-nikicat/protocol.py" \
    "$SSH_USER@$SSH_HOST:~/goodix-capture/driver/"

echo "Patching PEP 604/585 type-hint syntax for this guest's Python 3.8 (defer via __future__ annotations)..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
    "sed -i '1i from __future__ import annotations' ~/goodix-capture/driver/goodix.py ~/goodix-capture/driver/protocol.py ~/goodix-capture/driver/tool.py"
# driver_53xc.py opens with a module docstring -- the future-import must
# come after it, not at line 1 (Python only allows a docstring, comments,
# blank lines, and other future statements before a future import).
scp "${SCP_OPTS[@]}" "$VMDIR/patch_future_annotations.py" "$SSH_USER@$SSH_HOST:~/goodix-capture/"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
    "python3 ~/goodix-capture/patch_future_annotations.py ~/goodix-capture/driver/driver_53xc.py"

echo "Installing pyusb + pycryptodome in guest (idempotent; tshark/openssl already provisioned via cloud-init)..."
# The apt python3-usb package (1.0.2) predates usb.core.USBTimeoutError,
# which goodix.py relies on -- pip install a current pyusb instead so the
# exception class exists, rather than patching goodix.py for guest-only
# version skew.
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
    "sudo apt-get install -y -qq libusb-1.0-0 python3-pip && sudo pip3 install --quiet --upgrade pyusb pycryptodome python-periphery spidev; python3 -c 'import usb.core; usb.core.USBTimeoutError; from Crypto.Cipher import AES; import periphery; import spidev' && echo deps OK"

echo "Running tshark capture + capture_fixture_session.py inside guest..."
# capture_fixture_session.py needs sudo too (re isn't in plugdev-equivalent
# here, pyusb raises Access Denied otherwise); system-wide pip installs
# above (no --user) keep the packages visible under sudo regardless of HOME.
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" '
    set -u
    cd ~/goodix-capture
    BUSNUM="$(lsusb -d 27c6:533c | sed -n "s/^Bus \([0-9]\+\).*/\1/p")"
    IFACE="usbmon$((10#$BUSNUM))"
    echo "guest interface: $IFACE"
    sudo timeout 90 tshark -i "$IFACE" -w /tmp/capture-guest.pcapng -q &
    TSHARKPID=$!
    sleep 1
    sudo env "PYTHONPATH=driver" python3 capture_fixture_session.py > /tmp/capture-guest.log 2>&1
    echo "session exit: $?" >> /tmp/capture-guest.log
    sleep 1
    sudo kill -INT $TSHARKPID 2>/dev/null
    wait $TSHARKPID 2>/dev/null
    sudo chown "$(whoami):$(whoami)" /tmp/capture-guest.pcapng /tmp/capture-guest.log
    [ -f fixture-reference.pgm ] && sudo chown "$(whoami):$(whoami)" fixture-reference.pgm
    tail -5 /tmp/capture-guest.log
    echo "pcapng packet count: $(tshark -r /tmp/capture-guest.pcapng 2>/dev/null | wc -l)"
'

echo "Pulling results back..."
scp "${SCP_OPTS[@]}" "$SSH_USER@$SSH_HOST:/tmp/capture-guest.log" "$OUTDIR/" 2>&1 || true
scp "${SCP_OPTS[@]}" "$SSH_USER@$SSH_HOST:~/goodix-capture/fixture-reference.pgm" "$OUTDIR/" 2>&1 || true
scp "${SCP_OPTS[@]}" "$SSH_USER@$SSH_HOST:/tmp/capture-guest.pcapng" "$OUTDIR/" 2>&1 || true

echo
echo "Results in $OUTDIR:"
ls -la "$OUTDIR"
echo "done"
