"""Records a NO-FINGER-ONLY 27c6:533c session for the public umockdev test
fixture: reset -> PSK check -> TLS-PSK -> config upload -> FDT baseline ->
one reference-frame image capture -> done. Deliberately stops before
wait_for_finger() -- this exercises the entire protocol used by the
capture path (everything but the live/finger-present branch) without
ever capturing or storing a real fingerprint image, since the PSK is
public (all-zero) and anyone can decrypt a committed capture."""
import socket
import subprocess
import sys

sys.path.insert(0, "vendor/goodix-fp-dump-nikicat")
import driver_53xc as d  # noqa: E402
import tool  # noqa: E402


def main(product: int):
    device = d.init_device(product)

    errors = open("/tmp/openssl-fixture.log", "w+b")
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

            print("Capturing reference (no-finger) frame at 0xc2...")
            reference = d.capture(device, client_write_key, 0x01, 0xc2)

            tool.write_pgm(reference, d.SENSOR_WIDTH, d.SENSOR_HEIGHT,
                           "fixture-reference.pgm")
            print("Wrote fixture-reference.pgm (no-finger, safe to publish)")

        finally:
            tls_client.close()
    finally:
        tls_server.terminate()


if __name__ == "__main__":
    main(0x533C)
