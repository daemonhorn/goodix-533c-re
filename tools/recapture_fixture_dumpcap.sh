#!/bin/bash
# Recaptures the finger-absent goodix533c umockdev fixture session via
# dumpcap directly on the usbmon binary interface, instead of through
# tshark's wrapper (tshark internally re-execs dumpcap for the live
# capture anyway, but going direct removes one layer and lets us pass
# usbmon's own options explicitly).
#
# Context: tests/goodix533c/README.md documents that the current
# custom.pcapng/capture.pcapng fixture -- and two prior tshark-based
# recapture attempts -- all captured *zero* payload bytes on every
# bulk-IN (0x83) completion event for the sensor, making the fixture
# replay-incapable past the second open() command. Snaplen was ruled
# out (tried -s 0 and -s 65535, same result both times). This script
# is the next diagnostic step the README suggested: capture via dumpcap
# directly, and separately confirm usbmon's ring buffer isn't starved.
#
# RESULT: this script does NOT fix the problem -- dumpcap direct
# reproduces the identical zero-payload symptom (confirmed on the real
# 14,338-byte image-transfer frame too). Root cause turned out to be
# Linux kernel lockdown mode (confidentiality), which redacts USB
# payload capture system-wide, independent of capture tool. See
# tests/goodix533c/README.md's "Replay status" section for the full
# diagnosis, and vm/usbmon-capture-in-vm.sh for the actual fix (capture
# from inside a VM whose guest kernel has no lockdown enabled). Kept
# here as a documented negative result, not an untried avenue.
#
# Safety: this only ever runs capture_fixture_session.py, the
# deliberately finger-absent session (reset -> PSK check -> TLS-PSK ->
# config upload -> FDT baseline -> one no-finger reference-frame
# capture). It must never be pointed at a script that calls
# wait_for_finger() or otherwise captures a live finger-present frame --
# see tests/goodix533c/README.md's "Deliberately finger-absent" section
# for why that would be unsafe to commit (the PSK for this whole device
# family is public, so any committed capture is third-party-decryptable).
#
# Usage: tools/recapture_fixture_dumpcap.sh [output.pcapng]
#   Requires: real 27c6:533c hardware attached, group membership in
#   `wireshark` (for /dev/usbmonN and dumpcap's capabilities -- this
#   script re-execs itself under `sg wireshark` if that group isn't
#   already active), the repo's .venv with pyusb installed, and openssl
#   on PATH (for the TLS-PSK server capture_fixture_session.py spawns).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/tools/recapture-out.pcapng}"

if ! id -nG | grep -qw wireshark; then
    echo "Re-execing under 'sg wireshark' (current shell lacks that group)..." >&2
    exec sg wireshark -c "$(printf '%q ' "$0" "$@")"
fi

VENDOR_ID=27c6
PRODUCT_ID=533c

BUS_LINE="$(lsusb -d ${VENDOR_ID}:${PRODUCT_ID})"
if [[ -z "$BUS_LINE" ]]; then
    echo "No ${VENDOR_ID}:${PRODUCT_ID} device found -- is it plugged in?" >&2
    exit 1
fi
BUS_NUM="$(sed -n 's/^Bus \([0-9]\+\).*/\1/p' <<<"$BUS_LINE")"
BUS_NUM_TRIMMED="$((10#$BUS_NUM))"   # "003" -> 3
IFACE="usbmon${BUS_NUM_TRIMMED}"
echo "Device found: $BUS_LINE"
echo "Capturing on interface: $IFACE"

# Note: the README also flags usbmon's ring buffer (MON_IOCT_RING_SIZE,
# default 1 MiB) as a candidate cause of dropped payload. dumpcap/libpcap
# don't expose that ioctl, so it isn't controllable from here -- if this
# script's capture still comes up empty, that ioctl (via a small custom
# C reader, or python-usbmon-style tooling) is the next thing to try.

rm -f "$OUT"
dumpcap -i "$IFACE" -w "$OUT" -q &
DUMPCAP_PID=$!

# Give dumpcap a moment to open the interface before traffic starts.
for _ in $(seq 1 20); do
    [[ -e "$OUT" ]] && break
    sleep 0.1
done
sleep 0.5

cleanup() {
    if kill -0 "$DUMPCAP_PID" 2>/dev/null; then
        kill -INT "$DUMPCAP_PID" 2>/dev/null || true
        wait "$DUMPCAP_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "Running capture_fixture_session.py (finger-absent)..."
(
    cd "$REPO_ROOT"
    source .venv/bin/activate
    python3 capture_fixture_session.py
)
SESSION_STATUS=$?

sleep 0.5
cleanup
trap - EXIT

if [[ $SESSION_STATUS -ne 0 ]]; then
    echo "capture_fixture_session.py exited with status $SESSION_STATUS" >&2
    exit "$SESSION_STATUS"
fi

echo
echo "Wrote $OUT"
echo
echo "--- Quick payload check (bulk-IN completions on this device's address) ---"
DEV_ADDR="$(sed -n 's/.*Device \([0-9]\+\):.*/\1/p' <<<"$BUS_LINE")"
DEV_ADDR_TRIMMED="$((10#$DEV_ADDR))"
tshark -r "$OUT" -Y "usb.device_address == ${DEV_ADDR_TRIMMED} && usb.endpoint_address == 0x83 && usb.urb_type == \"C\"" \
    -T fields -e frame.number -e usb.data_len 2>/dev/null | head -20 || true
COUNT_NONZERO="$(tshark -r "$OUT" -Y "usb.device_address == ${DEV_ADDR_TRIMMED} && usb.endpoint_address == 0x83 && usb.urb_type == \"C\" && usb.data_len > 0" 2>/dev/null | wc -l)"
echo
echo "Bulk-IN (0x83) completions with usb.data_len > 0: $COUNT_NONZERO"
if [[ "$COUNT_NONZERO" -gt 0 ]]; then
    echo "PASS: this capture has real bulk-IN payload data."
else
    echo "STILL EMPTY: the dumpcap-direct path did not fix it either."
fi
