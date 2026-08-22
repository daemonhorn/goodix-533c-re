import socket
import statistics
import subprocess
import sys

sys.path.insert(0, "vendor/goodix-fp-dump-nikicat")
import driver_53xc as d  # noqa: E402
import tool  # noqa: E402

GAINS = [0x40, 0x50, 0x60, 0x70, 0x86, 0xa0, 0xc2]


def main(product: int):
    device = d.init_device(product)

    errors = open("/tmp/openssl-sweep.log", "w+b")
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

            print("Capturing reference frame at 0xc2 (no finger, has headroom)...")
            reference = d.capture(device, client_write_key, 0x01, 0xc2)
            print(f"  reference: min={min(reference)} max={max(reference)} "
                  f"mean={statistics.mean(reference):.1f}")

            device.mcu_switch_to_sleep_mode()
            device.query_mcu_state(b"\x01\x00\x01", False)

            print("Waiting for finger -- touch and HOLD firmly through the "
                  "whole sweep (several captures in a row)...")
            d.wait_for_finger(device, d.FDT_DOWN_ARMED + template)
            device.mcu_switch_to_fdt_mode(d.FDT_MODE_ARMED + template, True)

            for gain in GAINS:
                image = d.capture(device, client_write_key, 0x41, gain)
                mn, mx = min(image), max(image)
                mean = statistics.mean(image)
                clipped = sum(1 for v in image if v >= 4095)
                print(f"gain {gain:#04x}: min={mn} max={mx} mean={mean:.1f} "
                      f"clipped_px={clipped}/{len(image)}")

                corrected = d.flat_field(image, reference)
                path = f"sweep-{gain:#04x}.pgm"
                tool.write_pgm(corrected, d.SENSOR_WIDTH, d.SENSOR_HEIGHT, path)
                print(f"  wrote {path}")

            device.mcu_switch_to_fdt_up(d.FDT_UP_ARMED + template)

        finally:
            tls_client.close()
    finally:
        tls_server.terminate()


if __name__ == "__main__":
    main(0x533C)
