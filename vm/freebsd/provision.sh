#!/bin/bash
# One-time (writable) provisioning boot for the FreeBSD USB-passthrough test
# VM: bootstraps pkg, installs build dependencies as binary packages, and
# shallow-clones the FreeBSD ports tree. No USB passthrough here -- the real
# sensor isn't needed for any of this and stays free for host use.
#
# Run this once against a freshly downloaded/resized freebsd-base.qcow2:
#   curl -LO https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/amd64/Latest/FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz
#   (verify against .../Latest/CHECKSUM.SHA256 first)
#   unxz -k FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz
#   mv FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2 freebsd-base.qcow2
#   qemu-img resize freebsd-base.qcow2 30G
# and a seed.iso built from this directory's meta-data/user-data:
#   genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data
# After this completes and the VM is shut down cleanly, build-and-test-in-vm.sh boots
# the now-provisioned image with -snapshot for repeatable, non-destructive
# hardware test runs -- everything expensive (OpenCV, the ports tree clone)
# is already baked into freebsd-base.qcow2 by this script, never redone.
#
# Usage: vm/freebsd/provision.sh

set -uo pipefail

VMDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_PORT=2223
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o IdentitiesOnly=yes -i "$VMDIR/vm_key" -p "$SSH_PORT")
SCP_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -i "$VMDIR/vm_key" -P "$SSH_PORT")
SSH_HOST=localhost

if [[ ! -f "$VMDIR/freebsd-base.qcow2" ]]; then
    echo "freebsd-base.qcow2 not found -- fetch and resize it first (see the header comment above)." >&2
    exit 1
fi

: > "$VMDIR/serial.log"
echo "Booting (writable) for provisioning..."
qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 2 -m 2048 \
    -drive file="$VMDIR/freebsd-base.qcow2",if=virtio \
    -cdrom "$VMDIR/seed.iso" \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -display none -serial file:"$VMDIR/serial.log" \
    -daemonize -pidfile "$VMDIR/qemu.pid"

cleanup() {
    if [[ -f "$VMDIR/qemu.pid" ]]; then
        QPID="$(cat "$VMDIR/qemu.pid" 2>/dev/null)"
        if [[ -n "${QPID:-}" ]] && kill -0 "$QPID" 2>/dev/null; then
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
for _ in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" true 2>/dev/null; then SSH_UP=1; break; fi
    sleep 5
done
if [[ $SSH_UP -ne 1 ]]; then
    echo "SSH never came up -- check $VMDIR/serial.log" >&2
    exit 1
fi

# Confirmed necessary on this image, not theoretical: FreeBSD base sshd's
# compiled-in default for PermitRootLogin, when the sshd_config line is left
# commented out, is "no" (not OpenSSH's documented upstream default of
# "prohibit-password"). Root pubkey auth got PK_OK at the SSH query phase
# but was denied at the real auth step until this was made explicit.
# user-data's runcmd also carries this fix for a from-scratch re-provision;
# this line makes provision.sh idempotent/self-sufficient either way.
ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" \
    "sed -i '' 's/^#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config && service sshd restart"

echo "Bootstrapping pkg..."
ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" "ASSUME_ALWAYS_YES=yes pkg bootstrap -f && pkg update"

echo "Installing build dependencies (binary packages only -- never build OpenCV etc. from source in-guest)..."
ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" \
    "pkg install -y git meson ninja pkgconf glib libgusb pixman opencv openssl"

echo "Verifying OpenCV pkg-config resolves the modules the sigfm driver helper needs..."
ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" "pkg-config --exists opencv4 && echo OPENCV4_OK"

echo "Cloning the FreeBSD ports tree (shallow -- only Mk/Templates/etc. are needed, all deps are pre-installed packages)..."
ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" \
    "[ -d /usr/ports/.git ] || git clone --depth 1 https://git.FreeBSD.org/ports.git /usr/ports"

echo "Provisioning complete. Shutting down cleanly to persist it into freebsd-base.qcow2..."
ssh "${SSH_OPTS[@]}" "root@$SSH_HOST" "shutdown -p now" || true
sleep 8
echo "done"
