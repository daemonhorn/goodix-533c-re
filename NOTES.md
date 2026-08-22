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

Upstreamed as [goodix-fp-dump PR #76](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/pull/76),
referencing issue #31.

Not done, and out of scope for this project: a `libfprint` C driver (see
README "Scope"), `530c`/`538c` support (untested, no hardware), and a
`goodix-firmware` PR (that repo wants raw chip firmware dumps, which
were never available here — only the closed shared library was).

## Ethics/legal note

Only original analysis, derived protocol constants, and newly-written
open-source code are kept/published here. The proprietary `.deb`/`.so` are
never redistributed — this mirrors how `goodix-fp-dump` itself documents
protocol constants for other models without shipping the vendor binaries
they were derived from. This static analysis (strings/section inspection,
no decompilation yet) is for interoperability — reproducing observable
behavior of hardware the user owns, not copying vendor code.
