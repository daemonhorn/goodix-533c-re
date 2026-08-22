#!/usr/bin/env python3
"""Focused single-candidate (MilanFn -- confirmed accepted) run with full
tracebacks and raw-bytes diagnostics for the mcu_switch_to_fdt_mode
failure seen in capture_image_533c.py."""
import socket
import subprocess
import sys
import time
import traceback

sys.path.insert(0, "vendor/goodix-fp-dump")
import goodix
import protocol
import tool
import usb.util

from capture_image_533c import (DEVICE_CONFIGS, PSK, check_psk_state,
                                 init_device)

config = DEVICE_CONFIGS["MilanFn"]


def main():
    device = init_device()
    tls_server = None
    try:
        assert check_psk_state(device)
        assert device.reset(True, False, 20)[0]
        device.read_sensor_register(0x0000, 4)
        device.read_otp()

        tls_server = subprocess.Popen(
            ["openssl", "s_server", "-nocert", "-psk", PSK.hex(), "-port",
             "4433", "-quiet"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        time.sleep(0.3)

        tls_client = socket.socket()
        tls_client.connect(("localhost", 4433))
        try:
            tool.connect_device(device, tls_client)
            print("TLS-PSK handshake OK")

            ok = device.upload_config_mcu(config)
            print("upload_config_mcu ->", ok)
            assert ok

            print("--- raw: write mcu_switch_to_fdt_mode(mode, reply=False) frame ---")
            mode0 = (b"\x0d\x01\x28\x01\x22\x01\x28\x01"
                     b"\x24\x01\x00\x00\x00\x00\x00\x00"
                     b"\x00\x00\x00\x00\x00\x00\x00\x00"
                     b"\x00\x00\x00")
            device.protocol.write(
                goodix.encode_message_pack(
                    goodix.encode_message_protocol(
                        mode0, goodix.COMMAND_MCU_SWITCH_TO_FDT_MODE)))
            r1 = device.protocol.read(timeout=2)
            print("read #1 (expect ACK for reply=False call):", r1.hex())

            print("--- raw: write mcu_switch_to_fdt_mode(mode, reply=True) frame ---")
            mode1 = (b"\x0d\x01\x28\x01\x22\x01\x28\x01"
                     b"\x24\x01\x00\x00\x00\x00\x00\x00"
                     b"\x00\x00\x00\x00\x00\x00\x00\x00"
                     b"\x00\x00\x01")
            device.protocol.write(
                goodix.encode_message_pack(
                    goodix.encode_message_protocol(
                        mode1, goodix.COMMAND_MCU_SWITCH_TO_FDT_MODE)))
            for i in range(4):
                try:
                    r = device.protocol.read(timeout=2)
                    print(f"read #{i+2}:", r.hex())
                except Exception as e:
                    print(f"read #{i+2} failed/timeout: {e}")
                    break

        finally:
            tls_client.close()
    finally:
        if tls_server is not None:
            tls_server.terminate()
        try:
            device.disconnect()
        except TimeoutError:
            pass
        usb.util.dispose_resources(device.protocol.device)


if __name__ == "__main__":
    main()
