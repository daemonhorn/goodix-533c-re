#!/usr/bin/env python3
"""
Read-only protocol probe for Goodix 27c6:533c.

Deliberately limited to non-mutating operations (nop, firmware_version,
read_sensor_register, read_otp, preset_psk_read) to validate Phase 1's
static findings against real hardware WITHOUT writing anything to the
device (no preset_psk_write, no upload_config_mcu, no reset/erase).

See findings/SUMMARY.md for what this is trying to confirm:
  - the real firmware-name string (unresolvable statically)
  - whether the PSK_WHITE_BOX candidate at .so offset 0xf1bab is correct,
    by comparing sha256(candidate) against the device's live PMK hash
  - the sensor's chip ID / variant, to narrow the 6 remaining
    DEVICE_CONFIG candidates
"""
import hashlib
import sys

sys.path.insert(0, "vendor/goodix-fp-dump")

import goodix
import protocol

PRODUCT_ID = 0x533C

# Candidate PSK_WHITE_BOX recovered by static analysis (findings/psk-whitebox.md).
# Only the first 16 bytes are code-confirmed; bytes 16-95 are a strong
# statistical hypothesis, NOT yet verified against real hardware.
PSK_WHITE_BOX_CANDIDATE = bytes.fromhex(
    "ec35ae3abb45ed3f12c4751f1e5c2cc"
    "02fd3af40249d50d3e549674d4dc2989d96450df05d56eb6c157af776b4d33782"
    "0c49acfd5e2702d38167e3d39cea160a547dd284ccbcf279e104989c3a9e9fec3"
    "42fea692eb942d0f69e8ab6c00c2d26"
)


def main():
    print(f"Candidate PSK_WHITE_BOX length: {len(PSK_WHITE_BOX_CANDIDATE)} bytes")
    if len(PSK_WHITE_BOX_CANDIDATE) != 96:
        print("WARNING: candidate is not 96 bytes, hex was likely mistyped")

    device = goodix.Device(PRODUCT_ID, protocol.USBProtocol)

    print("\n--- nop() ---")
    device.nop()
    print("nop OK (device responds to basic framing)")

    print("\n--- firmware_version() ---")
    fw = device.firmware_version()
    print(f"Firmware version string: {fw!r}")

    print("\n--- read_sensor_register(0x0000, 4)  [chip ID] ---")
    try:
        chip_id = device.read_sensor_register(0x0000, 4)
        print(f"Chip ID bytes: {chip_id.hex()}")
    except Exception as error:
        print(f"read_sensor_register failed (non-fatal, continuing): {error}")

    print("\n--- read_otp() ---")
    try:
        otp = device.read_otp()
        print(f"OTP bytes ({len(otp)}): {otp.hex()}")
    except Exception as error:
        print(f"read_otp failed (non-fatal, continuing): {error}")

    print("\n--- preset_psk_read(0xbb020001, 32, 0)  [current PMK hash] ---")
    ok, flags, pmk_hash = device.preset_psk_read(0xBB020001, 32, 0)
    if not ok:
        print("Device reports: no PSK/PMK hash currently set (ok=False)")
    else:
        print(f"Device PMK hash ({len(pmk_hash)} bytes): {pmk_hash.hex()}")

        candidate_hash = hashlib.sha256(PSK_WHITE_BOX_CANDIDATE).digest()
        print(f"sha256(candidate PSK_WHITE_BOX):  {candidate_hash.hex()}")

        if pmk_hash == candidate_hash:
            print(">>> MATCH: the static PSK_WHITE_BOX candidate is CONFIRMED.")
        else:
            print(">>> NO MATCH: the static PSK_WHITE_BOX candidate is WRONG "
                  "(or the factory PSK differs from the white-box constant "
                  "until write_psk() is called, as with the sibling models).")

    try:
        device.disconnect()
    except TimeoutError:
        # protocol.py's disconnect() polls waiting for the device to drop
        # off the bus, which only happens after a reset()/firmware update.
        # We never reset the device, so it never re-enumerates -- benign.
        pass
    print("\nDone. No data was written to the device.")


if __name__ == "__main__":
    main()
