#!/usr/bin/env python3
"""
Instrumented replay of the exact same PSK-write transaction as
write_psk_533c.py (wrapped form: length=114, offset=0, pre_flags=...),
but bypassing preset_psk_write()'s True/False collapse to print the full
raw rejection response. No new key bytes, no new framing -- purely
diagnostic on an already-attempted transaction.
"""
import importlib.util
import struct
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
PRE_FLAGS = bytes.fromhex("56a5bb956b7c8d9e0000")
FLAGS = 0xBB010003
LENGTH = 114
OFFSET = 0


def main():
    device = goodix.Device(PRODUCT_ID, protocol.USBProtocol)

    print("--- nop() ---")
    device.nop()

    # Reconstruct `data` exactly as preset_psk_write() does internally.
    data = PRE_FLAGS + struct.pack("<I", FLAGS) + struct.pack(
        "<I", len(PSK_WHITE_BOX)) + PSK_WHITE_BOX
    total_length = len(data)
    assert total_length == LENGTH, f"expected {LENGTH}, got {total_length}"
    if OFFSET + LENGTH > total_length:
        raise ValueError("Invalid payload, length or offset")
    data = (struct.pack("<I", total_length) + struct.pack("<I", LENGTH) +
            struct.pack("<I", OFFSET) + data[OFFSET:OFFSET + LENGTH])

    print(f"\n--- raw preset_psk_write transaction ({len(data)} bytes) ---")
    device.protocol.write(
        goodix.encode_message_pack(
            goodix.encode_message_protocol(data,
                                           goodix.COMMAND_PRESET_PSK_WRITE_R)))

    ack_msg = goodix.check_message_protocol(
        goodix.check_message_pack(device.protocol.read()), goodix.COMMAND_ACK)
    print(f"ACK payload: {ack_msg!r}")
    goodix.check_ack(ack_msg, goodix.COMMAND_PRESET_PSK_WRITE_R)
    print("ACK verified for COMMAND_PRESET_PSK_WRITE_R")

    resp = goodix.check_message_protocol(
        goodix.check_message_pack(device.protocol.read()),
        goodix.COMMAND_PRESET_PSK_WRITE_R)
    print(f"\nFull response ({len(resp)} bytes): {resp.hex()}")
    print(f"Response byte 0 (result code): 0x{resp[0]:02x}")
    if len(resp) > 1:
        print(f"Remaining response bytes: {resp[1:].hex()}")

    try:
        device.disconnect()
    except TimeoutError:
        pass


if __name__ == "__main__":
    main()
