# DEVICE_CONFIG rejection: checksum mismatch confirms these are unpatched templates

All 6 remaining static candidates (`MilanF`, `MilanH`, `MilanG`, `MilanL`,
`ChicagoHS`, `MilanFn` — see `device-config.md`) were tried against the
real device via `capture_image_533c.py`. Every step through the TLS-PSK
handshake succeeded (matching the real vendor capture exactly — see
`vm-capture-analysis.md`); `upload_config_mcu()` cleanly rejected all six.

## Local, zero-hardware-risk analysis (per advisor review)

Recomputed each candidate's checksum using the algorithm Phase 1 confirmed
via disassembly (VA `0x2d0a0`, seed `0xa5a5`, running 16-bit LE sum over
bytes `[0:254]`, negated mod `0x10000`, stored LE in bytes `[254:256]`):

```
MilanF       stored=0x0000  computed=0xac73  MISMATCH
MilanH       stored=0xffbc  computed=0x74a5  MISMATCH
MilanG       stored=0xd8ba  computed=0xd8ea  MISMATCH
MilanL       stored=0xe90f  computed=0x1a12  MISMATCH
ChicagoHS    stored=0xffbc  computed=0x0e93  MISMATCH
MilanFn      stored=0x466e  computed=0xd33e  MISMATCH
```

**All six fail.** This is not a bug in the checksum algorithm: pulled
`driver_53x5.py`'s actual `fix_config_checksum` source directly to compare,
and it is structurally identical to what was implemented here
(`checksum = 0x10000 - checksum`, equivalent to this analysis's
`(-checksum) & 0xffff`).

## Why: these are templates, not ready-to-send blobs

`driver_53x5.py`'s own `run_driver()`-equivalent code (`device_enable()`
region) does this, verbatim:

```python
chip_config = bytearray(DEFAULT_CONFIG)
# ... TCODE_TAG / DAC_L_TAG-tagged bytes patched into chip_config here ...
fix_config_checksum(chip_config)   # overwrites the last 2 bytes in place
device.upload_config_mcu(bytes(chip_config))
```

`fix_config_checksum` **mutates the buffer it's given** — it's called
*after* calibration data is spliced in, and only then does the checksum
become valid. The compiled `.so`'s stored `DEFAULT_CONFIG`-equivalent
constant is a **starting template**; its embedded "checksum" bytes are
whatever they were when the template was last saved (possibly zero,
possibly a placeholder, possibly stale from a different build) — not a
valid checksum of the template as-is. Our 6 extracted `53xc` candidates
being checksum-invalid **in exactly this way** is strong evidence they're
the same kind of template, not a sign the wrong variant was picked or that
extraction was wrong.

This directly corroborates `driver_51x0.py`'s pattern too (read separately,
per advisor's pointer): `51x0` doesn't splice OTP bytes into
`DEVICE_CONFIG` itself — `DEVICE_CONFIG` stays a flat, already-checksummed
constant there, and calibration instead happens via **separate
`write_sensor_register` calls after config upload** (`0x0234`/`0x0236`/
`0x0238`/`0x023a`, values derived from `OTP[46:50]`). The real `533c`
vendor capture shows exactly this shape too: `COMMAND_WRITE_SENSOR_REGISTER`
calls appear immediately after `COMMAND_UPLOAD_CONFIG_MCU` and before
`COMMAND_MCU_GET_IMAGE`. So there are two live mechanisms in this codebase
family for getting calibration data onto the chip — config-blob patching
(`53x5`-style) and post-upload register writes (`51x0`-style) — and which
one (or both) `533c` needs isn't resolved by this pass.

## Sanity check on the other lead (per advisor)

The 102-byte `0xbb010002`-tagged "sealed" blob captured in
`phase2-psk-write-CORRECTION.md`/`vm-capture-analysis.md` does **not**
contain the live 32-byte OTP bytes anywhere in it (checked both the full
32 bytes and just the first 16, neither appears as a substring). Not a
useful lead for the config question; ruled out cleanly.

## Status

**PSK/handshake side: fully solved and confirmed working against real
hardware** (see `phase2-psk-write-CORRECTION.md`). **Image capture is
blocked on one remaining unknown: how to correctly build/patch the
`DEVICE_CONFIG` payload for this specific chip** — likely needs either (a)
the OTP-splice patch logic decompiled from this `.so`'s equivalent of
`53x5`'s `device_enable()`/`TCODE_TAG`/`DAC_L_TAG` handling, applied to one
of the 6 `MilanFSeries` templates, or (b) uploading a template with
placeholder calibration bytes and a *freshly computed* checksum (even
without real OTP-derived values) to see if the device accepts a
structurally-valid-but-uncalibrated config, which would at least confirm
which of the 6 templates is the right starting point before tackling
calibration.

Per advisor review: this is the natural stopping point for this session.
No further hardware attempts made after this analysis. The next step
(decompiling the OTP-to-config patch logic, or trying checksum-corrected-
but-uncalibrated uploads) is a real, scoped follow-on, not something to
proceed with unprompted.
