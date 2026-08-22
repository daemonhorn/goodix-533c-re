## DEVICE_CONFIG hunt

Target: `/home/dhorn/goodix/extracted_driver/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/libfprint-tod-goodix-53xc-0.0.4.so`
(x86-64 ELF shared object, stripped, PIE.)

### Result summary

**Confirmed**: the binary contains **eight** distinct, named, 256-byte
register-init blobs (`DEVICE_CONFIG`-class data), one per supported sensor
sub-model, each copied byte-for-byte from a `.rodata`/`.data` constant into a
freshly `malloc(0x100)`-ed buffer by a dedicated "build chip config" function,
then checksummed. All eight share the section-table/register-tuple shape of
`DEVICE_CONFIG`/`DEFAULT_CONFIG` in the sibling open-source drivers
(`driver_53xd.py`, `driver_53x5.py`). Two of the eight are **exact matches to
sibling drivers for chip families other than 53xc**:

- **T7 (`MilanFnHv`) is a 256/256 byte-for-byte match** to `driver_53x5.py`'s
  `DEFAULT_CONFIG`, checksum footer included.
- **T8 (`MilanHuHv`) is a 250/256 byte match** to `driver_53xd.py`'s
  `DEVICE_CONFIG` (differences are 4 calibration bytes plus the 2-byte
  checksum footer, which every one of the 8 blobs gets recomputed at runtime
  — see §6).

The checksum algorithm was disassembled and confirmed to exactly match
`driver_53x5.py`'s `fix_config_checksum` (seed `0xa5a5`, 16-bit running sum
over the buffer excluding the last word, negated mod `0x10000`, stored into
the last 2 bytes).

**Consequence for the 533c question**: since T7 and T8 are attributable to
the `53x5` and `53xd` chip families respectively (not the `530c`/`533c`/`538c`
group this `.so` targets), they are the two blobs I would now most confidently
**exclude**, not recommend, for a 533c device — see §9. This is a **correction**
from an earlier draft of this document that mistakenly recommended T8 as the
best guess before T7 had been diff'd against `DEFAULT_CONFIG` too.

**Not determined** from static analysis: which single one of the remaining 6
named sensor variants (MilanF, MilanFn, MilanG, MilanH, MilanL, ChicagoHS) is
used for USB PID `27c6:533c` specifically (vs `530c`/`538c`). No USB-PID
immediate compares (`0x530c`/`0x533c`/`0x538c`) were found anywhere in
`.text`; the udev rules file for this package
(`/home/dhorn/goodix/extracted_driver/lib/udev/rules.d/60-libfprint-2-tod1-goodix.rules`)
only maps PIDs `530c`/`533c`/`538c`/`5840` to the generic driver name "Goodix
Fingerprint Sensor" — no per-PID sensor-name hint — and no `.conf`/metadata
file shipping alongside the `.so` was found (`find
/home/dhorn/goodix/extracted_driver -type f` turns up only the udev rules
file, a copyright/changelog doc, and the `.so` itself). Variant selection is
almost certainly driven by an on-device chip-ID/OTP read (the
`CheckOtp`/`GetChipConfig`/`GetDacFromOtp` family) rather than by USB PID.
See "Open question".

---

### 1. Section layout (`readelf -S`)

```
$ readelf -S libfprint-tod-goodix-53xc-0.0.4.so
[12] .text        PROGBITS 000000000000aa60  0000aa60  size cf188
[14] .rodata      PROGBITS 00000000000da000  000da000  size 44220
[19] .data.rel.ro PROGBITS 00000000001438c0  001428c0  size 14f0
[20] .dynamic     DYNAMIC  0000000000144db0  00143db0  size 220
[21] .got         PROGBITS 0000000000144fd0  00143fd0  size 20
[22] .got.plt     PROGBITS 0000000000145000  00144000  size 528
[23] .data        PROGBITS 0000000000145540  00144540  size 40c0
[24] .bss         NOBITS   0000000000149600  00148600  size a5540
```
For VA < `0x1438c0` (`.text`/`.rodata`), file offset == VA directly. From
`.data.rel.ro` onward, file offset = VA − `0x1000`. Verified independently
below with `readelf -x`/`od` cross-checks.

### 2. Anchor strings (`strings -a -t x`)

```
 105b08 mcu has no config, download chip config...
 1065c4 download chip config...
 102510 FpMcuDownloadChipConfig
  dc680 FpDownloadChipConfigStub
  dc6a0 FpGetChipConfigStub
 1030c8 / 103228 / 103538 / 1038e8 / 103b48 / 103cf8 / 104b78 / 104cb8  GetChipConfig
 105897 ../algorithm/AlgoConfig.c
 1058d0 CreateAlgConfig
```

`objdump -d` xref for `0x102510` ("FpMcuDownloadChipConfig") shows it's used as
a log/assert tag inside the function at `.text` VA `0x2bbe0`. That function is
**not** where the config bytes live — it receives the config buffer pointer
and size as its own arguments and forwards them into a generic "send MCU
command" call (`0x15ed0`). The constant lives at the *caller*.

### 3. Finding the callers: 8 function-pointer tables in `.data`

```
$ readelf -r libfprint-tod-goodix-53xc-0.0.4.so | grep 2bbe0
0000001465d8   R_X86_64_RELATIVE   2bbe0
0000001467b8   R_X86_64_RELATIVE   2bbe0
... (8 total, at 0x1465d8, 0x1467b8, 0x146a98, 0x146d78, 0x147058, 0x147238, 0x147518, 0x1477d8)
```

8 `R_X86_64_RELATIVE` relocations point at `0x2bbe0` from 8 different `.data`
locations — entries in 8 parallel per-sensor-variant "driver ops" vtables
(long runs of function pointers into `.text`). The field immediately *before*
the `FpMcuDownloadChipConfig`-style pointer (offset −8) is a different
function per table: the per-variant "build/get chip config" implementation.

| label | funcptr-to-`0x2bbe0` table VA | build-config fn | config source VA | `mov $0x100,%edi` (malloc site) |
|---|---|---|---|---|
| T1 | `0x1465d8` | `0x32070` | `0x146380` | `0x320e1` |
| T2 | `0x1467b8` | `0x32520` | `0x103380` | `0x3260e` |
| T3 | `0x146a98` | `0x32f90` | `0x146880` | `0x33013` |
| T4 | `0x146d78` | `0x343c0` | `0x146b60` | `0x34592` |
| T5 | `0x147058` | `0x35530` | `0x146e40` | `0x355b3` |
| T6 | `0x147238` | `0x372a0` | `0x103ee0` | `0x3747d` |
| T7 | `0x147518` | `0x3c6a0` | `0x147320` | `0x3c73e` |
| T8 | `0x1477d8` | `0x3c9f0` | `0x1475e0` | `0x3cac1` |

A 9th `mov $0x100,%edi` at `0x63d85` was checked and ruled out — it's unrelated
image-processing code with no accompanying `movdqa`/malloc-then-copy pattern.

### 4. The config-build function pattern (example: T1, fn `0x32070`)

```
   320e1: mov    $0x100,%edi           ; malloc(256)
   320e6: call   b8f0 <malloc@plt>
   320eb: movdqa 0x11428d(%rip),%xmm0  # 146380   <- 16 bytes -> buf+0x00
   320fe: movups %xmm0,(%rax)
   32101: movdqa ...                   # 146390   <- 16 bytes -> buf+0x10
   ... (16 movdqa/movups pairs total, one per 16-byte chunk, offsets 0x00..0xf0) ...
   321be: movdqa 0x1142aa(%rip),%xmm7  # 146470   <- final 16 bytes -> buf+0xf0
   321c6: movups %xmm7,0xf0(%rax)
   321cd: call   2d0a0                 ; checksum function (see §6)
   321d7: mov    %ax,0xfe(%rbx)        ; checksum written into buf[0xfe:0x100]
   321fe: movl   $0x100,(%r12)         ; out-size = 256
```

16 × 16 = exactly **256 bytes**. This same instruction pattern (malloc(0x100) →
16×`movdqa`+`movups` → checksum call → `mov %ax,0xfe(reg)`) was located and
manually walked for **all 8** functions. For 7 of the 8 (T1, T3, T4, T5, T6,
T7, T8) the 16 `movups` destinations are a clean, contiguous `0x00, 0x10,
0x20, ..., 0xf0` — confirmed line-by-line, no surprises.

**T2 is the exception** and required correction: its 15th chunk load
(`movdqa … # 103460`) is followed by a `movabs $0x100005400,%rax` /
`mov %rax,0xe0(%rbx)` / `mov %rdx,0xe8(%rbx)` (writing an inline 8-byte
immediate + a zeroed register, not two more `.rodata` chunks) *before* the
loaded `xmm0` is finally stored at offset `0xf0`. So T2's real 256 bytes are:

- `buf[0x00:0xe0]` (224 B) ← file `0x103380:0x103460` (14 contiguous 16-byte chunks)
- `buf[0xe0:0xe8]` (8 B) ← the literal `movabs` immediate `0x100005400`, little-endian: `00 54 00 00 01 00 00 00`
- `buf[0xe8:0xf0]` (8 B) ← zero (from `xor %edx,%edx` earlier in the function)
- `buf[0xf0:0x100]` (16 B) ← file `0x103460:0x103470` (the 15th chunk, stored last)

A naive flat `data[0x103380:0x103480]` read (which is what an early pass of
this investigation did) is **wrong** for T2 — it's shifted at the tail and
happens to run into an adjacent `.rodata` path string
(`../sensor/MilanFSeries/MilanFn.c`, see §5) rather than real config bytes.
The corrected T2 hex below accounts for this.

### 5. Sensor-variant names (from the log/assert-tag file-path strings)

Each build-config function logs errors tagged with `__FILE__`-style strings
(`"../sensor/<Series>/<Name>.c"`) passed to a `c940`-style assert/log helper.
Resolving the `lea ...,%rdx  # <addr>` operands inside each function body
(not just near the malloc call — some appear only in error paths further
down) gives a clean per-table sensor name, which is a much better anchor than
guessing from byte content alone:

| label | config source VA | sensor source file | sensor name |
|---|---|---|---|
| T1 | `0x146380` | `../sensor/MilanFSeries/MilanF.c` | **MilanF** |
| T2 | `0x103380` | `../sensor/MilanFSeries/MilanFn.c` | **MilanFn** |
| T3 | `0x146880` | `../sensor/MilanFSeries/MilanG.c` | **MilanG** |
| T4 | `0x146b60` | `../sensor/MilanFSeries/MilanH.c` | **MilanH** |
| T5 | `0x146e40` | `../sensor/MilanFSeries/MilanL.c` | **MilanL** |
| T6 | `0x103ee0` | `../sensor/MilanFSeries/ChicagoHS.c` | **ChicagoHS** |
| T7 | `0x147320` | `../sensor/MilanHvSeries/MilanFnHv.c` | **MilanFnHv** |
| T8 | `0x1475e0` | `../sensor/MilanHvSeries/MilanHuHv.c` | **MilanHuHv** |

This matches the task's own anchor-string list almost exactly
(`CheckSensorOtpHuHv`, `CheckSensorOtpHV`, `CheckSensorOtpMilanH` — "MilanH"
and "HuHv" both appear here as real per-sensor source files). It also confirms
this single `.so` bundles **8** distinct sensor sub-models across 2 series
("MilanFSeries" ×6, "MilanHvSeries" ×2) — evidently more than the 3 USB PIDs
(530c/533c/538c) the task's udev grouping mentions, reinforcing that PID isn't
the selector (a 1:1 PID→variant mapping would only need 3 tables, not 8).

### 6. Checksum function — disassembled and confirmed (VA `0x2d0a0`)

```
   2d0a0: endbr64
   2d0a4: test   %si,%si
   2d0a7: je     2d0d0
   2d0a9: sub    $0x1,%esi
   2d0ac: mov    $0xffffa5a5,%eax      ; seed = 0xa5a5 (sign-extended 32-bit form)
   2d0b1: movzwl %si,%esi
   2d0b4: lea    0x2(%rdi,%rsi,2),%rdx ; end = buf + 2 + (len-1)*2  (i.e. stop 1 short before buffer end)
   2d0c0: add    (%rdi),%ax           ; ax += *(uint16_t*)ptr, ptr += 2, loop
   2d0c3: add    $0x2,%rdi
   2d0c7: cmp    %rdx,%rdi
   2d0ca: jne    2d0c0
   2d0cc: neg    %eax                 ; checksum = -sum  (== 0x10000 - sum, mod 0x10000)
   2d0ce: ret
```

This **exactly** reproduces `driver_53x5.py`'s `fix_config_checksum`:
```python
checksum = 0xA5A5
for short_idx in range(0, len(config) - 2, 2):
    short = int.from_bytes(config[short_idx:short_idx+2], "little")
    checksum += short
    checksum &= 0xFFFF
checksum = 0x10000 - checksum
```
(seed `0xa5a5`, sum all 16-bit LE words except the last one, negate mod
`0x10000`). Confirmed, not just structurally inferred — I disassembled the
function body rather than assuming. The 2-byte result is written to
`buf[0xfe:0x100]` (the last 2 bytes) at every one of the 8 call sites, e.g.
T1's `321d7: mov %ax,0xfe(%rbx)`.

### 7. The eight 256-byte DEVICE_CONFIG blobs (corrected, script-generated)

Generated by a Python script that slices the raw file bytes at the computed
offsets (with the T2 correction from §4 applied), asserts `len(blob) == 256`
for each, and emits fixed 64-hex-char lines — not hand-wrapped.

**T1 — MilanF — VA `0x146380`, file offset `0x145380`:**
```
00115465248924ad1cc91ce504e904ed13ba000100ca00070084007f8186007f
8c88007f978a007fb08c007f868e007f8c90007fa092007fb394007f8496007f
8898007fa09a007fb85600082858004800700000007200785674003412260000
12d000000020010204200010402200012024003200800001045c008000280200
002a0200008200801520018204200010402200012024001400800001045c0000
01280200002a020000820080152001080422001008800001005c008000280200
002a02000082008015200108045c008000500001055200080054001001280200
002a020000000000000000000000000000000000000000000000000000000000
```

**T2 — MilanFn — VA `0x103380`, file offset `0x103380`** (lives in `.rodata`;
bytes 0xe0-0xef reconstructed from the `movabs`/zeroed-register splice
described in §4, not a flat file read):
```
6011607124952cc114d510e500e514f9030402000008001111ba000180ca0007
008400c0b38600bbc48800baba8a00b2b28c00aaaa8e00c1c19000bbbb9200b1
b1940000a8960000b6980000bf9a0000ba50000105d000000070000000720078
56740034122600001220001040120003042a0102002200012024003200800001
005c008000560008205800010032002c028200800cba000180ca0007002a0182
03200010402200012024001400800005005c0000015600082058000300820080
152a0108005c0080006200090364001800220000202a0108005c008000520008
005400000100000000000000000000000000000000000000000000000000fdf0
```

**T3 — MilanG — VA `0x146880`, file offset `0x145880`:**
```
301160712c9d2cc91ce518fd00fd00fd03ba000080ca0006008400beb28600c5
b98800b5ad8a009d958c0000be8e0000c5900000b59200009d940000af960000
bf980000b69a0000a7d2000000d4000000d6000000d800000012000304d00000
00700000007200785674003412200010402a0102002200012024003200800001
045c000001560030485800020032000802660000027c000038820080152a0182
032200012024001400800001045c00000156000c245800050032000802660000
027c000038820080152a0108005c008000540000016200380464001000660000
027c0001382a0108005c0080005200080054000001660000027c00013800bad8
```

**T4 — MilanH — VA `0x146b60`, file offset `0x145b60`:**
```
581160712c9d2cc91ce518fd00fd00fd03ba000180ca0004008400c0b38600bb
c48800baba8a00b2b28c00aaaa8e00c1c19000bbbb9200b1b1940000a8960000
b6980000009a000000d2000000d4000000d6000000d800000050000105d00000
00700000007200785674003412200010402a0102042200012024003200800001
005c008000560024205800030032000c02660000027c000058820080152a0182
032200012024001400800001005c000001560004205800030032000c02660000
027c000058820080152a0108005c000001540000016200080464001000660000
027c0000582a0108005c0000015200080054000001660000027c00005800bcff
```

**T5 — MilanL — VA `0x146e40`, file offset `0x145e40`:**
```
18116c7d24a124c510d510e500e500e5000402000008001111ba000180ca0007
008400beb28600c5b98800b5ad8a009d958c0000be8e0000c5900000b5920000
9d940000af960000bf980000b69a0000a7d2000000d4000000d6000000d80000
0050000105d000000070000000720078567400341220001040120003042a0102
002200012024003200800001005c0080005600342c5800010032002c0282007f
0c2a0182032200012024001400800001005c0000015600082c58000300320008
04820080152a0108005c00800062000a04640018002a0108005c008000520008
0054000001000000000000000000000000000000000000000000000000000fe9
```

**T6 — ChicagoHS — VA `0x103ee0`, file offset `0x103ee0`** (also in `.rodata`):
```
701160712c9d2cc91ce518fd00fd00fd03ba000180ca000400840015b3860000
c4880000ba8a0000b28c0000aa8e0000c19000bbbb9200b1b1940000a8960000
b6980000009a000000d2000000d4000000d6000000d800000050000105d00000
00700000007200785674003412200010402a0102042200012024003200800001
005c008000560024205800030232000c02660003007c000058820080152a0182
032200012024001400800001005c000001560004205800030232000c02660003
007c000058820080152a0108005c008000540010016200040364001900660003
007c0001582a0108005c0000015200080054000001660003007c00015800bcff
```

**T7 — MilanFnHv — VA `0x147320`, file offset `0x146320`:**
```
40116c7d28a528cd1ce910f900f900f9000402000008001111ba000180ca0007
008400beb28600c5b98800b5ad8a009d958c0000be8e0000c5900000b5920000
9d940000af960000bf980000b69a0000a730006c1c50000105d0000000700000
007200785674003412260000122000104012000304020216212c020a032a0102
002200012024003200800005045c000001560028205800010032002402820080
0c2002880d2a0192072200012024001400800005045c00000156000820580003
00320008048200800c2002880d2a0118045c0080005400000162000903640018
008200800c2002880d2a0118045c00800052000800540000010000000000614f
```

**T8 — MilanHuHv — VA `0x1475e0`, file offset `0x1465e0`** (matches
`driver_53xd.py`'s `DEVICE_CONFIG` in 250/256 bytes — see §8):
```
701160712c9d2cc91ce518fd00fd00fd03ba000180ca0008008400bec38600b1
b68800baba8a00b3b38c00bcbc8e00b1b19000bbbb9200b1b194000000960000
00980000009a000000d2000000d4000000d6000000d800000050000105d00000
00700000007200785674003412200010402a0102042200012024003200800001
005c000101560024205800010232000402660000027c00005882007f082a0182
072200012024001400800001405c000001560006145800040232000c02660000
027c00005882007f082a0108005c000101540000016200080464001000660000
027c0000582a0108005c00fb005200080054000001660000027c0000582002fc
```

All 256-byte lengths verified by script assertion. T1 and T8 also
cross-checked against `readelf -x .data` (VA-addressed) and `od -j
<file-offset>` (file-offset addressed) — all three agree byte-for-byte:

```
$ od -An -tx1 -j 0x145380 -N 16 libfprint-tod-goodix-53xc-0.0.4.so
 00 11 54 65 24 89 24 ad 1c c9 1c e5 04 e9 04 ed
$ readelf -x .data ... | grep 146380
  0x00146380 00115465 248924ad 1cc91ce5 04e904ed ..Te$.$.........
```

### 8. Structural corroboration vs. the sibling open-source drivers

- All 8 tables share byte `[1] == 0x11` (a version/magic byte); byte `[0]`
  varies per variant (`00,60,30,58,18,70,40,70`).
- 5 of 8 (T1,T3,T4,T6,T8) share the exact 4-byte sub-header `1c c9 1c e5`.
  T2 and T5 share a related `.. d5 10 e5` pattern (T2: `14 d5 10 e5`, T5:
  `10 d5 10 e5`). T7 has its own `1c e9 10 f9` — which turns out to be because
  T7 isn't really a "53xc-family" register map at all, see below.
- All 8 contain a run of ascending 2-byte register-address-shaped values
  stepping by `+2` (`0x86,0x88,0x8a,...`) — an analog/DAC calibration block
  structurally identical to `driver_53x5.py`'s `DEFAULT_CONFIG` calibration
  table (`...b1b6 8800 baba 8a00 b3b3 8c00 bcbc 8e00...`).
- All 8 contain the identical 12-byte chunk `70 00 00 00 72 00 78 56 74 00 34
  12` (a `0x12345678`-style version marker), present byte-for-byte in
  `driver_53xd.py`'s `DEVICE_CONFIG` too.
- The checksum mechanism (§6) is a verified exact match to
  `driver_53x5.py`'s `fix_config_checksum`.
- **Direct byte comparison, T7 (MilanFnHv) vs. `driver_53x5.py`'s
  `DEFAULT_CONFIG`: 0 of 256 bytes differ.** Exact match, checksum footer
  (`61 4f`) included — meaning T7's checksum is *already* correct as stored,
  unlike every other table (whose stored footer is stale and gets
  recomputed at runtime, see §6). This is about as strong a positive ID as
  static analysis can produce: T7 is the `53x5` driver's chip config,
  verbatim.
- **Direct byte comparison, T8 (MilanHuHv) vs. `driver_53xd.py`'s
  `DEVICE_CONFIG`:**
  ```
  offset 0xaf: ref=e7 t8=00
  offset 0xb0: ref=00 t8=01
  offset 0xc7: ref=80 t8=7f
  offset 0xeb: ref=dc t8=fb
  offset 0xfe: ref=c5 t8=02   <- checksum byte, overwritten at runtime anyway
  offset 0xff: ref=1d t8=fc   <- checksum byte, overwritten at runtime anyway
  ```
  250/256 bytes identical; the 4 non-checksum differences are plausibly
  per-unit/per-revision calibration tweaks. None of this is attributable to
  chance in a 256-byte buffer.
- **Implication**: `driver_53x5.py` and `driver_53xd.py` are drivers for the
  `53x5`/`53xd` PID families, not `530c`/`533c`/`538c`. T7 and T8 matching
  them this closely means T7 and T8 are (with high confidence) the chip
  configs for whatever sensor(s) those *other* PID families use, which this
  "53xc" `.so` also happens to bundle support for (alongside the 6 remaining
  variants). That makes T7/T8 the two blobs to *rule out* for 533c, not the
  ones to try first — see §9.

### 9. Confidence

- **Confirmed**: all 8 blobs (T1–T8) are genuine `DEVICE_CONFIG`-class,
  256-byte, register-init/calibration structures consumed by the
  `FpMcuDownloadChipConfig` code path (`0x2bbe0`) via 8 named sensor-variant
  vtables (MilanF, MilanFn, MilanG, MilanH, MilanL, ChicagoHS, MilanFnHv,
  MilanHuHv). Confirmed by: the malloc(0x100)+16×16-byte-copy+checksum code
  pattern (walked instruction-by-instruction for all 8, with T2's non-trivial
  immediate-splice correctly reconstructed and verified); the disassembled and
  algorithm-matched checksum function; and byte-exact comparison against two
  known-good sibling configs (T7 = 256/256 identical to `driver_53x5.py`'s
  `DEFAULT_CONFIG`; T8 = 250/256 identical to `driver_53xd.py`'s
  `DEVICE_CONFIG`).
- **T7 and T8 are excluded as 533c candidates.** Because they exactly match
  the sibling `53x5` and `53xd` drivers' configs (families distinct from
  `530c`/`533c`/`538c`), the most defensible reading is that this `.so`
  bundles the same underlying sensor-config logic across a *wider* set of
  Goodix "Milan"/"Chicago" chip families than just the 3 PIDs in its own udev
  rules, and T7/T8 belong to the non-53xc members of that set. This is a
  correction versus an earlier pass over this data, which recommended T8
  before T7 had been checked against `DEFAULT_CONFIG` — once T7 turned up an
  exact match too, "resembles a known driver" flipped from being weak
  evidence *for* 533c to being fairly strong evidence *against* it for both
  T7 and T8.
- **Remaining candidates for 533c** (in rough order of "most 53xc-family-typical
  structure", though none is confirmed): **MilanF (T1), MilanFn (T2),
  MilanG (T3), MilanH (T4), MilanL (T5), ChicagoHS (T6)**. All six share the
  register-tuple/checksum structure with T7/T8 but do not exactly match any
  known open-source sibling config, which is consistent with (though not
  proof of) them belonging to chip families — like 530c/533c/538c — that
  don't have an existing open-source reference driver.
- **Not confirmed / open**: which one of those 6 is used for USB PID
  `27c6:533c` specifically (vs `530c`/`538c`, or vs some other PID entirely).
  No `0x530c`/`0x533c`/`0x538c` immediate compares exist anywhere in `.text`,
  so PID-based dispatch inside this `.so` can be ruled out with reasonable
  confidence. The udev rules file for this package only maps PIDs
  `530c`/`533c`/`538c`/`5840` to the generic driver name "Goodix Fingerprint
  Sensor" (see §"Open question") with no per-PID sensor hint, and no
  `.conf`/metadata file exists alongside the `.so` to consult instead.
  Variant selection is most likely driven by on-device chip-ID/OTP
  identification (`CheckOtp`/`GetChipConfig`/`GetDacFromOtp` family) — this
  would need either a live USB capture of `upload_config_mcu` traffic against
  a real 533c device, or further static tracing of the OTP-read dispatch
  logic, to resolve.

### 10. Commands used (for reproducibility)

```
readelf -S libfprint-tod-goodix-53xc-0.0.4.so
strings -a -t x libfprint-tod-goodix-53xc-0.0.4.so | grep -F "GetChipConfig"
objdump -d --no-show-raw-insn libfprint-tod-goodix-53xc-0.0.4.so > disasm.txt
grep -n "# 102510\|# dc680\|# dc6a0\|# 105b08\|# 1065c4\|# 1058d0" disasm.txt
readelf -r libfprint-tod-goodix-53xc-0.0.4.so | grep 2bbe0
python3 -c "data=open('...','rb').read(); ..."   # slice raw bytes at computed offsets
readelf -x .data libfprint-tod-goodix-53xc-0.0.4.so | grep 146380
od -An -tx1 -j 0x145380 -N 16 libfprint-tod-goodix-53xc-0.0.4.so
```
Regex-based Python parsing of the `objdump` text (matching `lea
0x...(%rip),%r__  # <addr>` lines within each function's address range) was
used to enumerate the sensor-name log strings in §5, and to independently
re-slice/re-verify all 8 blobs in §7 (including the T2 correction).

### Open question / next step

Checked and ruled out as a shortcut: the package's udev rules
(`/home/dhorn/goodix/extracted_driver/lib/udev/rules.d/60-libfprint-2-tod1-goodix.rules`)
map PIDs `530c`, `533c`, `538c`, and `5840` all to the same generic
`LIBFPRINT_DRIVER="Goodix Fingerprint Sensor"` string — no per-PID sensor
name. `find /home/dhorn/goodix/extracted_driver -type f` shows the package
ships only that rules file, a Debian changelog/copyright doc, and the `.so`
itself — no companion `.conf`/metadata file with a PID→sensor table.

To pin down the exact 530c-vs-533c-vs-538c → variant mapping among the 6
remaining candidates (MilanF, MilanFn, MilanG, MilanH, MilanL, ChicagoHS),
the next step would be either (a) trace backwards from the 8 vtable
addresses to whatever selects among them at runtime (likely an on-device
OTP/chip-ID read, not USB PID or a static table), or (b) — more reliably —
capture real USB traffic from an actual 533c device during enrollment and
match the `upload_config_mcu` payload bytes against T1–T8 above. No blob is
confirmed as the 533c one from static analysis alone; T7 and T8 are
confirmed to belong to *other* PID families and should be excluded first.
