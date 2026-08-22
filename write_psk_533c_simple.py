#!/usr/bin/env python3
"""
Same as write_psk_533c.py, but using the SIMPLE preset_psk_write calling
convention (no length/offset/pre_flags wrapper) used by driver_51x0.py,
driver_5503.py and driver_55x4.py, instead of the WRAPPED form (length=114,
offset=0, pre_flags=...) used by driver_53xd.py/driver_52xd.py that we
already tried and got Write result: False from.

Same PSK_WHITE_BOX key bytes as before (known-universal across 8 sibling
families) -- this isolates whether the earlier failure was about the wire
framing/convention or about the key bytes themselves.
"""
import importlib.util
import sys

sys.path.insert(0, "vendor/goodix-fp-dump")

import goodix
import protocol

PRODUCT_ID = 0x533C

spec = importlib.util.spec_from_file_location(
    "driver_53xd", "vendor/goodix-fp-dump/driver_53xd.py")
driver_53xd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver_53xd)

PSK_WHITE_BOX = driver_53xd.PSK_WHITE_BOX
PMK_HASH = driver_53xd.PMK_HASH


def main():
    print(f"PSK_WHITE_BOX: {len(PSK_WHITE_BOX)} bytes, "
          f"{PSK_WHITE_BOX[:16].hex()}...")

    device = goodix.Device(PRODUCT_ID, protocol.USBProtocol)

    print("\n--- nop() ---")
    device.nop()

    print("\n--- preset_psk_write(0xbb010003, PSK_WHITE_BOX)  [SIMPLE form, "
          "no length/offset/pre_flags] ---")
    write_ok = device.preset_psk_write(0xBB010003, PSK_WHITE_BOX)
    print(f"Write result: {write_ok}")

    if not write_ok:
        print("\n>>> WRITE FAILED with the simple convention too. Both "
              "known calling conventions rejected the known-universal key "
              "bytes -- points toward the key bytes themselves being wrong "
              "for this chip, not the framing convention.")
        return

    print(f"\n--- preset_psk_read(0xbb020001, {len(PMK_HASH)}, 0) "
          "[verify] ---")
    ok, flags, pmk_hash = device.preset_psk_read(0xBB020001, len(PMK_HASH), 0)
    print(f"Read ok={ok}")
    if ok:
        print(f"Device PMK hash now: {pmk_hash.hex()}")
        print(f"Expected:            {PMK_HASH.hex()}")
        print("MATCH" if pmk_hash == PMK_HASH else "NO MATCH")

    try:
        device.disconnect()
    except TimeoutError:
        pass


if __name__ == "__main__":
    main()
