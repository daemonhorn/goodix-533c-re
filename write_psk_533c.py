#!/usr/bin/env python3
"""
Write the known-universal Goodix white-box PSK to the 27c6:533c sensor and
verify it took.

Per advisor review: `write_psk` ESTABLISHES a key, it doesn't need to match
any factory secret. driver_53xd.py's PSK_WHITE_BOX constant is confirmed
byte-for-byte identical across 8 sibling chip families (51x0, 51x0_spi,
51x7, 52xd, 53x5, 53xd, 5503, 55x4) -- so we use THAT known-good value
directly, imported from the vendored sibling driver rather than retyped,
instead of our own unconfirmed static-analysis candidate (findings/psk-
whitebox.md, offset 0xf1bab in the closed .so -- only 16/96 bytes were
code-confirmed there).

Scope, per plan + advisor: stop after PSK write + verification. Do NOT
proceed to reset()/GTLS/upload_config_mcu() in this script -- the config
upload in particular pushes DAC/calibration values and there are still 6
unresolved DEVICE_CONFIG candidates; that needs its own analysis, not a
blind hardware attempt.
"""
import importlib.util
import sys

sys.path.insert(0, "vendor/goodix-fp-dump")

import goodix
import protocol

PRODUCT_ID = 0x533C

# Pull PSK_WHITE_BOX / PMK_HASH directly from the sibling driver module
# rather than retyping them (avoids transcription errors).
spec = importlib.util.spec_from_file_location(
    "driver_53xd", "vendor/goodix-fp-dump/driver_53xd.py")
driver_53xd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver_53xd)

PSK_WHITE_BOX = driver_53xd.PSK_WHITE_BOX
PMK_HASH = driver_53xd.PMK_HASH  # NB: this is sha256 of the all-zero PSK,
# NOT sha256(PSK_WHITE_BOX) -- it's what check_psk() actually compares
# against after write_psk() succeeds. Reusing the sibling's own constant
# rather than recomputing avoids comparing against the wrong digest.

PRE_FLAGS = bytes.fromhex("56a5bb956b7c8d9e0000")


def main():
    print(f"PSK_WHITE_BOX: {len(PSK_WHITE_BOX)} bytes, "
          f"{PSK_WHITE_BOX[:16].hex()}...")
    print(f"Expected PMK_HASH after write: {PMK_HASH.hex()}")

    device = goodix.Device(PRODUCT_ID, protocol.USBProtocol)

    print("\n--- nop() ---")
    device.nop()

    print("\n--- preset_psk_write(0xbb010003, PSK_WHITE_BOX, 114, 0, "
          f"{PRE_FLAGS.hex()}) ---")
    write_ok = device.preset_psk_write(0xBB010003, PSK_WHITE_BOX, 114, 0,
                                        PRE_FLAGS)
    print(f"Write result: {write_ok}")

    if not write_ok:
        print("\n>>> WRITE FAILED. This is real evidence 53xc's PSK path "
              "differs from the 53xd/53x5 pattern -- do not retry blindly, "
              "report and reassess (this is when the 0xf1bab static "
              "candidate becomes worth trying instead).")
        return

    print(f"\n--- preset_psk_read(0xbb020001, {len(PMK_HASH)}, 0) "
          "[verify] ---")
    ok, flags, pmk_hash = device.preset_psk_read(0xBB020001, len(PMK_HASH), 0)

    if not ok:
        print(">>> Verification read failed (ok=False) despite write "
              "reporting success -- inconclusive, needs investigation.")
        return

    print(f"Device PMK hash now: {pmk_hash.hex()}")
    print(f"Expected:            {PMK_HASH.hex()}")

    if pmk_hash == PMK_HASH:
        print("\n>>> CONFIRMED: PSK write succeeded and verified. The "
              "known-universal white-box PSK works on 27c6:533c. The GTLS "
              "PSK layer is solved for this device.")
    else:
        print("\n>>> Write reported success but verification hash does "
              "NOT match expected. Needs investigation before trusting "
              "this device's PSK state.")

    try:
        device.disconnect()
    except TimeoutError:
        pass


if __name__ == "__main__":
    main()
