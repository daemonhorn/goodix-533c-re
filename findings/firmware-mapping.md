# Firmware-name string -> USB PID mapping (tod-goodix-53xc-0.0.4.so)

Target binary (all offsets below are **file offsets**, which are identical to
virtual addresses for this file — see rationale below):

```
/home/dhorn/goodix/extracted_driver/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/libfprint-tod-goodix-53xc-0.0.4.so
```

`readelf -S` shows `.rodata` has `Address == Offset == 0x00da000` and every
other loadable section likewise has file-offset == vaddr (p_vaddr == p_offset
for every PT_LOAD segment, checked via `readelf -l`), so no delta conversion
was needed between "offset printed by `strings -t x`" and "address printed in
`objdump -d` rip-relative comments".

## Firmware string -> PID mapping

**Leading answer: NOT FOUND. The PID-to-firmware hypothesis
(`GF5288_GM168SEC_APP_13016` == PID 0x533c) is REFUTED as stated** — there is
no static, PID-keyed table in this binary that binds any single
`GF*_APP_*` firmware-name string to PID 0x530c, 0x533c, or 0x538c
specifically. Confidence: **strong** (structural, not just absence-of-evidence).

Instead, the binary contains one confirmed **USB `id_table`** (PID/VID pairs,
no firmware association) shared by all three PIDs under a single
`FpDeviceClass`, plus a large, undifferentiated pool of ~19 `GF*_APP_*` /
`MILAN_*_IAP_*` firmware-name literals that are referenced from generic
string-building/logging code, not from any per-PID dispatch table. This
matches the open-source siblings' pattern of doing firmware identification
at **runtime** (read `firmware_version()` from the connected device, then
`re.fullmatch()` against a small regex of acceptable names) rather than
picking a firmware name ahead of time from the PID. Practical implication for
the interoperability tool: **query the live device's firmware string instead
of hard-coding one from PID 0x533c** — this blob does not appear to hard-code
that choice either.

### 1. Confirmed: USB `id_table` with all three PIDs, no firmware/driver_data payload

Command:
```
python3 - <<'EOF'
data = open(".../libfprint-tod-goodix-53xc-0.0.4.so","rb").read()
vid_le = (0x27c6).to_bytes(2,'little')   # bytes: c6 27
import re
for o in [m.start() for m in re.finditer(re.escape(vid_le), data)]:
    print(hex(o), data[o:o+16].hex())
EOF
```
Output included three struct-like hits at file offsets `0x10e884`,
`0x10e914`, `0x10e9a4` (VID field), each 0x90 = 144 bytes apart. Dumping the
full 144-byte entries (`od -An -tx1 -v -j <off> -N 144 <bin>`):

```
0x10e880:  8c 53 00 00 c6 27 00 00  00 00 ... (136 more zero bytes)
0x10e910:  3c 53 00 00 c6 27 00 00  00 00 ... (136 more zero bytes)
0x10e9a0:  0c 53 00 00 c6 27 00 00  00 00 ... (136 more zero bytes)
```

Interpreted as little-endian `uint32_t pid; uint32_t vid;` header of a larger
(144-byte) struct entry (typical of libfprint's `FpIdEntry`, whose
`driver_data` union is large enough to explain the padding), this decodes to:

| file offset | pid (LE u32) | vid (LE u32) | remaining 136 bytes |
|---|---|---|---|
| 0x10e880 | `0x0000538c` | `0x000027c6` | all zero |
| 0x10e910 | `0x0000533c` | `0x000027c6` | all zero |
| 0x10e9a0 | `0x0000530c` | `0x000027c6` | all zero |

This is **confirmed**: it is the complete set {0x530c, 0x533c, 0x538c}, all
under VID 0x27c6 (Goodix), listed in descending PID order, each entry
otherwise all-zero — i.e. there is **no per-PID field distinguishing 0x533c
from 0x530c/0x538c** in this table (no driver_data value, no firmware-name
pointer, no chip-id constant). Whatever differs between the three physical
devices is determined at runtime, not compiled in per-PID here.

### 2. Confirmed: this table is *the* `id_table` used by the device class (class_init)

Searching the full disassembly (`objdump -d --no-show-raw-insn -M intel`) for
any instruction whose rip-relative target resolves to `0x10e880` found
exactly one hit, inside the GObject `class_init` function:

```
   54840:	endbr64
   54844:	push   rbp
   ...
   54880:	lea    rdx,[rip+0xb99c9]   # 10e250   <- "goodix-tod"
   54887:	lea    rcx,[rip+0xb9cda]   # 10e568   <- "Goodix Fingerprint Sensor 53xc"
   5488e:	mov    QWORD PTR [rax+0x88],rdx
   54895:	lea    rdx,[rip+0xb9fe4]   # 10e880   <- the 3-entry PID/VID table above
   5489c:	lea    rsi,[rip+0xe1d]     # 556c0    (function pointer, probe/open/etc.)
   548a3:	mov    QWORD PTR [rax+0x90],rcx
   548aa:	movabs rcx,0x10000000c
   548b4:	mov    QWORD PTR [rax+0xa0],rdx        <- id_table field = 0x10e880
   ...
```

`strings -a -t x` confirms the two adjacent string constants used in the
same struct-fill sequence:
```
  10e250 goodix-tod
  10e568 Goodix Fingerprint Sensor 53xc
```
i.e. `[rax+0x88]="goodix-tod"` (driver id/short-name), `[rax+0x90]="Goodix
Fingerprint Sensor 53xc"` (full_name), `[rax+0xa0]=0x10e880` (id_table). This
is a single `FpDeviceClass` struct filled once, for the whole 53xc family —
there is only one code path/class for PIDs 0x530c, 0x533c and 0x538c, and it
carries only the generic 3-entry PID table above (§1), not three separate
per-PID classes or a per-PID firmware-name table.

### 3. Firmware-name strings found (all, with file offsets)

```
$ strings -a -t x libfprint-tod-goodix-53xc-0.0.4.so | grep -Ei 'GF[0-9]{3,4}.*APP|DN[0-9]|_IAP_'
  de781 GF3288_ST411SEC_APP_12116
  e0439  GF3208_ST411SEC_APP_12116
  e0491 @GF3288_ST411SEC_APP_12116
  e04ce GF3266_ST411SEC_APP_12116
  e05aa GF3658_ST411SEC_APP_12116
  f1f81 MILAN_GM168SEC_IAP_200031@
  f5315 MILAN_GM168SEC_IAP_20003
  f5fa1 MILAN_GM168SEC_IAP_100071@
  fa789 MILAN_GM168SEC_IAP_10007
  fb821 GF5288_HT_APP_20045
  fcbd8 GF3208_HT_APP_20045
  fcc14 GF3258_HT_APP_20045
  fcc44 GF3268_HT_APP_20045
  fcc67 @GF3288_HT_APP_20045
  fcc80 GF3266_HT_APP_20045
  fcc94 GF3206_HT_APP_20045
  fccb8 GF5288_HT_APP_20045
 107721 GF5288_GM168SEC_APP_13016
 1093f4 0AGF5288_GM168SEC_APP_13016
 145c8c GF3258 DN2
 14614c GF3658 DN3
```
(All offsets `0xde781`..`0x1093f4` fall inside `.rodata` [0xda000,0x11e220);
`0x145c8c`/`0x14614c` fall inside `.data` [0x145540,0x149600) — those two
short-form strings living in writable `.data` rather than `.rodata` is mildly
interesting but not further explored here.)

**No `lea`/rip-relative reference in the disassembly resolves to any of these
21 addresses**, i.e. none of them are loaded via a simple "load address of
string literal" instruction the way the id_table and the two class-name
strings above are. The only code that touches one of them at all is a
16-byte-at-a-time `movdqu`/`movaps` inlined-memcpy of the literal's *bytes*
into a stack buffer (compiler-generated inlined `strcpy`/`memcpy` of a
constant), e.g.:

```
   22d3f:	mov    rax,QWORD PTR [rip+0xbba4b]   # de791
   22d46:	movdqu xmm1,XMMWORD PTR [rip+0xbba33] # de781  <- "GF3288_ST411SEC_APP_12116"
   22d4e:	mov    rsi,r14
   22d51:	mov    rdi,rbx
   22d54:	mov    QWORD PTR [rbx+0x10],rax
   22d58:	movzx  eax,BYTE PTR [rip+0xbba3a]     # de799
   22d5f:	movaps XMMWORD PTR [rbx],xmm1
   22d62:	mov    BYTE PTR [rbx+0x18],al
```
and (same pattern, different string) at `0x28dca` for `GF5288_HT_APP_20045`
(`0xfb821`). Both sites sit inside a function (starts at `endbr64` @
`0x22c20`) that is otherwise dominated by `g_log`-style debug-print call
sequences (`__FILE__`/`__LINE__`/format-string arguments pushed before calls
to a logging thunk at `0xc940`), and by two-byte/four-byte magic-marker
compares (`cmp WORD PTR [rsp+0x150],0x5041` = "PA", `0x4149` = "AI",
`cmp DWORD PTR [rsp+0x150],0x54534554` = "TEST"). This reads as chip/firmware
**identification/validation** code that builds a name string from parsed
device data (likely OTP or a reported chip/firmware id) for logging or
comparison purposes — **not** a PID-indexed jump/dispatch table. No
switch/jump table structure keyed on a small integer was found anywhere near
these string-copy sites; selection appears to be driven by parsed
runtime chip-id bytes, not by a compile-time PID constant.

### 4. Direct literal-PID search ("530c"/"533c"/"538c" anywhere as text or bytes)

```
$ strings -a -t x libfprint-tod-goodix-53xc-0.0.4.so | grep -Ei '530c|533c|538c|53xc'
   1cc7 libfprint-tod-goodix-53xc-0.0.4.so
  530c4 UVWX
 10e568 Goodix Fingerprint Sensor 53xc
```
- `0x1cc7` and the generic `0x10e568 "Goodix Fingerprint Sensor 53xc"` are
  just the family label, not PID-specific.
- `530c4 UVWX` is a **false positive**: `530c4` here is the `strings -t x`
  *file-offset column*, not file content; the byte content at that offset is
  literally `UVWX`. Confirmed by checking the line — the pattern `530c`
  matched the offset digits, not the string text.
- No other `strings` hits for `530c`, `533c`, `538c`, or `53xc`
  (case-insensitive) anywhere in the binary.

Raw 2-byte pattern search (both byte orders) for `0x530c`/`0x533c`/`0x538c`
turned up dozens of hits scattered through `.text`/`.rodata`/`.data`
(expected — two arbitrary bytes recur constantly in machine code and data),
none of which cluster near any firmware-name string or form a recognizable
table besides the confirmed id_table in §1.

### 5. Honest summary / confidence levels

| Claim | Confidence | Evidence |
|---|---|---|
| id_table at file offset `0x10e880` contains exactly PIDs {0x538c, 0x533c, 0x530c}, VID 0x27c6, in that (descending) order, each a 144-byte all-zero-padded entry | **Confirmed** | §1, raw hex dump |
| That table is *the* `id_table` used by the (single, shared) `FpDeviceClass` for this .so | **Confirmed** | §2, disassembly of class_init, only xref to 0x10e880 in the whole binary |
| Any single `GF*_APP_*` string is bound to PID 0x533c specifically (or to 0x530c / 0x538c specifically) | **Not found / refuted as a static mapping** | §1 (id_table carries no firmware data), §3 (no code references any firmware string except via generic memcpy-of-literal inside what looks like logging/validation code, not a PID switch) |
| `GF5288_GM168SEC_APP_13016` is "the" 533c firmware (original hypothesis) | **Weak guess at best, not corroborated** | It's present in `.rodata` (offsets `0x107721`, `0x1093f4`) exactly like ~18 sibling firmware-name strings for *other* chips (GF3206/3208/3258/3266/3268/3288/3658, HT/ST411SEC/GM168SEC variants); nothing in the binary singles it out or associates it with PID 0x533c over any of the others |
| The three PIDs (530c/533c/538c) map 1:1 to three specific different physical sensor chips, each with its own firmware name, entirely determined by runtime probing rather than compiled-in PID logic | **Strong hypothesis** | Single shared class_init / id_table (§2) + large undifferentiated pool of firmware-name literals for many distinct chip families (§3) is exactly what you'd expect if this one `.so` supports several OEM chip variants that can ship under any of the three PIDs, and firmware match is done the same way the open-source sibling drivers do it: read `firmware_version()` from the live device, `re.fullmatch()` against known-good name(s) |

## Recommendation for the interoperability tool

Given the above, hard-coding `TARGET_FIRMWARE` from a static PID→name table
extracted from this binary is not supported by the evidence. The safer path,
consistent with `driver_53xd.py`/`driver_53x5.py`, is to read the firmware
version string back from the actual connected 0x533c device at runtime and
match/log it, rather than assume `GF5288_GM168SEC_APP_13016` (or any other
single string found here) is "the" 533c firmware ahead of time.

## Commands used (for reproducibility)

```
BIN=/home/dhorn/goodix/extracted_driver/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/libfprint-tod-goodix-53xc-0.0.4.so

readelf -h "$BIN"
readelf -S "$BIN"
readelf -l "$BIN"
readelf -r "$BIN"

strings -a -t x "$BIN" | grep -Ei 'GF[0-9]{3,4}.*APP|DN[0-9]|_IAP_'
strings -a -t x "$BIN" | grep -Ei '530c|533c|538c|53xc'

python3 -c "
data = open('$BIN','rb').read()
vid_le = (0x27c6).to_bytes(2,'little')
import re
for o in [m.start() for m in re.finditer(re.escape(vid_le), data)]:
    print(hex(o), data[o:o+16].hex())
"

od -An -tx1 -v -j 0x10e880 -N 144 "$BIN"
od -An -tx1 -v -j 0x10e910 -N 144 "$BIN"
od -An -tx1 -v -j 0x10e9a0 -N 144 "$BIN"

objdump -d --no-show-raw-insn -M intel "$BIN" > full_disasm.txt
grep -n "# 10e880\b" full_disasm.txt
grep -n "# de781\b\|# fb821\b\|# 107721\b" full_disasm.txt   # (and similarly for every other GF*/MILAN* address)
```
