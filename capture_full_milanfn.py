#!/usr/bin/env python3
"""
Full attempt at real image capture using the confirmed-working MilanFn
DEVICE_CONFIG. Works around a device-specific quirk: for at least
mcu_switch_to_fdt_mode, this chip sends [data][ack] instead of goodix.py's
assumed [ack][data] ordering. Reads both packets and classifies each by
content rather than assuming order.
"""
import socket
import subprocess
import sys
import time

sys.path.insert(0, "vendor/goodix-fp-dump")
import goodix
import protocol
import tool
import usb.util

from capture_image_533c import DEVICE_CONFIGS, PSK, check_psk_state, init_device

config = DEVICE_CONFIGS["MilanFn"]


def read_n_order_tolerant(device, command, expect_data):
    """Drain packets until we've seen one ACK and (if expect_data) one data
    response for `command`, discarding any duplicate/orphaned extras this
    device apparently sends (observed: fdt_mode's data+ack pair each
    duplicated). Order-agnostic; also robust to a short burst of extra
    repeats. Stops once satisfied or after a short quiet period."""
    ack_payload = None
    data_payload = None
    empty_reads = 0
    while empty_reads < 2 and (ack_payload is None or
                                (expect_data and data_payload is None)):
        try:
            raw = device.protocol.read(timeout=1)
        except Exception:
            empty_reads += 1
            continue
        try:
            inner, flags, length = goodix.decode_message_pack(raw)
            payload, cmd, plen = goodix.decode_message_protocol(inner)
        except Exception:
            continue
        if cmd == goodix.COMMAND_ACK and ack_payload is None:
            ack_payload = payload
        elif cmd == command and data_payload is None:
            data_payload = payload

    if ack_payload is not None:
        goodix.check_ack(ack_payload, command)
    else:
        print(f"WARNING: no ACK packet found for command 0x{command:02x}")

    return data_payload


def connect_device_instrumented(device, tls_client):
    """Copy of tool.connect_device() with hex logging of every relayed
    chunk, to diagnose why the local openssl TLS-PSK proxy produces zero
    decrypted bytes despite the handshake completing without error."""
    step = [0]

    def log(label, data):
        step[0] += 1
        print(f"  [connect step {step[0]}] {label} ({len(data)}B): "
              f"{data.hex()}")

    req = device.request_tls_connection()
    log("device.request_tls_connection() ->", req)
    tls_client.sendall(req)

    r1 = tls_client.recv(1024)
    log("tls_client.recv() [ClientHello, to relay to device] ->", r1)
    device.protocol.write(goodix.encode_message_pack(
        r1, goodix.FLAGS_TRANSPORT_LAYER_SECURITY))

    for i in range(3):
        raw = device.protocol.read()
        chunk = goodix.check_message_pack(
            raw, goodix.FLAGS_TRANSPORT_LAYER_SECURITY)
        log(f"device.protocol.read() #{i} [relay to openssl] ->", chunk)
        tls_client.sendall(chunk)

    r2 = tls_client.recv(1024)
    log("tls_client.recv() [final, to relay to device] ->", r2)

    # openssl s_server appends an encrypted Alert (content-type 0x15)
    # right after its legitimate ChangeCipherSpec(0x14)+Finished(0x16)
    # records in this same recv() -- forwarding that alert to the device
    # tears down its TLS session, which is why decryption of the
    # subsequent Application Data silently failed. Parse TLS record
    # boundaries and only forward the legitimate CCS+Finished records.
    legit_end = 0
    pos = 0
    while pos + 5 <= len(r2):
        content_type = r2[pos]
        rec_len = int.from_bytes(r2[pos + 3:pos + 5], "big")
        rec_total = 5 + rec_len
        if content_type not in (0x14, 0x16):
            print(f"  Dropping trailing record: content_type=0x{content_type:02x} "
                  f"len={rec_len} (not forwarding to device)")
            break
        pos += rec_total
        legit_end = pos
    r2_legit = r2[:legit_end]
    if legit_end != len(r2):
        print(f"  Truncated final relay from {len(r2)}B to {legit_end}B")

    device.protocol.write(goodix.encode_message_pack(
        r2_legit, goodix.FLAGS_TRANSPORT_LAYER_SECURITY))

    time.sleep(0.05)


def send_and_read_tolerant(device, payload, command, expect_data):
    device.protocol.write(
        goodix.encode_message_pack(
            goodix.encode_message_protocol(payload, command)))
    return read_n_order_tolerant(device, command, expect_data)


def tolerant_reset(device, reset_sensor, soft_reset_mcu, sleep_time):
    import struct
    payload = (struct.pack("<B", (0x1 if reset_sensor else 0x0) |
                            (0x1 if soft_reset_mcu else 0x0) << 1 |
                            (0x1 if reset_sensor else 0x0) << 2) +
               struct.pack("<B", sleep_time))
    resp = send_and_read_tolerant(device, payload, goodix.COMMAND_RESET,
                                   expect_data=not soft_reset_mcu)
    if soft_reset_mcu:
        return None
    if resp is None or len(resp) < 1 or resp[0] != 0x01:
        return False, None
    if len(resp) < 3:
        return False, None
    number = struct.unpack("<H", resp[1:3])[0]
    return True, number


def main():
    device = init_device()
    tls_server = None
    try:
        reset_result = tolerant_reset(device, True, False, 20)
        print("reset ->", reset_result)
        assert reset_result[0]
        assert check_psk_state(device)
        device.read_sensor_register(0x0000, 4)
        device.read_otp()

        # Real vendor capture negotiates cipher suite 0x00AE
        # (TLS_PSK_WITH_AES_128_CBC_SHA256) -- a legacy CBC suite OpenSSL
        # 3.x won't offer by default. Force it explicitly (with SECLEVEL=0
        # to allow it) so our local proxy derives session keys the exact
        # same way the device expects, not whatever OpenSSL 3.x would
        # otherwise auto-negotiate.
        tls_server = subprocess.Popen(
            ["openssl", "s_server", "-nocert", "-psk", PSK.hex(), "-port",
             "4433", "-quiet", "-cipher", "PSK-AES128-CBC-SHA256:@SECLEVEL=0"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        time.sleep(0.5)

        tls_client = socket.socket()
        tls_client.connect(("localhost", 4433))
        try:
            connect_device_instrumented(device, tls_client)
            print("TLS-PSK handshake OK")

            print("--- checking for any extra pending packet post-handshake ---")
            for _ in range(3):
                try:
                    extra = device.protocol.read(timeout=1)
                    print(f"  EXTRA PACKET FOUND ({len(extra)}B): {extra.hex()}")
                except Exception:
                    print("  (none pending)")
                    break

            assert device.upload_config_mcu(config)
            print("upload_config_mcu OK")

            send_and_read_tolerant(
                device,
                b"\x0d\x01\x28\x01\x22\x01\x28\x01\x24\x01\x00\x00\x00\x00"
                b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
                goodix.COMMAND_MCU_SWITCH_TO_FDT_MODE, expect_data=False)
            print("fdt_mode(reply=False) OK")

            resp = send_and_read_tolerant(
                device,
                b"\x0d\x01\x28\x01\x22\x01\x28\x01\x24\x01\x00\x00\x00\x00"
                b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01",
                goodix.COMMAND_MCU_SWITCH_TO_FDT_MODE, expect_data=True)
            print("fdt_mode(reply=True) OK, resp:",
                  resp.hex() if resp else None)

            send_and_read_tolerant(
                device, b"\x00" + b"\x2c\x02" + b"\x0a\x03",
                goodix.COMMAND_WRITE_SENSOR_REGISTER, expect_data=False)
            print("write_sensor_register OK")

            # mcu_get_image: write, then the ACK is TLS-wrapped (flags=
            # FLAGS_TRANSPORT_LAYER_SECURITY_DATA per goodix.py's own
            # implementation) so decode_message_pack's flags check would
            # reject it as non-ACK -- read it manually and forward raw.
            device.protocol.write(
                goodix.encode_message_pack(
                    goodix.encode_message_protocol(
                        b"\x01\x03\x28\x01\x22\x01\x28\x01\x24\x01",
                        goodix.COMMAND_MCU_GET_IMAGE)))
            ack_resp = device.protocol.read()
            print(f"mcu_get_image() ACK length: {len(ack_resp)}, "
                  f"hex={ack_resp.hex()}")

            resp = device.protocol.read()
            print(f"mcu_get_image() DATA raw length: {len(resp)}, "
                  f"hex[:20]={resp[:20].hex()}")
            # Strip the message_pack OUTER header via check_message_pack
            # (returns the length-trimmed inner payload) before applying
            # driver_53xd.py's own [9:] slice -- sending raw[9:] directly
            # (skipping check_message_pack) leaves 4 extra header bytes
            # glued onto the front, corrupting the TLS record.
            inner = goodix.check_message_pack(
                resp, goodix.FLAGS_TRANSPORT_LAYER_SECURITY_DATA)
            print(f"mcu_get_image() DATA inner length: {len(inner)}")
            try:
                sent = tls_client.send(inner[9:])
                print(f"tls_client.send() reported {sent} bytes sent "
                      f"(of {len(inner[9:])})")
                remaining = inner[9:][sent:]
                while remaining:
                    n = tls_client.send(remaining)
                    print(f"  ...sent {n} more")
                    remaining = remaining[n:]
            except OSError as e:
                print(f"tls_client.send() raised: {e!r}")
                raise

            import select
            raw = b""
            deadline = time.time() + 6
            while time.time() < deadline:
                r, _, _ = select.select([tls_server.stdout], [], [], 0.5)
                if r:
                    chunk = tls_server.stdout.read1(65536)
                    if not chunk:
                        break
                    raw += chunk
                elif raw:
                    break

            print(f"Decrypted plaintext bytes: {len(raw)}")
            print(f"tls_server.poll() = {tls_server.poll()}")
            if not raw:
                # Drain and print whatever's left in case openssl logged an
                # error/warning to its (stderr-merged) stdout.
                time.sleep(0.5)
                leftover = tls_server.stdout.read1(65536) if hasattr(
                    tls_server.stdout, "read1") else b""
                print(f"leftover stdout after wait: {leftover!r}")
            if raw:
                with open("vm/clear-MilanFn.raw", "wb") as f:
                    f.write(raw)
                print("Saved vm/clear-MilanFn.raw")

                trimmed = raw[:-4] if len(raw) % 6 == 4 else raw
                trimmed = trimmed[:len(trimmed) - (len(trimmed) % 6)]
                image = tool.decode_image(trimmed)
                pixel_count = len(image)
                print(f"Decoded {pixel_count} pixels")

                candidates_wh = []
                for h in range(30, 200):
                    if pixel_count % h == 0:
                        w = pixel_count // h
                        if 30 <= w <= 200:
                            candidates_wh.append((w, h))
                print(f"Plausible (w,h) pairs: {candidates_wh}")

                nonzero = sum(1 for v in image if v != 0)
                print(f"Non-zero pixels: {nonzero}/{pixel_count} "
                      f"min={min(image) if image else None} "
                      f"max={max(image) if image else None}")

                if candidates_wh:
                    w, h = candidates_wh[len(candidates_wh) // 2]
                    tool.write_pgm(image, w, h, "vm/clear-MilanFn.pgm")
                    print(f"Wrote vm/clear-MilanFn.pgm as {w}x{h}")

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
