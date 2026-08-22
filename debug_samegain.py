import socket
import subprocess
import sys

sys.path.insert(0, "vendor/goodix-fp-dump-nikicat")
import driver_53xc as d  # noqa: E402
import tool  # noqa: E402


def main(product: int):
    device = d.init_device(product)

    errors = open("/tmp/openssl-samegain.log", "w+b")
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

            # Reference captured at gain 0x86 -- SAME gain as the live
            # capture below, unlike driver_53xc.py's normal 0xc2. Tests
            # whether flat_field()'s single global linear fit was masking
            # ridge detail because it couldn't fully compensate for a
            # nonlinear difference between gain 0xc2 and 0x86 on this unit.
            print("Capturing reference frame at gain 0x86 (no finger)...")
            reference = d.capture(device, client_write_key, 0x01, 0x86)

            device.mcu_switch_to_sleep_mode()
            device.query_mcu_state(b"\x01\x00\x01", False)

            print("Waiting for finger -- touch the sensor firmly...")
            d.wait_for_finger(device, d.FDT_DOWN_ARMED + template)
            device.mcu_switch_to_fdt_mode(d.FDT_MODE_ARMED + template, True)

            image = d.capture(device, client_write_key, 0x41, 0x86)

            device.mcu_switch_to_fdt_up(d.FDT_UP_ARMED + template)

            corrected = d.flat_field(image, reference)
            tool.write_pgm(corrected, d.SENSOR_WIDTH, d.SENSOR_HEIGHT,
                           "fingerprint-samegain.pgm")
            print("Wrote fingerprint-samegain.pgm")

            with open("/tmp/reference_samegain.txt", "w") as f:
                f.write(" ".join(str(v) for v in reference))
            with open("/tmp/live_samegain.txt", "w") as f:
                f.write(" ".join(str(v) for v in image))

            import statistics
            def pearson(a, b):
                ma, mb = statistics.mean(a), statistics.mean(b)
                num = sum((a[i] - ma) * (b[i] - mb) for i in range(len(a)))
                da = sum((v - ma) ** 2 for v in a) ** 0.5
                db = sum((v - mb) ** 2 for v in b) ** 0.5
                return num / (da * db)

            r = pearson(reference, image)
            print(f"Pearson correlation reference(0x86) vs live(0x86): {r:.4f}")
            print(f"reference: min={min(reference)} max={max(reference)} "
                  f"mean={statistics.mean(reference):.1f}")
            print(f"live:      min={min(image)} max={max(image)} "
                  f"mean={statistics.mean(image):.1f}")

        finally:
            tls_client.close()
    finally:
        tls_server.terminate()


if __name__ == "__main__":
    main(0x533C)
