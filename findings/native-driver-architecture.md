# Native libfprint driver for 27c6:533c — architecture findings

## Summary

Two candidate upstream bases were evaluated hands-on (real driver code
written, built, and run against real 27c6:533c hardware for both). Neither
is a direct adaptation target: each is structurally wrong for this device
in a different subsystem. A working native driver needs pieces from both,
plus new code neither has. This document records what was learned so the
next attempt doesn't have to re-derive it.

## The two candidate bases

### `AndyHazz/goodix53x5-libfprint` (forked to `daemonhorn/goodix53x5-libfprint`, branch `add-533c-support`)

A complete, actively maintained, `FpDeviceClass`-based driver for the
Goodix HTK32 board (PIDs `0x5335`/`0x5385`/`0x5395`), same 108x88 GF5288
sensor family, same OTP/calibration math, and — critically — already has
SIGFM matching wired in (`sigfm/` + `goodix53x5-match.c`/`-enroll.c`/
`-auth.c`), tuned for this exact sensor size.

**What's right about it:** the FDT/template handling (see below) and the
whole enroll/verify/identify shape needed for SIGFM.

**What's wrong about it:** its crypto/transport layer assumes a
proprietary, non-standard "GTLS" handshake (`goodix53x5-crypto.c`, a
`GoodixGtlsCtx` with manually-implemented key derivation, exchanged as a
3-message random/identity handshake wrapped inside the *regular* command
channel, category 0xD/command 0x1). 533c does not speak this. It speaks
real, standards-compliant TLS-PSK — proven directly, by this project,
earlier in this session: `driver_53xc.py`'s `establish_tls()` forwards the
device's raw handshake bytes to and from a genuine `openssl s_server -psk
<all-zero-hex>` subprocess, and it works end-to-end (image capture
succeeded through this path multiple times). `session_keys()` derives the
TLS session keys via the standard TLS 1.2 PRF (RFC 5246) from a suite
0x00AE premaster secret shaped per RFC 4279 (`len‖zeros‖len‖PSK`) — this
is textbook TLS-PSK, not a proprietary scheme.

Also wrong on this base, independently of the crypto mismatch: its
`preset_psk_read` reused goodix53x5's unrelated "production read" command
shape, and its RESET command had both a wrong payload and skipped a
mandatory second reply.

### `goodix-fp-linux-dev/libfprint`, branch `goodixtls` (forked to `daemonhorn/libfprint`, same branch)

An `FpImageDevice`-based base class (`goodix5xx.c`/`goodix5xx.h`) shared by
several in-flight PRs (511, 53x5, 55x4, 5f10, 5e0a — none merged
upstream). `goodixtls.c` (201 lines) is a complete, working, embedded
TLS-PSK **server** using real OpenSSL `SSL_CTX`/PSK-callback APIs over a
`socketpair()`-backed background thread — this is exactly the mechanism
533c needs, standing in for the `openssl s_server` subprocess our own
Python driver shells out to. Confirmed by exact match: `goodix_proto.h`
defines `GOODIX_FLAGS_MSG_PROTOCOL (0xa0)` / `GOODIX_FLAGS_TLS (0xb0)`,
identical to `goodix.py`'s `FLAGS_MESSAGE_PROTOCOL = 0xa0` /
`FLAGS_TRANSPORT_LAYER_SECURITY = 0xb0`.

**What's right about it:** the crypto/transport layer (`goodixtls.c`) and
the generic command layer (`goodix.c`).

**What's wrong about it:** `goodix5xx.c`'s FDT (finger-detect) mode
switching assumes a *static* configuration blob, sourced from
`cls->get_mcu_cfg()` — a **no-argument** function pointer
(`typedef GoodixTls5xxMcuConfig (*GoodixTls5xxGetMcuFn)(void);`) called
identically at every FDT mode-switch site (`SWITCH_TO_FDT_MODE`,
`SWITCH_TO_FDT_DOWN`, `SWITCH_TO_FDT_UP`) with no way to differentiate
between them or thread a runtime value through. 533c's FDT commands need
`FDT_MODE_ARMED + template`, `FDT_DOWN_ARMED + template`,
`FDT_UP_ARMED + template` — three *different* fixed prefixes, each
suffixed with the *same* 24-byte `template` value, which is obtained at
the start of every open/scan session by sending
`mcu_switch_to_fdt_mode(FDT_MODE_IDLE + 24 zero bytes)` and reading the
device's reply (`measure_baseline()` in `driver_53xc.py`) — genuinely
dynamic, not a constant (it reflects the sensor's live baseline
capacitance/environment at that moment; it is queried fresh, not cached
across power cycles).

This is not a one-field gap. Confirmed directly in `goodix.c`:
`goodix_send_mcu_switch_to_fdt_mode()`'s reply *is* delivered to whatever
callback is registered (`GoodixDefaultCallback` carries `data`/`length`) —
so the primitive isn't broken — but `goodix5xx.c`'s own SCAN/CALIBRATE
state machine wires every one of these calls to
`goodixtls5xx_check_none_cmd`, which discards the reply. Getting the
template through this base would mean: changing the `get_mcu_cfg`
call signature (breaking `goodix511` and every in-flight sibling PR that
shares this vtable), adding a new state to the shared SCAN SSM to perform
the baseline measurement, and adding instance storage to carry the result
— a fork of the shared base, not a patch to it.

Separately, `FpImageDevice` inheritance forecloses SIGFM as this base
currently stands: SIGFM-based matching needs `FpDeviceClass`-level control
over enroll/verify/identify (per AndyHazz's shape), not the automatic
image-capture-then-NBIS-minutiae pipeline `FpImageDeviceClass` drives.

## Hardware-verified protocol facts (transfer to any future attempt)

All confirmed against a real `27c6:533c` this session, via direct
iteration: build → run against hardware → read the exact failure → fix →
rebuild → retest. Six real bugs were found and fixed this way against the
AndyHazz-derived driver before the crypto-architecture mismatch was
discovered; the facts below outlived that driver.

- **USB interface: `0`** (not goodix53x5's `1`) — single-interface
  device, confirmed via `lsusb -v -d 27c6:533c`.
- **Endpoints: `0x01 OUT` / `0x83 IN`** (not goodix53x5's `0x03`/`0x01`) —
  confirmed via `lsusb -v -d 27c6:533c`.
- **`reset(reset_sensor=True, soft_reset_mcu=False, sleep_time=20)`**
  sends payload `[0x05, 0x14]` (byte0 = `reset_sensor | soft_reset_mcu<<1
  | reset_sensor<<2` = `0x05`, byte1 = sleep_time = `20`) and — critically
  — the device replies with an ACK **and then a separate data reply**
  (`message[0] != 0x01` ⇒ failure) that must be read before sending any
  further command, or every subsequent command's ACK/data matching
  desyncs by one frame. (`goodixtls`'s own `goodix_send_reset()` already
  does this correctly — it was only AndyHazz's board-specific
  reimplementation that got it wrong.)
- **`preset_psk_read(flags=0xbb020001, length=32, offset=0)`** sends a
  16-byte payload (`length‖offset‖flags‖0`, all u32 LE) on category
  0xE/command 0x2, and its reply is `[status(1)][flags(4 LE)]
  [psk_length(4 LE)][data]` — status `0x00` means success (opposite
  convention from RESET's `0x01`). This is *not* the same shape as
  goodix53x5's "production read" (bare 4-byte `read_type` selector) even
  though it's the same command byte.
- **Chip ID reads back as `0x00220ca1`** — matches `driver_53xc.py`'s
  documented value for this silicon (GF5288, same as the 53x5 family).
- **PSK is all-zero**, confirmed via the above, matching this whole
  device family's known convention. This driver must never write a PSK —
  `read_firmware` returns nothing in APP mode on 533c, so a failed write
  is unrecoverable.
- **Firmware version: `GF5288_GM168SEC_APP_13016`** on the unit tested
  this session; `driver_53xc.py` accepts the pattern
  `GF5288_GM168SEC_APP_1[0-9]{4}` (any build in the 1xxxx range), not an
  exact match.
- **`mcu_get_image` request is 4 bytes: `(flags, 0x06, gain, 0x00)`**, not
  the 1-byte payload both candidate bases assumed. `flags = 0x01` for a
  no-finger calibration/reference frame, `flags = 0x41` for a live
  finger-present frame (`0x01 | 0x40`). Gain `0xc2` was confirmed
  headroom-safe (0 clipped pixels) for both frame types on the hardware
  unit tested via a 7-point gain sweep earlier this project — likely
  unit-specific, no known auto-detection for this family yet.
- **TLS-PSK details**: suite 0x00AE
  (`TLS_PSK_WITH_AES_128_CBC_SHA256`), TLS 1.2, RFC 4279 premaster
  (`len‖zeros‖len‖PSK`), standard TLS 1.2 PRF for key expansion. Record
  decryption is AES-128-CBC with an explicit per-record IV, PKCS7-style
  padding stripped after decrypt (see `driver_53xc.py`'s
  `decrypt_record()`).
- **FDT template is per-session, not a constant**: obtained via
  `mcu_switch_to_fdt_mode(FDT_MODE_IDLE + 24×0x00, True)` at the start of
  each session, and appended (not replacing) a fixed 2-byte prefix for
  every subsequent FDT command (`FDT_MODE_ARMED = 0x8d 0x01`,
  `FDT_DOWN_ARMED = 0x0c 0x01`, `FDT_UP_ARMED = 0x0e 0x01`).
- **`DEVICE_CONFIG`** (the 256-byte sensor config blob) is captured from
  the real vendor driver and is *not* byte-identical to goodix53x5's
  default config (10 of 256 bytes differ, at offsets 183-184, 200,
  203-204, 211, 231-232, 239, 254-255) — use `driver_53xc.py`'s
  `DEVICE_CONFIG` verbatim, not goodix53x5's.
- **Sensor dimensions: 108×88**, confirmed multiple times independently
  this project (shape-corroborated PGM reshape, `driver_53xc.py`'s
  `SENSOR_WIDTH`/`SENSOR_HEIGHT`, and matching AndyHazz's board's own
  108×88 — same silicon).

## What a working driver actually needs

No single existing codebase provides all of this:

1. **Transport/crypto**: `goodixtls.c`'s embedded TLS-PSK server
   (`SSL_CTX` + PSK callback + socketpair thread) and `goodix.c`'s generic
   command-layer primitives (`goodix_send_protocol`, the ACK/data
   sub-state-machine) — both directly reusable, *not* `goodix5xx.c`.
2. **FDT/capture state machine**: new code, following the proven sequence
   in `driver_53xc.py`/`capture_golden_session.py` — baseline measurement
   once per session, three FDT commands each carrying the measured
   template plus a distinct fixed prefix, `mcu_get_image` with the 4-byte
   gain-aware payload above, calibration-frame-vs-live-frame flat-fielding
   (plain subtract, since both frames share one gain — no scale-fit
   needed, unlike goodix53x5's dual-gain approach).
3. **Matching**: `FpDeviceClass`-based (not `FpImageDevice`) enroll/
   verify/identify, following AndyHazz's `goodix53x5-enroll.c`/`-auth.c`/
   `-match.c` shape, with SIGFM (`sigfm/` — self-contained C++/OpenCV,
   directly portable) as the matcher. This is an explicit, load-bearing
   requirement, not a detail to defer: the user asked for SIGFM by name
   as the reliability mechanism, and every viable open-source driver for
   this sensor family (this project's own research, AndyHazz's driver)
   uses it instead of NBIS specifically because minutiae extraction is
   unreliable on a sensor this small.

In short: `goodixtls`'s transport + a new FDT/capture layer written
directly against `goodix.c`'s primitives (bypassing `goodix5xx.c`
entirely) + AndyHazz's `FpDeviceClass`/SIGFM shape ported onto that
transport. This is a genuine, multi-file driver-authoring task — not an
adaptation of either existing base — but every protocol-level fact it
needs is now established and listed above.

## Repository state

- `vendor/goodix53x5-libfprint` (fork of `AndyHazz/goodix53x5-libfprint`),
  branch `add-533c-support`: the AndyHazz-based attempt, kept as a record
  of the hardware-verified fixes (interface, endpoints, reset, PSK-read)
  and as a source to port the SIGFM/enroll/auth shape from. Not the
  driver going forward.
- `vendor/libfprint-goodixtls` (fork of `goodix-fp-linux-dev/libfprint`),
  branch `goodixtls`: has two small local patches on top of upstream —
  (1) `goodix_send_mcu_get_image_gain()`/`goodix_tls_read_image_gain()`
  added to `goodix.c`/`goodix.h` (additive, does not change existing
  drivers' behavior), gated by a new opt-in
  `use_gain_image_request`/`image_gain` pair on
  `FpiDeviceGoodixTls5xxClass`; (2) none yet applied for the FDT gap
  (would require the fork described above, not attempted this session).
  `goodixtls.c`/`goodix.c` are the parts worth keeping from this fork;
  `goodix5xx.c` is not the right base for 533c's capture path.

Both forks are pushed to GitHub under `daemonhorn/` with `upstream`
remotes pointing at their respective originals, for future PRs.
