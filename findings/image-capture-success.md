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
Plausible (w,h) pairs include: (96, 99)
Non-zero pixels: 3351/9504, min=0, max=284 (post decode_image transform)
Wrote vm/clear-MilanFn.pgm as 96x99 (raw PGM pixel range 0-4545)
```

Visually, the decoded image (contrast-stretched, no finger present — this
is the calibration/"clear" read the sensor does as part of its normal
`mcu_get_image` cycle, matching the 3x-repeated pattern seen in the real
vendor capture) shows clean horizontal banding consistent with the
sensor's row-scan readout — structured signal, not random noise. Random or
misaligned AES-CBC decryption would produce uniform noise with no such
periodic structure, so this is strong evidence the crypto, framing, and
pixel-decode path are all correct, not a lucky-looking artifact.

## Status

**Phase 2 (prove image capture) is complete.** All constants needed —
firmware string, PSK (all-zero, confirmed already provisioned),
`DEVICE_CONFIG` (MilanFn variant, checksum-recomputed from the static
template), sensor dimensions (96x99) — are now confirmed against real
hardware, not just inferred from static analysis.

Remaining known gaps, deferred (not needed for the "prove capture" goal):
- OTP-derived calibration patching into `DEVICE_CONFIG` (per `53x5`'s
  `TCODE_TAG`/`DAC_L_TAG` pattern) was not implemented — the checksum-only
  fix was sufficient to get the config accepted and produce a real image,
  but a finger-present capture may need this for well-calibrated ridge
  detail. Untested since no finger was placed on the sensor during capture.
- This session never tested with an actual finger present — only the
  no-touch "clear" calibration image was captured (matching what the real
  driver does 3x in a row during enrollment before finger detection).
