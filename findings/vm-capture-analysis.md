# VM capture: real vendor driver session against 27c6:533c

Ubuntu 20.04 (focal) VM, QEMU USB passthrough of the real device, vendor
`.deb` (`libfprint-2-tod1-goodix_0.0.4-0ubuntu1somerville1_amd64.deb`)
installed alongside stock Ubuntu `fprintd`/`libfprint-2-tod1`. Captured via
`usbmon` + `tshark` while running `fprintd-enroll` (timed out waiting for a
finger touch that was never given — irrelevant, the interesting traffic is
the device-open/init sequence, which happens regardless of touch).

Tooling: no `tshark`/`wireshark` on the host, so the `.pcapng` was pulled
back and decoded with pure-Python (`dpkt` for pcapng framing + a hand
-written Linux-usbmon-mmapped-header parser, `parse_capture.py`), then the
actual message framing decoded using `goodix.py`'s own
`decode_message_pack`/`decode_message_protocol` functions directly
(`decode_capture.py`) rather than hand-deriving the byte layout, to avoid
transcription errors.

## Full command sequence observed (bulk EP1 OUT / EP3 IN, device addr 3)

```
nop()
firmware_version()  x2          -> "GF5288_GM168SEC_APP_13016\x00"
preset_psk_read(0xbb010002, 0x66, 0)   -> 102-byte stored "sealed" blob (unchanged, not analyzed further -- not needed)
preset_psk_read(0xbb020001, 32, 0)     -> 66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925
    == driver_53xd.py's PMK_HASH (sha256 of the all-zero PSK) -- EXACT MATCH
firmware_version() x2 (again)
reset()
read_sensor_register(chip ID)
read_otp()
COMMAND_REQUEST_TLS_CONNECTION (0xd0)
  -> full TLS 1.2 handshake follows (ClientHello, ServerHello, "Client_identity"
     PSK-identity hint visible in plaintext handshake bytes, Finished, etc.)
COMMAND_UPLOAD_CONFIG_MCU (0x90)        -- sent TLS-encrypted, can't read plaintext from the wire
COMMAND_MCU_SWITCH_TO_FDT_MODE (0x36)
COMMAND_WRITE_SENSOR_REGISTER (0x80) x2
COMMAND_MCU_GET_IMAGE (0x20)            -> 14338-byte TLS-encrypted response
  (repeated 3x total -- calibration/finger-detect loop, all successful)
```

**No `COMMAND_PRESET_PSK_WRITE_R` (`0xe0`) appears anywhere in this
capture.** See `phase2-psk-write-CORRECTION.md` for why: the device's PSK
was already correctly set by our own earlier (Phase 2) write attempt,
which we had misread as a failure.

## New/reconciled data points

- **Firmware version now reads `..._13016`**, matching Phase 1's original
  static hypothesis from the blob's `.rodata` strings exactly. This
  differs from the very first live read in this project (`..._13020`,
  see `phase2-readonly-probe.md`), taken before any write attempts. Not
  fully explained -- possibly a firmware self-check/rollback triggered by
  the PSK write or a subsequent `reset()`, possibly something more mundane.
  Re-verified directly on the host, twice, after the VM was shut down: now
  consistently `..._13016`. Not investigated further; doesn't block
  anything since the value is stable and matches other evidence.
- **The `0x66`-byte (102) `0xbb010002`-tagged read** returns a stored
  "sealed"-looking blob (Phase 1/decompile-analysis's "sealed PSK" concept)
  -- present and consistent, but not needed for anything now that the PSK
  bootstrap is confirmed already correct. Not decoded further.
- **`DEVICE_CONFIG`'s actual bytes remain unknown** -- the upload happens
  after the TLS handshake, so it's encrypted on the wire and this capture
  alone can't recover the plaintext. Still one of 6 remaining named
  candidates from `device-config.md` (MilanF/MilanFn/MilanG/MilanH/MilanL/
  ChicagoHS). Next step: try each against the real device inside our own
  TLS session (now that the PSK/handshake side is proven working) and see
  which one the device accepts without error.
- **Image capture is real and repeatable**: three independent 14338-byte
  encrypted image payloads were captured in one session, all following
  identical `write_sensor_register` -> `mcu_get_image` sequences. Once we
  can stand up our own TLS-PSK session (matching what the vendor driver
  does, reusing `driver_53xd.py`'s pattern of shelling out to `openssl
  s_server -psk <hex> -port 4433` as a local decryption proxy -- avoids
  reimplementing any TLS crypto), the same 14338-byte responses should be
  decryptable to a raw image.
