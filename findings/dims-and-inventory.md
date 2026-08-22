# Sensor dimensions + inventory

Target file (all offsets/VAs below are file offsets; confirmed via
`readelf -S` that `.text` (file off `0xaa60`) and `.rodata` (file off
`0xda000`) have identical file-offset == virtual-address, i.e. no load
bias to account for):

```
/home/dhorn/goodix/extracted_driver/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/libfprint-tod-goodix-53xc-0.0.4.so
```

## (A) SENSOR_WIDTH / SENSOR_HEIGHT — best effort, inconclusive

**Commands run:**
```
strings -a -t x "$BIN" | grep -i "width\|height\|WxH\|resolution"
objdump -d --no-show-raw-insn "$BIN" > full_disasm.txt   # 207135 lines
grep -n "<addr>" full_disasm.txt   # cross-refs for rip-relative lea
python3 <scan for 32-bit LE int pairs in [40,300]>
python3 <scan for VID 0x27c6 occurrences>
```

**Confirmed, but not the answer:**

- The only `width`/`height`-ish string in the entire binary is
  `FingerWidth` at file offset `0x10f7a3` (confirmed via
  `strings -a -t x`). Cross-referencing its only use (code at VA
  `0x6f0c5`, function starting ~`0x6f070`) shows it's an assert/log
  label used inside a generic bit-unpacking routine in
  `packages/core/src/img_quality.c` (string at `0x10f7b0`) that
  extracts two ~9-bit fields from a packed `esi` word via
  `and ebx,0x7fc000; sar ebx,0xe` and `shr ebp,0x17`. This is generic,
  shared image-quality code (present for every Goodix sensor this SDK
  supports) — it decodes a runtime value, it does not embed a
  compile-time width/height constant. **Not usable as SENSOR_WIDTH.**

- Located and disassembled two hardcoded-return `GetImageSampleSize()`
  implementations (function name confirmed via the string
  `"GetImageSampleSize"` at file offset `0x103570`, cross-referenced
  to its callers):
  - VA `0x334f0` (body at `0x334fe`): `mov DWORD PTR [rsi],0x39c4`
    → returns **14788** decimal. Source path embedded nearby:
    `../sensor/MilanFSeries/MilanG.c` (string at `0x103470`).
  - VA `0x36f70` (body at `0x36f7e`): `mov DWORD PTR [rsi],0x2944`
    → returns **10564** decimal. Source path: `../sensor/MilanFSeries/ChicagoHS.c`
    (string at `0x103ba0`).
  - Factored both: `14788 = 2² × 3697` (3697 is prime — does **not**
    factor into any plausible width×height pair). `10564 = 2² × 19 ×
    139` (only plausible factor pair in range is 76×139, which is not
    a credible sensor resolution either). These "sample sizes" almost
    certainly include header/OTP/metadata bytes beyond raw
    width×height pixels, or are for sensor variants unrelated to
    530c/533c/538c. **Not confidently usable as width×height.**

- Grep for all `mov DWORD PTR [rsi],0x<imm>` patterns (the calling
  convention used by the two functions above) turned up only these
  two non-trivial values in the whole `.text`; all other hits are
  `0x0`, `0x1`, `0x2`, `0x4000` (looks like a generic max-buffer-size
  constant, not image dims).

- Confirmed the on-disk USB id-table entries for all three PIDs this
  `.so` handles (found by scanning for the raw 32-bit VID `0x27c6`):
  - `538c` @ file offset `0x10e880`
  - `533c` @ file offset `0x10e910`
  - `530c` @ file offset `0x10e9a0`

  Each is a 144-byte (`0x90`) stride record of the form
  `{u32 pid; u32 vid; 0-padding...}` with **zero payload** beyond
  PID/VID — e.g. for 533c: bytes `3c 53 00 00 c6 27 00 00 00 00 ... 00`
  starting at `0x10e910`. This is the standard `FpIdEntry`-style
  match table libfprint TOD drivers use; it carries no per-PID
  sensor-dimension or config-index field. This means **all three PIDs
  (530c/533c/538c) are dispatched identically** by this table — if
  they differ in sensor resolution, that information is not encoded
  here; it is presumably resolved at runtime from the sensor's chip
  ID / OTP data (there are `MilanGetChipId`, `MilanFSerGetOtpDetails`,
  `CHICAGO_HS_ID` etc. symbols in the string table) rather than being
  a link-time constant tied to the USB PID.

- Weak/circumstantial lead, reported for completeness only: scanning
  `.rodata` for adjacent 32-bit LE integer pairs both in `[40,300]`
  turned up a 144-byte-stride struct-array starting at file offset
  `~0x10eb00` (right after a small float table `4.0,5.0,3.0,2.0` and
  the log string `"algoLog: Update %d, g_fpTemplateNum %d\n"` at
  `0x10ead0`) whose 5th/6th 32-bit fields repeat the pair
  **(88, 108)** four times (offsets `0x10eb98`, `0x10ebb8`, `0x10ec38`,
  `0x10ec78` for the two fields) and **(64, 176)** twice. `(108, 88)`
  numerically matches the sibling `driver_53x5.py`'s
  `SENSOR_WIDTH=108, SENSOR_HEIGHT=88` exactly — but the surrounding
  context (algo/enrollment log strings, floating-point thresholds, and
  no link to the PID table above) suggests this is more likely an
  algorithm/OTP calibration parameter table shared across many sensor
  models in this SDK, not a per-PID resolution table. **Given the
  coincidental exact match to the known 53x5 dims, flag as
  interesting but do not treat as confirmed for 533c** — could easily
  be leftover shared-SDK data for an unrelated sensor model bundled in
  the same `.so`.

**Verdict for (A): NOT FOUND with confidence.** No string or
disassembled constant was located that can be confidently attributed
as `SENSOR_WIDTH`/`SENSOR_HEIGHT` specifically for USB PID `0x533c`.
The strongest circumstantial lead is the repeated `(88, 108)` integer
pair in the struct table at file offset `~0x10eb00`, which numerically
equals the already-known 53x5 dims (108×88) — worth a follow-up dynamic
capture (USB traffic dump) to confirm rather than trusting statically.
Recommend cross-checking against USB packet captures of an actual
530c/533c/538c device (image payload size / any GTLS handshake fields)
rather than relying further on static analysis for this value.

## (B) Inventory dumps

All four raw dumps were written to
`/home/dhorn/goodix/goodix-533c-re/findings/`:

| file | command | lines |
|---|---|---|
| `all-strings.txt` | `strings -a "$BIN" \| sort -u` | 7484 |
| `dynamic-symbols.txt` | `nm -D "$BIN"` | 167 |
| `sections.txt` | `readelf -S "$BIN"` | 62 |
| `dynamic-deps.txt` | `readelf -d "$BIN"` | 33 |

(`nm -D` confirms the blob is stripped of the regular symtab but still
exposes 167 lines of dynamic symbol table entries — mostly imported
libc/glibc/mbedtls symbols plus a handful of exported
`fpi_tod_shared_driver_*` / `libfprint`-ABI entry points, useful for
later work without re-deriving.)

Full disassembly (`objdump -d --no-show-raw-insn`, 207135 lines) was
also generated during this task for cross-referencing but was kept in
the scratch directory (not one of the four requested dumps):
`/tmp/claude-1000/-home-dhorn-goodix/9245a513-3cfa-433a-bdb3-9f38e1f39185/scratchpad/full_disasm.txt`
