"""Runs one full, known-good 27c6:533c session (reset -> PSK check ->
TLS-PSK -> config upload -> FDT baseline -> wait for finger -> image
capture at the unit-safe gain 0xc2 -> fdt_up) for recording a umockdev
test fixture. Mirrors driver_53xc.py's run_driver() but with the
live-capture gain fixed to 0xc2 (see NOTES.md's "Ridge visibility
resolved" section -- 0x86 clips on this unit)."""
import socket
import subprocess
import sys

sys.path.insert(0, "vendor/goodix-fp-dump-nikicat")
import driver_53xc as d  # noqa: E402
import tool  # noqa: E402


def main(product: int):
    device = d.init_device(product)

    errors = open("/tmp/openssl-golden.log", "w+b")
    tls_server = subprocess.Popen(
        ["openssl", "s_server", "-nocert", "-psk", d.PSK.hex(), "-port",
         "4433", "-quiet"],
        stdout=subprocess.PIPE, stderr=errors)

    try:
        success, number = device.reset(True, False, 20)
        if not success:
            raise ValueError("Reset failed")
        print(f"Reset OK, number {number}")

        device.read_sensor_register(0x0000, 4)
        device.read_otp()

        tls_client = socket.socket()
        tls_client.connect(("localhost", 4433))

        try:
            client_write_key, _ = d.establish_tls(device, tls_client)
            device.tls_successfully_established()
            print("TLS established")

            if not device.upload_config_mcu(d.DEVICE_CONFIG):
                raise ValueError("Failed to upload config")

            template = d.measure_baseline(device)
            print(f"FDT template: {template.hex(' ')}")

            print("Capturing reference frame at 0xc2 (no finger)...")
            reference = d.capture(device, client_write_key, 0x01, 0xc2)

            device.mcu_switch_to_sleep_mode()
            device.query_mcu_state(b"\x01\x00\x01", False)

            print("Waiting for finger -- touch and hold...")
            d.wait_for_finger(device, d.FDT_DOWN_ARMED + template)
            device.mcu_switch_to_fdt_mode(d.FDT_MODE_ARMED + template, True)

            image = d.capture(device, client_write_key, 0x41, 0xc2)

            device.mcu_switch_to_fdt_up(d.FDT_UP_ARMED + template)

            corrected = d.flat_field(image, reference)
            tool.write_pgm(corrected, d.SENSOR_WIDTH, d.SENSOR_HEIGHT,
                           "golden-session.pgm")
            print("Wrote golden-session.pgm")

        finally:
            tls_client.close()
    finally:
        tls_server.terminate()


if __name__ == "__main__":
    main(0x533C)
