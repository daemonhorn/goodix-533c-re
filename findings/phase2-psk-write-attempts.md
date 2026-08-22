# Phase 2 — PSK write attempts against real 27c6:533c hardware

Three real write transactions were sent to the device (documented here in
full per the plan's transparency expectations). No further writes were
attempted after the third — see "Stopping point" below.

## Attempt 1 — wrapped convention, known-universal key

`driver_53xd.py`/`driver_52xd.py`'s calling convention:
`preset_psk_write(0xbb010003, PSK_WHITE_BOX, length=114, offset=0, pre_flags=56a5bb956b7c8d9e0000)`,
using the `PSK_WHITE_BOX` value confirmed byte-for-byte identical across 8
sibling chip families (imported directly from `vendor/goodix-fp-dump/driver_53xd.py`,
not retyped).

**Result: `Write result: False`**

## Attempt 2 — simple convention, same known-universal key

`driver_51x0.py`/`driver_5503.py`/`driver_55x4.py`'s calling convention:
`preset_psk_write(0xbb010003, PSK_WHITE_BOX)` — no length/offset/pre_flags
wrapper, a structurally different wire payload. Same key bytes as attempt 1.

**Result: `Write result: False`**

Two different framing conventions, both rejecting the same key, is
evidence against "wrong framing" and toward either "wrong key" or "the
write is rejected regardless of key/framing" (a precondition/state issue).

## Attempt 3 — instrumented replay of attempt 1, raw response captured

Bypassed `preset_psk_write()`'s True/False collapse to see the actual
device response (`write_psk_533c_diag.py`, same bytes/framing as attempt 1
— no new key, no new payload).

```
ACK payload: b'\xe0\x03'
Full response (2 bytes): 0100
Response byte 0 (result code): 0x01
Remaining response bytes: 00
```

**`message[0] == 0x01`.** `preset_psk_write()`'s own code treats
`message[0] == 0x00` as success — so `0x01` is a rejection, consistent
with attempts 1-2's `False`. Notably, `goodix.py` uses `message[0] == 0x01`
to mean **true/success** for several *other* commands (`reset()` and
others, lines 419/466/510/543/814/871) — a different result-code
convention per opcode. This makes `0x01` here read as a specific,
dedicated status/error code for `COMMAND_PRESET_PSK_WRITE_R`, not a vague
"something went wrong" catch-all (which would more plausibly look like the
`0x80`-style codes seen in the MOC-family error scheme). No table mapping
this code to a meaning was found in `goodix-fp-dump`'s code or docs.

## Corroborating context (from Phase 1 + Phase 2 read-only probe)

- The closed blob's `.rodata` contains PSK-lifecycle debug strings:
  `"1.seal psk by sgx"`, `"2.process encrypted psk"`, `"3.write psk to mcu"`,
  `"seal psk, ret 0x%x length before %d, length after:%d"`,
  `"../common/sgx/PskUnify.c"`, `GfSealData`/`GfSealData failed`/`GfUnsealData`.
  This is a **3-step provisioning sequence** (seal → process → write), not
  a single flat write — `preset_psk_write` alone may only be step 3 of a
  sequence this chip requires, while sibling chips apparently don't (or
  the community reverse-engineering for those chips never needed to
  discover steps 1-2 because a simpler path existed for them).
- `read_otp()` returned **32 bytes**; `driver_53xd.py`'s own comment
  documents a 64-byte OTP dump for that sibling chip. A differently-sized
  OTP layout is consistent with a genuinely different provisioning/security
  scheme on this chip generation, not just a different DEVICE_CONFIG value.

## Stopping point

Per plan + advisor review: **no further PSK writes attempted.** The
evidence (specific non-generic rejection code, "seal by sgx" sequence
strings, differently-sized OTP) favors a structural precondition over a
simple wrong-key problem — trying the Phase 1 `0xf1bab` static candidate
next would very likely fail the same way and burn another real write
attempt without new information. The next step is decompiling the
`PskUnify.c`-tagged function(s) (`"1.seal psk by sgx"`, `"3.write psk to
mcu"`) to understand the actual required sequence, which needs a
decompiler (Ghidra) — the plain-disassembly sweep in Phase 1 already hit
this same wall for the PSK-write code path.

**Explicitly out of bounds** (per advisor review, noted here for the
record): `mcu_erase_app`/firmware-update-based "unlock" attempts.
`driver_53xd.py`'s retry loop calls `erase_firmware()` and expects to
reflash from `firmware/53xd/<TARGET_FIRMWARE>.bin` — and
`goodix-firmware` has no `53xc` directory (confirmed in Phase 1). Erasing
this device's firmware with nothing to reflash is the one action in this
project that could brick the sensor. Do not attempt.
