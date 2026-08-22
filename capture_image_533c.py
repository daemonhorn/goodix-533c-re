#!/usr/bin/env python3
"""
Attempt real (no-finger, "clear"/calibration) image capture from the real
27c6:533c sensor, following driver_53xd.py's run_driver() pattern almost
verbatim -- reusing the generic goodix.py wire protocol and shelling out to
`openssl s_server` for the TLS-PSK session (no custom crypto implemented).

The PSK bootstrap is already confirmed working (see findings/
phase2-psk-write-CORRECTION.md and findings/vm-capture-analysis.md) -- this
script does NOT write a PSK, only reads to confirm state, matching what the
real vendor driver does.

DEVICE_CONFIG is unknown for this PID (6 remaining named candidates from
findings/device-config.md: MilanF, MilanFn, MilanG, MilanH, MilanL,
ChicagoHS). This script tries each in turn, doing a full fresh
reset+connect+upload_config_mcu per candidate, and stops at the first one
that lets image capture succeed.
"""
import hashlib
import importlib.util
import socket
import subprocess
import sys
import time

sys.path.insert(0, "vendor/goodix-fp-dump")
import goodix
import protocol
import tool
import usb.util

PRODUCT_ID = 0x533C
SO_PATH = ("/home/dhorn/goodix/extracted_driver/usr/lib/x86_64-linux-gnu/"
           "libfprint-2/tod-1/libfprint-tod-goodix-53xc-0.0.4.so")

CANDIDATES = {
    "MilanF": 0x145380,
    "MilanH": 0x145b60,
    "MilanG": 0x145880,
    "MilanL": 0x145e40,
    "ChicagoHS": 0x103ee0,
    "MilanFn": 0x103380,
}

with open(SO_PATH, "rb") as f:
    _so_data = f.read()


def fix_config_checksum(config: bytearray):
    """Confirmed algorithm (Phase 1, VA 0x2d0a0): seed 0xa5a5, running
    16-bit LE sum over bytes [0:254], negated mod 0x10000, stored LE in
    bytes [254:256]. Matches driver_53x5.py's fix_config_checksum exactly."""
    checksum = 0xA5A5
    for i in range(0, 254, 2):
        checksum = (checksum + int.from_bytes(config[i:i + 2], "little")) & 0xFFFF
    checksum = (0x10000 - checksum) & 0xFFFF
    config[254:256] = checksum.to_bytes(2, "little")


DEVICE_CONFIGS = {}
for _name, _off in CANDIDATES.items():
    _blob = bytearray(_so_data[_off:_off + 256])
    fix_config_checksum(_blob)
    DEVICE_CONFIGS[_name] = bytes(_blob)

# Known-universal PSK (all-zero) -- confirmed already correctly provisioned
# on this device (see phase2-psk-write-CORRECTION.md).
PSK = bytes.fromhex(
    "0000000000000000000000000000000000000000000000000000000000000000")


def init_device():
    device = goodix.Device(PRODUCT_ID, protocol.USBProtocol)
    device.nop()
    return device


def check_psk_state(device):
    ok, flags, pmk_hash = device.preset_psk_read(0xBB020001, 32, 0)
    expected = hashlib.sha256((b"\x00\x22" + PSK) * 2).digest() if False else None
    # PMK_HASH is sha256 of a specific encoding of the all-zero PSK; reuse
    # the known-good constant directly rather than recomputing, to avoid
    # an encoding mismatch (see driver_53xd.py's own PMK_HASH constant).
    spec = importlib.util.spec_from_file_location(
        "driver_53xd", "vendor/goodix-fp-dump/driver_53xd.py")
    driver_53xd = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver_53xd)
    print(f"PSK check: ok={ok} hash={pmk_hash.hex() if pmk_hash else None} "
          f"expected={driver_53xd.PMK_HASH.hex()}")
    return ok and pmk_hash == driver_53xd.PMK_HASH


def try_candidate(name, config):
    print(f"\n{'='*60}\nTrying DEVICE_CONFIG candidate: {name}\n{'='*60}")

    device = init_device()
    success = False
    tls_server = None

    try:
        if not check_psk_state(device):
            print("PSK state not as expected -- aborting this attempt")
            return False

        reset_ok = device.reset(True, False, 20)[0]
        print(f"reset() -> {reset_ok}")
        if not reset_ok:
            return False

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
            print("TLS-PSK handshake established")

            if not device.upload_config_mcu(config):
                print(f"upload_config_mcu REJECTED for {name}")
                return False
            print(f"upload_config_mcu ACCEPTED for {name}")

            device.mcu_switch_to_fdt_mode(
                b"\x0d\x01\x28\x01\x22\x01\x28\x01"
                b"\x24\x01\x00\x00\x00\x00\x00\x00"
                b"\x00\x00\x00\x00\x00\x00\x00\x00"
                b"\x00\x00\x00", False)
            device.mcu_switch_to_fdt_mode(
                b"\x0d\x01\x28\x01\x22\x01\x28\x01"
                b"\x24\x01\x00\x00\x00\x00\x00\x00"
                b"\x00\x00\x00\x00\x00\x00\x00\x00"
                b"\x00\x00\x01", True)

            device.write_sensor_register(0x022c, b"\x0a\x03")

            resp = device.mcu_get_image(
                b"\x01\x03\x28\x01\x22\x01\x28\x01\x24\x01",
                goodix.FLAGS_TRANSPORT_LAYER_SECURITY_DATA)
            print(f"mcu_get_image() ack response length: {len(resp)}")
            tls_client.sendall(resp[9:])

            # Read whatever the TLS server decrypted, with a timeout so we
            # don't hang forever if the byte count differs from 53xd's.
            tls_server.stdout.settimeout = None
            import select
            raw = b""
            deadline = time.time() + 5
            while time.time() < deadline:
                r, _, _ = select.select([tls_server.stdout], [], [], 0.5)
                if r:
                    chunk = tls_server.stdout.read1(65536) if hasattr(
                        tls_server.stdout, "read1") else tls_server.stdout.read(65536)
                    if not chunk:
                        break
                    raw += chunk
                elif raw:
                    break

            print(f"Decrypted plaintext image bytes: {len(raw)}")
            if len(raw) < 24:
                print(f"Too little data decrypted for {name} -- treating as failure")
                return False

            out_path = f"vm/clear-{name}.raw"
            with open(out_path, "wb") as f:
                f.write(raw)
            print(f"Saved raw decrypted bytes to {out_path}")

            image = tool.decode_image(raw[:-4] if len(raw) % 6 else raw)
            pixel_count = len(image)
            print(f"Decoded {pixel_count} pixels")

            # Try to find a plausible width x height factorization.
            candidates_wh = []
            for h in range(40, 200):
                if pixel_count % h == 0:
                    w = pixel_count // h
                    if 40 <= w <= 200:
                        candidates_wh.append((w, h))
            print(f"Plausible (width, height) factor pairs: {candidates_wh}")

            if candidates_wh:
                w, h = candidates_wh[0]
                tool.write_pgm(image, w, h, f"vm/clear-{name}.pgm")
                print(f"Wrote vm/clear-{name}.pgm ({w}x{h})")

            nonzero = sum(1 for v in image if v != 0)
            print(f"Non-zero pixels: {nonzero}/{pixel_count}")
            success = nonzero > pixel_count * 0.05  # not just a blank/garbage read

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

    return success


def main():
    for name, config in DEVICE_CONFIGS.items():
        try:
            if try_candidate(name, config):
                print(f"\n*** SUCCESS with candidate {name} ***")
                return
        except Exception as error:
            print(f"Candidate {name} raised an exception: {error!r}")
        time.sleep(1)

    print("\nNo candidate produced a plausible image.")


if __name__ == "__main__":
    main()
