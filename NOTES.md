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

## Native driver: two candidate bases tried, neither is a direct fit

Full detail: `findings/native-driver-architecture.md`. Short version:

- Tried `AndyHazz/goodix53x5-libfprint` (forked, `add-533c-support` branch)
  first — same 108x88 sensor family, already has SIGFM matching wired in.
  Six real protocol bugs found and fixed by iterating directly against
  real hardware (wrong USB interface/endpoints, wrong RESET payload +
  skipped mandatory second reply, wrong PSK-read command shape) — but its
  crypto layer assumes a proprietary non-standard "GTLS" handshake this
  device doesn't speak. 533c speaks real, standards-compliant TLS-PSK
  (proven by this project's own `establish_tls()` successfully proxying
  it through genuine `openssl s_server -psk`). Discovered this only after
  getting all the way through OTP/chip-ID/PSK verification against real
  hardware, into the GTLS handshake itself.
- Pivoted to `goodix-fp-linux-dev/libfprint`'s `goodixtls` branch (forked,
  same branch name) — its `goodixtls.c` is a real embedded TLS-PSK
  *server* (genuine OpenSSL `SSL_CTX`, all-zero PSK callback) with pack
  flags (`0xa0`/`0xb0`) matching this device exactly. But its shared FDT
  state machine assumes a static config blob; 533c's FDT commands need a
  *dynamic*, per-session baseline template read from the device at the
  start of each session — a structural mismatch, not a small patch.
  Confirmed by reading `goodix.c` directly: the primitive can carry a
  reply payload, but the shared SCAN state machine discards it, and
  `get_mcu_cfg()`'s vtable signature has no way to carry a runtime value
  forward. Also: `FpImageDevice` inheritance forecloses SIGFM as this
  base stands (SIGFM needs `FpDeviceClass`-level enroll/verify control).
- Net position: a working driver needs `goodixtls.c` (TLS transport) +
  new FDT/capture code written directly against `goodix.c`'s primitives
  (bypassing `goodix5xx.c`) + AndyHazz's `FpDeviceClass`/SIGFM shape
  ported onto that transport. Every protocol-level fact this needs (exact
  bytes for reset/PSK-read/image-request/FDT template, chip ID, firmware
  string, DEVICE_CONFIG) is confirmed against real hardware and recorded
  in the findings doc. Not started this session — flagged as the next
  concrete step.
- Both forks pushed to GitHub (`daemonhorn/goodix53x5-libfprint` branch
  `add-533c-support`, `daemonhorn/libfprint` branch `goodixtls`), each
  with an `upstream` remote pointing at its original, for future PRs.

## Native capture working: first real image from the native driver

The "next concrete step" above is done. `daemonhorn/libfprint` branch
`goodix533c-open-capture` (pushed) has a new `drivers/goodix533c/` — a
plain `FpDevice`-rooted driver (not `FpImageDevice`, so SIGFM stays
possible later), reusing `goodix_proto.c` and `goodixtls.c` verbatim,
with the command layer and TLS handshake pump ported from `goodix.c`
(adapted off the shared `FpiDeviceGoodixTls` private struct, not linked
against it), and a new FDT/capture sequence written directly from
`capture_golden_session.py` since `goodix5xx.c`'s static-config FDT
machinery doesn't fit this device.

Verified independently against real hardware (not just the implementing
agent's own report — rebuilt from a clean tree and re-ran myself):
`open()` succeeds, and one full no-finger reference frame captures,
TLS-decrypts, and decodes to raw pixel range `[0, 4056]` (12-bit sensor,
non-degenerate). Output PGM (108x88, confirmed via `file`) visually shows
exactly the fixed-pattern-noise grid `driver_53xc.py`'s docstring
describes for a no-finger capture — not ridge data (no finger was
present), but clearly real, structured sensor output, not garbage.

Scope was deliberately narrow (`open()` + one capture, no enroll/verify,
no SIGFM) to validate the transport/crypto/capture chain in isolation
before building matching on top of it. Next: finger-detect wait loop
(live capture, flat-fielding against the reference frame via the
least-squares regression `flat_field()` already uses in
`driver_53xc.py` — not a plain subtract, correcting an overstatement in
an earlier version of this note), then `FpDeviceClass` enroll/verify/
identify with SIGFM matching, porting the matcher shape from
`goodix53x5-enroll.c`/`-auth.c`/`-match.c` and vendoring `sigfm/` from
the AndyHazz fork.

## Full capture pipeline working end to end, real ridge image produced

The "next" item above is done. `goodix533c-open-capture` (pushed) now
implements the complete `driver_53xc.py` `run_driver()` sequence:
sleep_mode, query_mcu_state, arm finger detection, wait for the
device's asynchronous touch notification, re-arm, live capture at gain
`0xc2`, `mcu_switch_to_fdt_up`, and `flat_field()` (ordinary
least-squares regression, ported and independently verified
byte-for-byte against the Python formula) followed by a proper min-max
stretch to a spec-correct PGM.

Verified against a real touch on real hardware (required a human — an
agent can't physically touch a sensor). Took several attempts to get
the coordination right: the sequence reaches the "touch the sensor"
prompt in under half a second, so a finger already resting near the
sensor before the prompt corrupts the reference-frame capture (several
early attempts showed anomalous reference-frame pixel ranges,
consistent with this). Once the finger was kept fully clear until after
the prompt and lifted off after ~2s, every stage completed cleanly,
including `mcu_switch_to_fdt_up` (which appears to be edge-triggered on
lift-off, mirroring `fdt_down`'s edge-trigger on landing — it had timed
out in the immediately preceding attempt, where the finger was still
down when it was sent). The resulting flat-fielded image shows clear,
visible curved ridge structure — not just correlated noise. The actual
capture was not committed to git (see "Ethics/legal note" below — the
PSK is public, so a committed live capture would be a real, recoverable
fingerprint image); it was reviewed directly with the user instead.

Remaining before this is a complete driver: `FpDeviceClass`
enroll/verify/identify vfuncs and SIGFM matching (this driver is
currently capture-only, exercised via a test-only entry point, not
wired into libfprint's actual enroll/verify/identify actions at all).

## SIGFM matching wired: enroll/verify/identify implemented

The "remaining" item above is done. `goodix533c-open-capture` (pushed)
now has real `FpDeviceClass` `enroll`/`verify`/`identify`/`cancel`
vfuncs, backed by SIGFM (SIFT+CLAHE via OpenCV) matching vendored from
`sigfm/` (AndyHazz's fork) and a driver-side wrapper
(`goodix533c-match.c`, own template magic `"G533"` — not
interoperable with goodix53x5's templates, different preprocessing
pipeline). The enroll/verify/identify state-machine shape (quality
gates on keypoint count and non-contact/clipped fraction, deferred
result reporting until after finger lift-off, shared verify/identify
SSM dispatching on the current libfprint action) is ported from
`goodix53x5-enroll.c`/`-auth.c`, adapted onto this driver's own proven
transport rather than goodix53x5's. `open()` now does the full
TLS-handshake/config-upload/FDT-baseline sequence once per session;
enroll/verify/identify repeat only the attempt-scoped parts (reference
capture, finger wait, live capture, finger-up wait) via four reusable
sub-SSMs.

Independently verified: clean build from scratch, and a host-side SIGFM
round-trip test (extract → serialize → deserialize → self-match, no
hardware needed) — self-match score 37947 against a `GOODIX533C_SIGFM_
BEST_MIN` threshold of 150, cross-match against an unrelated frame
scores 0. Re-ran this myself independently, not just trusting the
implementing agent's report.

**Not yet verified**: the real enroll-then-verify success path, which
needs a human — up to 8 touches for enrollment (lifting between each),
then at least one more for verify. Not attempted yet this session.

Also produced this session: `findings/freebsd-porting-plan.md`, a
research-only planning document (no code changes) for a hypothetical
future FreeBSD port. Bottom line: the driver's own code has no
Linux-specific dependencies (confirmed by direct source audit), and
every dependency (GLib, OpenSSL, OpenCV, Meson) is packaged and current
on FreeBSD, including upstream libfprint itself (1.94.10, actively
maintained port). The real blocker is hardware: nobody in this project
has a FreeBSD machine with this sensor, and a historical GUsb bug
(`g_usb_device_get_parent()` returning NULL on FreeBSD, fixed upstream
~June 2025) means even device *detection* isn't confirmed working on a
typical FreeBSD install, let alone this specific driver. Not an active
work item — a plan for if/when someone has that hardware.

## umockdev test harness added; found (and partially debugged) a real gap in the existing fixture

`daemonhorn/libfprint` branch `goodix533c-open-capture` now has
`tests/goodix533c/` wired into `meson test`, following this tree's
sibling-driver convention (`custom.pcapng`/`custom.py`, `tests/goodixmoc/`
as the structural template). Reuses the already-vetted finger-absent
`device`/`capture.pcapng` fixture from earlier this session (copied
byte-identical — confirmed independently via checksum — into the
submodule, original untouched).

Real finding, not a driver bug: replaying that fixture against the
actual (working, hardware-verified) driver does not get past the second
open() command. Root cause, confirmed independently (tshark's decoded
URB fields, cross-checked against `tests/goodixmoc`'s known-good fixture
as a control): **every bulk-IN completion event on the sensor's real
endpoint in this capture has zero captured reply payload bytes** — the
original recording captured outgoing requests in full but never the
device's replies. This is a property of how that original capture was
taken, not something fixable in the driver or the test harness.

I tried to fix this myself (a safe, finger-absent recapture doesn't need
a human) — reran `capture_fixture_session.py` with `tshark -s 0` and
then `-s 65535`, ruling out snaplen as the cause: same zero-payload
result both times, confirmed via raw hex inspection (the 64-byte frames
are entirely consumed by usbmon's own header, no truncated data at all).
The actual cause is a deeper usbmon/kernel-capture property not yet
identified — documented in `tests/goodix533c/README.md` with the exact
diagnostic trail so a future attempt doesn't repeat the same debugging.

Given the replay gap, `custom.py` is honestly scoped to only what's
currently verifiable (device discovery, feature-flag assertions matching
the driver's actual wiring) rather than shipping a permanently-red test.
`meson test goodix533c` passes cleanly — independently re-verified
myself. Two follow-ups are documented for later, both requiring new
captures: (1) a corrected finger-absent capture that actually retains
reply payloads, to restore `open_sync()`/`close_sync()` coverage; (2) a
human-supplied, finger-present capture for enroll/verify/identify
coverage once someone runs the real hardware test below — which, per the
standing PSK-is-public safety policy, must never be generated by an
agent.

## Full driver validated end to end: real enroll + verify, real match

The native driver works, completely, against real hardware. Ran a
standalone GObject-introspection script (not umockdev — the actual
physical sensor) driving libfprint's real public API:
`FPrint.Device.enroll_sync()` through all 8 stages (a real touch per
stage, lifting fully between each), then `verify_sync()` against the
freshly enrolled print. Every enroll stage reported success; verify
returned `True` — a genuine SIGFM match against a real second touch,
not a self-comparison or synthetic test.

This closes the loop from the very start of this project: raw USB
protocol reverse-engineering → proven Python capture → architecture
dead-ends on two candidate C driver bases → a from-scratch native driver
combining the right transport (`goodixtls`'s embedded TLS-PSK server)
with the right matching architecture (`FpDeviceClass` + SIGFM, not
`FpImageDevice` + NBIS) → SIGFM wired in → real enroll/verify success.
The driver (`daemonhorn/libfprint`, branch `goodix533c-open-capture`,
all work pushed) now does what the original goal was: open-source
fingerprint authentication for this sensor on Debian, with no
proprietary blob involved anywhere in the path.

Remaining, not blocking the core result: the test-harness fixture gap
(previous section) and whatever it takes to get this upstreamed /
packaged for real-world use (not attempted this session — this session's
scope was proving the driver works, not distribution).

## PR opened, umockdev fixture gap resolved (mostly), real package built and verified

Picking up the two "remaining" items from the previous section: this is
now upstreamed and packaged for real-world use.

**PR opened**: [goodix-fp-linux-dev/libfprint#40](https://github.com/goodix-fp-linux-dev/libfprint/pull/40),
`daemonhorn:goodix533c-open-capture` → `goodix-fp-linux-dev:goodixtls`.
Before pushing, fixed three pre-PR issues a maintainer would have bounced
on sight: `goodix533c` was in `default_drivers` (forcing OpenCV on every
other in-flight driver PR via a plain `meson setup`), a GLib version
guard checked the wrong macro (`GLIB_CHECK_VERSION`, the build machine's
headers, instead of `GLIB_VERSION_MAX_ALLOWED`, the project's declared
floor) so the deprecation warning it was meant to silence still fired,
and four unaligned `guint16*`/`guint32*` pointer casts (UB, real SIGBUS
risk on strict-alignment architectures) needed `memcpy`.

**umockdev fixture**: the "real gap" flagged two sections up turned out
to be two separate, real bugs, both now fixed — full diagnosis in
`vendor/libfprint-goodixtls/tests/goodix533c/README.md`'s "Replay status"
section, short version:

1. Every bulk-IN reply payload was silently redacted on capture. Root
   cause: this host's kernel `lockdown` mode (`confidentiality`, usually
   Secure-Boot-triggered) blocks `LOCKDOWN_USB`, which usbmon respects —
   confirmed via the text interface returning `EPERM` even as root, and
   the binary interface (used by both `tshark` and `dumpcap`, so not a
   tool-choice issue) reporting correct transfer lengths but always
   zeroing captured data. Not fixable on this host without touching
   Secure Boot/lockdown, which was explicitly out of bounds. Fixed by
   capturing from inside the project's existing `vm/` VM instead (its
   guest kernel has no lockdown) — new `vm/usbmon-capture-in-vm.sh`,
   verified byte-exact (14835/14835 bytes captured, including the full
   14338-byte image frame).
2. Even with real payload, replay still desynced
   (`Reaping discard URB... without corresponding submit`). After ruling
   out write ordering, `urb_id` reuse, root-hub interleaving, and reply
   content itself (each via a targeted, reasoning-checked experiment, not
   guesswork) — actual cause: the fixture's `device` file still declared
   `busnum=3/devnum=6` from the very first capture, but the VM recapture
   used its own topology (`bus=1/device=2`). umockdev needs these to
   match. Relabeling the pcap's bus/device fields fixed replay completely
   through the entire non-TLS open() sequence.

What's left, and it's a structural limit, not a bug: replay still can't
get past the TLS handshake itself. Traced directly through
`goodix533c.c`: the replayed ClientHello gets fed into the driver's own
embedded TLS server, whose `SSL_accept()` generates a genuinely fresh
`ServerHello` (new randomness, new ECDHE keys) every run — output that
can never byte-match a previously recorded session. No pcap fix can
address this; `custom.py` stays scoped to discovery/feature-flags, and
the concrete follow-up (a test stopping before TLS, which the fixture can
now actually support) is documented in the fixture's README rather than
chased further this session.

**Real package built and verified working**: `packaging/build-libfprint-deb.sh`
builds an actual `libfprint-2-2` replacement (not the earlier
`goodix-533c-test`'s standalone diagnostic tool) — full default driver
set plus `goodix533c`, `Depends:` computed via `dpkg-shlibdeps` rather
than hand-maintained, lintian-clean. Installed via `dpkg -i` and
independently confirmed end-to-end on real hardware: `fprintd-enroll`
(all 8 stages) and `fprintd-verify` both succeeded through the actual
system `fprintd` service, not just the standalone GObject test script
from the previous section. Published as a GitHub release:
https://github.com/daemonhorn/goodix-533c-re/releases/tag/libfprint-1.94.5-0goodix533c1
Package version is deliberately lower than the distro's, so a plain
`apt upgrade` reverts to the official package on its own.

### Outstanding

- **PR #40**: open, no review yet.
- **umockdev**: add a test-only entry point + `custom.py` coverage that
  exercises up through `request_tls_connection` (proven replayable now)
  without needing the TLS stage itself — see the fixture README's
  "Follow-up needed" section.
- **Finger-present capture** for `enroll_sync()`/`verify_sync()`/
  `identify_sync()` umockdev coverage still needs a human-supervised
  recapture (never agent-generated, per the standing PSK-is-public
  policy) — `vm/usbmon-capture-in-vm.sh` is the mechanism, just pointed
  at a different, human-run capture script.
- **`530c`/`538c`**: same PID grouping, protocol likely shared, still
  completely untested — no hardware.
- **"Push the .deb to GitHub Packages"**: asked for, not done. GitHub
  Packages has no native Debian/APT registry type (npm/Maven/NuGet/
  RubyGems/container only), and the current `gh` auth lacks the
  `write:packages` scope regardless. Real options are (a) push as a
  generic OCI artifact to `ghcr.io` via `oras` — literally "GitHub
  Packages" but `oras pull` + `dpkg -i` to use, not `apt install`, or
  (b) a real APT repository (`reprepro`/`aptly` + GitHub Pages) — more
  useful day-to-day but a different GitHub feature entirely, not
  Packages. Asked the user which; awaiting an answer.

## Ethics/legal note

Only original analysis, derived protocol constants, and newly-written
open-source code are kept/published here. The proprietary `.deb`/`.so` are
never redistributed — this mirrors how `goodix-fp-dump` itself documents
protocol constants for other models without shipping the vendor binaries
they were derived from. This static analysis (strings/section inspection,
no decompilation yet) is for interoperability — reproducing observable
behavior of hardware the user owns, not copying vendor code.
