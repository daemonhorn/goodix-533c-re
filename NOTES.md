# RE Notes — Goodix 27c6:533c

## Hardware

```
Bus 003 Device 002: ID 27c6:533c Shenzhen Goodix Technology Co.,Ltd. FingerPrint
Negotiated speed: Full Speed (12Mbps)
bDeviceClass 255 (Vendor Specific), bcdDevice 1.00, iSerial 0 (no string)
1 config, 1 interface (class 255), 2 bulk endpoints:
  EP 0x01 OUT, bulk, wMaxPacketSize 64
  EP 0x83 IN,  bulk, wMaxPacketSize 64
```

Device node on this host: `/dev/bus/usb/003/002`, `crw-rw---- root plugdev`
— this user is in `plugdev`, so no root needed for basic libusb I/O.
A udev rule for this PID (`60-libfprint-2-tod1-goodix.rules`, from the
proprietary `.deb`) is already installed on this host, granting `plugdev`
access and setting `power/control=auto`.

## Family identification

Ruled out **match-on-chip (`goodixmoc`)**:
- Cloned `gitlab.freedesktop.org/libfprint/libfprint` (master) and
  `github.com/goodix-fp-linux-dev/libfprint`. Neither `id_table` in
  `libfprint/drivers/goodixmoc/goodix.c` contains `0x533c` (checked by
  direct grep of both clones).
- `goodixmoc`'s test fixture device (`tests/goodixmoc/device`, PID
  `0x609c`) has `bDeviceClass 0xEF` (IAD/composite) — our device is
  `0xFF` at the device level, single interface. Different generation/shape.
- `goodixmoc`'s probe path requires a valid serial-number string
  descriptor ending in `"B0"` (`g_str_has_suffix (serial, "B0")`,
  `goodix.c` probe). Our device has `iSerial 0` — no string descriptor at
  all. `g_usb_device_get_string_descriptor` on index 0 would error, and
  that error is treated as fatal in the MOC probe path. This alone would
  likely kill MOC-driver probing on this hardware even before protocol
  concerns.

Confirmed **GTLS (encrypted, match-on-host, raw-image)** family via static
analysis of the proprietary blob (read-only `strings`/`readelf`, no
disassembly/decompilation performed at this stage):

`extracted_driver/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/libfprint-tod-goodix-53xc-0.0.4.so`
(from the Ubuntu-focal `.deb`, Goodix/Canonical 2020, `libfprint-tod.so.1`
ABI):

- `readelf -d`: links `libfprint-2-tod.so.1` only (no image/crypto libs
  linked externally — mbedTLS etc. must be statically linked in).
- `strings` shows a full mbedTLS-derived GTLS handshake state machine:
  `SecGtlsHandshake`, `SecGtlsInit`, `SecGtlsRead`/`SecGtlsWrite`,
  `gtls_handshake_client_step`, `gtls_parse_client_hello`,
  `gtls_get_gea_key`, plus generic mbedTLS strings (`AES-128-CBC`,
  `bad server key exchange message (ECDHE curve)`, PEM certificate
  markers, etc.)
- Host-side algorithm/matching layer present as exported-looking symbols:
  `AlgEnrollstartInterface`, `AlgCommitTemplateInterface`,
  `AlgIdentifyFeatureSetInterface`, `EAadapter_commit_enroll`,
  `EAadapter_identify_featureset`, `DecodeFingerTemplate`,
  `EncodeFingerTemplate` — consistent with match-on-host (raw image +
  template built and matched on the PC), not match-on-chip.

This matches the profile of
[`goodix-fp-dump`](https://github.com/goodix-fp-linux-dev/goodix-fp-dump)'s
already-supported model families (`51x0`, `51x7`, `52xd`, `53x5`, `53xd`,
`5503`, `55x4`), all GTLS/raw-image, sharing one generic USB command set
(`goodix.py`) with per-model constants supplied by `driver_<model>.py`.

**No prior open-source work exists for the `53xc` group** (`530c`/`533c`/
`538c`, the PID grouping used by the closed driver's own udev rules):
- `goodix-fp-dump` issue [#31](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/issues/31)
  ("538c compatibility?") closed `wontfix`.
- [`goodix-firmware`](https://github.com/goodix-fp-linux-dev/goodix-firmware)
  has directories for every family above but none for `53xc`.
- Every "works on Linux" report for `533c` found online (AUR
  `libfprint-goodix-53xc`, Fedora COPR `manciukic/libfprint-tod-goodix`,
  the omarchy issue thread) is people repackaging the same closed blob —
  not an open reimplementation.
- No `libfprint` **C** driver exists yet for the GTLS family at all
  (upstream's only merged Goodix driver is `goodixmoc`), so a production
  driver is out of scope for now — see README "Scope".

## Model-specific constants needed (per `driver_53xd.py`/`driver_53x5.py` shape)

`goodix.py`'s protocol (command opcodes, framing, PSK-provisioning
handshake) is generic across models. Each `driver_<model>.py` supplies:

| Constant | Type/size | 53xd reference value (for shape only) |
|---|---|---|
| `TARGET_FIRMWARE` | string | `GF5298_GM168SEC_APP_13016` |
| `PSK_WHITE_BOX` | 96 bytes | (per-model constant) |
| `PMK_HASH` | 32 bytes (SHA-256 of `PSK_WHITE_BOX`) | (derivable once PSK found) |
| `DEVICE_CONFIG` | 256 bytes | sensor register/init blob |
| `SENSOR_WIDTH`/`SENSOR_HEIGHT` | ints | 80×64 for 53xd |

### Firmware-name candidates found in the blob (`strings`, read-only)

The blob is a multi-chip-family shared library — it contains many
`GF<chip>_<variant>_APP_<ver>` strings, not just one:

```
GF3206_HT_APP_20045
GF3208_HT_APP_20045
GF3208_ST411SEC_APP_12116
GF3258_HT_APP_20045
GF3258 DN2
GF3266_HT_APP_20045
GF3266_ST411SEC_APP_12116
GF3268_HT_APP_20045
GF3288_HT_APP_20045
GF3288_ST411SEC_APP_12116
GF3658_ST411SEC_APP_12116
GF3658 DN3
GF5288_GM168SEC_APP_13016   <-- closest shape-match to 53xd's GF5298_GM168SEC_APP_13016
GF5288_HT_APP_20045
```

**Leading hypothesis:** `GF5288_GM168SEC_APP_13016` — one digit off from
`driver_53xd.py`'s `GF5298_GM168SEC_APP_13016` (`GF52_9_8` vs `GF52_8_8`),
same `GM168SEC_APP_13016` suffix (chip generation/firmware-build family).
**Not yet confirmed which PID(s) this string maps to** inside the blob —
the binary likely has a PID→firmware lookup table (same pattern as
`goodixmoc`'s `switch (productid)` in `goodix.c`). Confirming this mapping
is the first Workflow task.

## Open questions / next steps

1. Which firmware string above (if any) is the one selected when the
   blob's probe path sees PID `0x533c`? (Static analysis — trace PID
   checks in the binary.)
2. Locate the 96-byte `PSK_WHITE_BOX` and 256-byte `DEVICE_CONFIG` blobs
   in `.rodata`/`.data.rel.ro`, anchored from the GTLS/PSK code paths.
3. Build `driver_53xc.py` from `driver_53xd.py` with these constants and
   validate against the real device (single physical device — sequential,
   not parallelizable).
4. If static analysis stalls: capture real blob traffic via Wireshark
   (`goodix-fp-dump/wireshark/goodix_message.lua`) — needs an Ubuntu VM
   with the device passed through via QEMU, since Debian has no
   TOD-enabled `fprintd`. See the plan file for details.

## Result (final)

Real image capture confirmed working against real `27c6:533c` hardware,
end to end, using only the open-source protocol reimplementation. Summary
of what the "open questions" above actually resolved to:

1. Firmware string: `GF5288_GM168SEC_APP_13016` (confirmed via live read).
2. `PSK_WHITE_BOX` turned out unnecessary — this unit's PSK was already
   correctly provisioned to all-zero from the factory (confirmed via a
   live vendor-driver capture, see `findings/vm-capture-analysis.md`).
   `DEVICE_CONFIG`: the "MilanFn" template (of 6 named candidates found in
   `.rodata`) is correct for this PID, needing only a checksum
   recomputation (no OTP calibration splice) to be accepted —
   `findings/device-config-checksum-analysis.md`.
3. `driver_53xc.py`/`run_533c.py` built and validated against the real
   device — see `findings/image-capture-success.md`. Also needed: an
   order-tolerant USB read layer (this chip doesn't send `[ack][data]` in
   a fixed order, unlike every sibling model) and an `openssl s_server`
   fix (`-ign_eof` + a kept-open stdin, or the TLS session gets silently
   torn down before the image arrives).
4. The VM+QEMU capture (step 4) *was* used, and was the key unlock for
   steps 1–2 — see `findings/vm-capture-analysis.md` and
   `findings/phase2-psk-write-CORRECTION.md`.

Opened as goodix-fp-dump PR #76, referencing issue #31 — then discovered
another contributor (nikicat) had independently reached the same device
and already had a materially more complete driver open as
[PR #75](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/pull/75)
(stacked on [#72](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/pull/72)/[#73](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/pull/73),
open since 2026-08-06, ~2.5 weeks before this project's PR). Theirs:
derives TLS session keys and decrypts in-process instead of depending on
`openssl s_server`'s stdout framing; captures `DEVICE_CONFIG` live from
vendor traffic per-unit instead of patching a static template; self
-calibrates the FDT threshold; and gets an actual finger-present capture
with visible ridge detail — this project's driver only ever produced the
no-finger calibration frame. #72's library-level ACK-tolerance fix
(a read/pushback mechanism in `goodix.Device`) is also a cleaner
generalization of the same problem than the local per-driver
`tolerant_*` workaround used here.

Closed PR #76 in favor of the existing stack and left a comment on #75
with what was still additive: independent cross-validation of the
all-zero PSK and 108x88 dimensions on a second physical `533c` unit, the
PSK-write inverted-ACK-convention finding, and the six named
`DEVICE_CONFIG` template offsets recovered from static analysis (a
possible fallback for `530c`/`538c` owners without a live vendor capture
to sniff from). Updated the issue #31 comment accordingly.

Not done, and out of scope for this project: a `libfprint` C driver (see
README "Scope"), `530c`/`538c` support (untested, no hardware), and a
`goodix-firmware` PR (that repo wants raw chip firmware dumps, which
were never available here — only the closed shared library was).

## Cross-validating #75 on this hardware

After closing #76, checked out nikicat's `driver-53xc` branch (#72/#73/#75
combined) and ran it directly against this project's own `27c6:533c` unit
— a second, independent physical device from their XPS 13 9310. Findings,
posted as a follow-up PR comment:

- Their live-captured `DEVICE_CONFIG` (from their machine) was **accepted
  verbatim** by `upload_config_mcu()` on this unit too, and produced
  identical downstream byte counts (`14334 B encrypted -> 14260 B plain`,
  matching their log exactly) and chip ID (`0x220ca1`). This means
  `DEVICE_CONFIG` is not per-unit-calibrated after all — which corrects
  this project's earlier PR comment (see above) that framed the six
  static template offsets as a per-unit-calibration fallback. That framing
  was wrong; retracted on the PR.
- `#72`'s ACK-tolerance fix and `#73`'s recon tooling both ran cleanly on
  this unit with no errors — the ordering quirk this project worked
  around locally in its own (now-closed) driver either doesn't affect
  this unit, or #72's fix generalizes to it either way. No bug found to
  report back.
- Finger detection genuinely responds to a real touch (confirmed via a
  small ad hoc diagnostic script computing Pearson correlation between
  the no-finger reference frame and a live finger-present frame: `r =
  0.88`, mean shifted from 3600 to 3996 out of a 0-4095 range) — this
  isn't a stale/cached-frame artifact.
- What didn't reproduce on this unit: visually clear ridge flow in the
  final `fingerprint.pgm`, across three attempts with firmer/held
  touches, even after contrast stretching and per-row detrending. Given
  the 0.88 (not ~1.0) correlation, real differential signal is present;
  the leading (untested) hypothesis is that `flat_field()`'s single
  global linear fit doesn't fully compensate for a possibly-nonlinear
  gain difference between the reference capture (gain `0xc2`) and the
  live capture (gain `0x86`) on this unit. Not confident enough to call
  this a bug — reported to the PR as an open data point, not a defect.
- Also noted (pre-existing, not introduced by #75): `tool.write_pgm()`
  writes `{height} {width}` where the PGM spec wants width first, so
  every `.pgm` this repo produces reads transposed in a standards
  -compliant viewer (bit us both here and in this project's own earlier
  capture); and `flat_field()`'s corrected output contains negative
  pixel values, which most PGM readers reject outright.

Full comment: https://github.com/goodix-fp-linux-dev/goodix-fp-dump/pull/75#issuecomment-5382822279

## Ridge visibility resolved: gain calibration, not protocol

The open question from the PR #75 cross-validation (real touch produced
correlated but not visibly ridge-structured images) is resolved:
**gain, not protocol.** `driver_53xc.py` hardcodes `0x86` as the
live-capture gain (tuned for nikicat's XPS 13 9310). On this unit, a
7-point gain sweep with a finger held down through all captures
(`debug_gain_sweep.py`) showed `0x86` clips ~47% of pixels
(`clipped_px=4462/9504`) — ridge contrast was being cut off the top of
the 12-bit range. `0xc2` (the gain `driver_53xc.py` uses for the
no-finger *reference* frame) is the only fully headroom-safe gain for
the *live* frame on this unit (`clipped_px=0/9504`). Re-running
`flat_field()` with both reference and live captured at `0xc2` produces
a clearly ridge-structured image — curved, branching bands, not the flat
horizontal banding every earlier attempt produced. Posted to PR #75.

This settles the question that was gating SIGFM matcher work: there is
real, recoverable ridge signal on this hardware, at least at the right
gain. Native driver work (see below) can proceed on that basis, though a
production driver would need either a fixed higher-headroom gain or a
small pre-capture clipping check rather than a hardcoded value, since
the safe gain is apparently unit-specific.

## Ethics/legal note

Only original analysis, derived protocol constants, and newly-written
open-source code are kept/published here. The proprietary `.deb`/`.so` are
never redistributed — this mirrors how `goodix-fp-dump` itself documents
protocol constants for other models without shipping the vendor binaries
they were derived from. This static analysis (strings/section inspection,
no decompilation yet) is for interoperability — reproducing observable
behavior of hardware the user owns, not copying vendor code.
