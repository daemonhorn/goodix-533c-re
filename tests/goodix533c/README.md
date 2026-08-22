# goodix533c umockdev test fixture

Real USB traffic captured from a physical `27c6:533c` sensor via
`usbmon`/`tshark`, for `umockdev-run -p` replay -- same mechanism used by
`tests/goodixmoc/` in the libfprint source tree.

- `device` -- `umockdev-record`'s sysfs/udev description of the real
  device (vendor/product IDs, descriptors, interfaces, endpoints).
- `capture.pcapng` -- one full session: `nop -> reset -> read chip ID ->
  read OTP -> TLS-PSK handshake -> upload_config_mcu -> FDT baseline ->
  one mcu_get_image capture (reference frame, gain 0xc2)`.

## Deliberately finger-absent

This fixture stops after the no-finger reference-frame capture and never
calls `wait_for_finger()`/captures a live frame. The PSK for this whole
device family is public (all-zero, confirmed in
`../../findings/vm-capture-analysis.md`), so anyone with the pcapng can
decrypt every `mcu_get_image` payload in it. A live capture would be a
real, recoverable fingerprint image committed to a public repo -- so it
was deliberately not what got recorded here. See `capture_fixture_session.py`
in the repo root for the exact (short) protocol path this covers, and
`capture_golden_session.py` for the full path (including live capture)
that was used for local testing but never committed.

This still exercises the entire protocol used by the capture path except
the live/finger-present branch, which is identical machinery
(`mcu_get_image` at a different gain) already proven working
end-to-end multiple times against real hardware this session -- see
`../../findings/image-capture-success.md` and `../../NOTES.md`.

## Replay

```sh
umockdev-run -d device \
  -p /sys/devices/pci0000:00/0000:00:14.0/usb3/3-3=capture.pcapng \
  -- <program that talks to 27c6:533c>
```

The syspath is specific to the machine this was captured on but is only
used as a mock sysfs label by umockdev -- any syspath works as long as
the `-p` flag's key matches the `P:` line in `device` with `/sys`
prepended.

**Known limitation**: replaying against `vendor/goodix-fp-dump-nikicat`'s
Python driver directly fails at device-open (`is_kernel_driver_active`/
`set_configuration` calls that PyUSB's `protocol.py` makes but that a
libfprint C driver using `GUsbDevice`/`g_usb_device_claim_interface`
would not). This fixture targets the native libfprint driver, not the
Python reference implementation -- confirmed the `device` file itself is
accurate (enumeration, interface, and endpoint discovery all replay
correctly).
