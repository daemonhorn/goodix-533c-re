# Image capture succeeded: root cause and fix

`capture_full_milanfn.py` now reliably captures a real image from the
27c6:533c sensor end-to-end via the open-source protocol reimplementation.
This closes the plan's Phase 2 exit criterion.

## The final blocker: openssl s_server closing on stdin EOF

Symptom across many runs: the TLS-PSK handshake with the real device
completed cleanly (correct cipher suite `0x00AE`/`TLS_PSK_WITH_AES_128_CBC_SHA256`,
matching the real vendor capture — see `vm-capture-analysis.md`), every
protocol step through `mcu_get_image` succeeded without exception, and the
14325-byte TLS Application Data record was accepted by the socket
(`tls_client.send()` reported all bytes sent) — but `openssl s_server`'s
stdout, which should contain the decrypted plaintext image, always showed
"Decrypted plaintext bytes: 0" while the process stayed alive
(`poll() is None`).

Root cause: `subprocess.Popen(..., stdout=subprocess.PIPE, ...)` was
launched **without** `stdin=subprocess.PIPE`, so `openssl s_server`'s stdin
inherited (or immediately saw EOF on) an already-closed/non-interactive
fd. `s_server` sends `close_notify` and tears down the session as soon as
its stdin hits EOF. Because there are several seconds of USB round-trips
between handshake completion and the image fetch, the TLS session was
already closed server-side by the time the Application Data record
arrived — openssl silently discards records on a closed session, hence
zero decrypted bytes despite no visible error.

This also explains an earlier red herring: in some runs the final
handshake `recv()` contained what looked like a trailing encrypted Alert
record appended after ChangeCipherSpec+Finished. That was `s_server`
already reacting to the EOF-triggered shutdown mid-handshake-relay, not a
distinct bug. The TLS-record-boundary-parsing/truncation logic added to
work around it stayed in place (harmless, and technically more correct
relay behavior) but was **not** the actual fix.

## Fix

Two changes to the `openssl s_server` invocation in `capture_full_milanfn.py`:

```python
tls_server = subprocess.Popen(
    ["openssl", "s_server", "-nocert", "-psk", PSK.hex(), "-port",
     "4433", "-quiet", "-ign_eof", "-cipher",
     "PSK-AES128-CBC-SHA256:@SECLEVEL=0"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT)
```

1. `stdin=subprocess.PIPE` — gives the process an open pipe that Python
   holds a live reference to for the process's full lifetime (never
   closed until `tls_server.terminate()`), so it never sees EOF.
2. `-ign_eof` — openssl's documented flag to not close the connection on
   stdin EOF, as defense in depth even if something else closes the pipe.

## Result

```
mcu_get_image() ACK length: 10
mcu_get_image() DATA raw length: 14338, inner length: 14334
tls_client.send() reported 14325 bytes sent (of 14325)
Decrypted plaintext bytes: 14260
Decoded 9504 pixels
Non-zero pixels: 3351/9504, min=0, max=284
```

## Sensor dimensions: 108x88, corroborated (not a confirmed firmware constant)

9504 factors into 12 plausible width x height pairs in the 30-200 range.
`SENSOR_WIDTH`/`SENSOR_HEIGHT` were never found statically (Phase 1
concluded the only numeric lead, `(88,108)`, was "actively disfavored" —
see `dims-and-inventory.md` §A and `SUMMARY.md` — on the theory that it
belonged to this same `.so`'s bundled `53x5`/`53xd` sibling config data,
not to `533c` specifically).

Reshaping the decoded pixel list row-major at each of the 12 candidate
widths and rendering as an image settles this empirically: **only
width=108 produces a coherent 2D shape** — a rounded vignette (bright
center, dark corners) consistent with a capacitive sensor's physical
active-area falloff in a no-finger background read. Every other
candidate (including the naively-picked 96x99 originally used) produces
pure horizontal banding with no 2D structure, which is exactly what
reshaping row-major data at the wrong row length looks like. This
reverses Phase 1's "disfavored" call: `108x88` is either genuinely this
chip's sensor size, or `530c`/`533c`/`538c` share the same physical die
as `53x5`/`53xd` (plausible — same OEM sensor package, different
firmware/config SKU). Not a firmware-constant-level confirmation, but
strong shape evidence, and `108 * 88 = 9504` matches the pixel count
exactly.

Visually, the 108x88 image (contrast-stretched, no finger present — this
is the calibration/"clear" read the sensor does as part of its normal
`mcu_get_image` cycle, matching the 3x-repeated pattern seen in the real
vendor capture) shows a coherent sensor-shaped vignette, not noise.
Random or misaligned AES-CBC decryption would produce uniform noise with
no such structure, so this is strong evidence the crypto, framing, and
pixel-decode path are all correct.

Note: `vendor/goodix-fp-dump/tool.py`'s `write_pgm()`/`read_pgm()` write
`width`/`height` swapped relative to the PGM spec's own header order (an
existing quirk in the vendored, third-party code, self-consistent within
that pair of functions but not standard-PGM-compliant) — external readers
like PIL parsed our first `write_pgm()`-produced file as if maxval/shape
were different than intended, showing a nonsensical max pixel value of
4545 vs. the true (directly-decoded) max of 284. `capture_full_milanfn.py`
now writes the PGM file directly with a standard-compliant header instead
of calling the vendored `write_pgm()`, avoiding this.

## Status

**Phase 2 (prove image capture) is complete.** All constants needed —
firmware string, PSK (all-zero, confirmed already provisioned),
`DEVICE_CONFIG` (MilanFn variant, checksum-recomputed from the static
template) — are now confirmed against real hardware, not just inferred
from static analysis. Sensor dimensions (108x88) are strongly
shape-corroborated from live pixel data but not confirmed via a firmware
constant — flag this as "likely, not certain" in any downstream use.

Remaining known gaps, deferred (not needed for the "prove capture" goal):
- OTP-derived calibration patching into `DEVICE_CONFIG` (per `53x5`'s
  `TCODE_TAG`/`DAC_L_TAG` pattern) was not implemented — the checksum-only
  fix was sufficient to get the config accepted and produce a real image,
  but a finger-present capture may need this for well-calibrated ridge
  detail. Untested since no finger was placed on the sensor during capture.
- This session never tested with an actual finger present — only the
  no-touch "clear" calibration image was captured (matching what the real
  driver does 3x in a row during enrollment before finger detection).
