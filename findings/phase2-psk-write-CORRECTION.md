# Correction: the PSK write already succeeded in Phase 2

**This corrects `phase2-psk-write-attempts.md` and `psk-algorithm-analysis.md`'s
practical conclusion.** The deep "seal by sgx" / Geneva / Stm32 decompilation
work in `psk-algorithm-analysis.md` is still accurate as a description of code
that exists in the binary, but it turned out **not to be the path this PID
uses for normal operation** — see below.

## What actually happened

`write_psk_533c.py`'s Attempt 1 (wrapped convention, known-universal
`PSK_WHITE_BOX`, response `message[0] == 0x01`) was logged as a failure
because `preset_psk_write()`'s own code treats `message[0] == 0x00` as
success — a convention that holds for the 8 sibling models this function
was written against.

**Live VM capture (see `vm-capture-analysis.md`) of the real vendor driver
running against this exact device proves the write actually succeeded.**
The vendor driver's own session:

1. Never calls `COMMAND_PRESET_PSK_WRITE_R` (`0xe0`) at all — only reads.
2. Reads `preset_psk_read(0xbb020001, 32, 0)` and gets back
   `66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925` —
   **exactly** `driver_53xd.py`'s `PMK_HASH` constant (SHA-256 of the
   all-zero `PSK`).
3. Proceeds directly to a real TLS-PSK handshake and successful image
   capture, using that already-correct PSK state.

**Re-verified directly on the host after the VM was shut down and the
device returned** (not just inferred from the capture):

```
preset_psk_read(0xbb020001, 32, 0)
pmk_hash = 66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925
expected PMK_HASH             = 66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925
MATCH
```

**Conclusion: `message[0] == 0x01` is this chip's success code for
`COMMAND_PRESET_PSK_WRITE_R`** — the opposite of the `== 0x00` convention
`preset_psk_write()` assumes, which is why both of Phase 2's attempts were
misread as failures. The known-universal `PSK_WHITE_BOX` constant (shared
across all 8 sibling families) **does work on `27c6:533c`** — no
chip-specific key derivation was ever needed. The extensive "seal by sgx" /
Geneva-vs-Stm32 decompilation was investigating real code in the binary,
but not the path exercised for this PID's normal PSK bootstrap — most
likely that machinery serves firmware-update or a different chip variant
also bundled in this multi-family `.so` (consistent with Phase 1's finding
that the same blob bundles config data for `53x5`/`53xd` too).

## Practical takeaway for `driver_533c.py`

`preset_psk_write()` in the vendored `goodix.py` should be treated as
already having done its job for this device — no further PSK
provisioning work is needed. Any reimplementation should either fix the
success-code check for this PID specifically (`in (0x00, 0x01)`) or simply
skip the write step going forward, since the device's PSK state persists
across sessions (it's non-volatile) and is already correct.

## Lesson for the project record

Static analysis correctly identified real, load-bearing code in the
binary, but wasted significant effort because the actual live protocol
outcome (a response byte's meaning) was never checked against a second
data point before committing to the "structural precondition" theory. The
live capture that settled this took under 30 minutes end-to-end (VM boot,
package install, one `fprintd-enroll` attempt); the decompilation pass
that preceded it took considerably longer. Read the correct lesson,
though: the decompile work wasn't wasted motion at the time it was done —
it was the reasonable next step given what was known then (a specific,
non-generic rejection code plus corroborating "seal"/OTP-size evidence).
The miss was not re-deriving the response-code convention empirically
(e.g. by testing `write_psk_533c.py` a second time and checking whether
the resulting PMK hash changed) before investing further in static
analysis.
