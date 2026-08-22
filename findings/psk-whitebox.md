# PSK_WHITE_BOX hunt

Target file (file offset == virtual address for `.rodata`, confirmed via
`readelf -l`: the third `LOAD` segment has `Offset 0x00da000` ==
`VirtAddr 0x00da000`, so no load-bias adjustment is needed for any
address below):

```
/home/dhorn/goodix/extracted_driver/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/libfprint-tod-goodix-53xc-0.0.4.so
```

## Reference constant (what we're hunting for)

`PSK_WHITE_BOX` in every sibling open-source driver in
`/tmp/goodix-fp-dump` (`driver_51x0.py`, `driver_51x0_spi.py`,
`driver_51x7.py`, `driver_52xd.py`, `driver_53x5.py`, `driver_53xd.py`,
`driver_5503.py`, `driver_55x4.py` — eight different chip families) is
**byte-for-byte identical**:

```
ec35ae3abb45ed3f12c4751f1e5c2cc05b3c5452e9104d9f2a3118644f37a04b
6fd66b1d97cf80f1345f76c84f03ff30bb51bf308f2a9875c41e6592cd2a2f9e
60809b17b5316037b69bb2fa5d4c8ac31edb3394046ec06bbdacc57da6a756c5
```
(96 bytes, verified with `python3 -c "print(len(bytes.fromhex(...)))"` → 96)

This is important context this task's prompt didn't state: **the
constant is not actually per-model** across those eight sibling
drivers — it's one shared value across 51x0/51x7/52xd/53x5/53xd/5503/55x4.
That changes what "found the PSK_WHITE_BOX" should mean for a 9th
(53xc) family: either the value is shared unchanged again (checked —
it is not, see below), or it's shared in part (a common
header/IV/salt) with the rest per-generation.

## Commands run

```bash
SO=/home/dhorn/goodix/extracted_driver/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/libfprint-tod-goodix-53xc-0.0.4.so
readelf -S "$SO"                       # section table (offsets/sizes below)
readelf -l "$SO"                       # confirm file-offset == VA for .rodata
objdump -d --no-show-raw-insn -M intel "$SO" > full_disasm.txt   # 207135 lines
```
Plus several `python3` scripts (inline below) for: exact-substring
search, chunked/partial substring search, full-file sliding-window
mismatch scan, Shannon-entropy scan of `.rodata` / `.data.rel.ro` /
`.data`, and disassembly cross-reference extraction.

Section table (relevant sections):

```
[14] .rodata      PROGBITS  00000000000da000  000da000  size 0x044220
[19] .data.rel.ro PROGBITS  00000000001438c0  001428c0  size 0x0014f0
[23] .data        PROGBITS  0000000000145540  00144540  size 0x0040c0
```

## Step 1 — exact 96-byte match

```python
target = bytes.fromhex('ec35ae3a...756c5')  # the 96-byte sibling constant
data = open(SO,'rb').read()
data.find(target)   # -> -1
```
**Not found.** The 53xc blob does not contain the sibling constant
verbatim.

## Step 2 — chunked search / longest-common-prefix

Searching for 8-byte chunks of the target at stride 4 turned up hits
only at the very start of the target, all landing on the same file
region:

```
chunk at target-offset 0  found at file offset 0xf1bab
chunk at target-offset 4  found at file offset 0xf1baf
chunk at target-offset 8  found at file offset 0xf1bb3
```

Dumping 96 bytes starting at `0xf1bab` and diffing byte-by-byte
against the sibling constant:

```
candidate: ec35ae3abb45ed3f12c4751f1e5c2cc02fd3af40249d50d3e549674d4dc2989d
           96450df05d56eb6c157af776b4d337820c49acfd5e2702d38167e3d39cea160a
           547dd284ccbcf279e104989c3a9e9fec342fea692eb942d0f69e8ab6c00c2d26
target:    ec35ae3abb45ed3f12c4751f1e5c2cc05b3c5452e9104d9f2a3118644f37a04b
           6fd66b1d97cf80f1345f76c84f03ff30bb51bf308f2a9875c41e6592cd2a2f9e
           60809b17b5316037b69bb2fa5d4c8ac31edb3394046ec06bbdacc57da6a756c5

byte diffs: 80 of 96 (bytes 16..95 differ; bytes 0..15 are IDENTICAL)
```

The first **16 bytes are an exact match**: `ec35ae3abb45ed3f12c4751f1e5c2cc`.
Bytes 16‑95 (80 bytes) are completely different from the sibling
constant.

**Uniqueness check** — this 16-byte prefix occurs exactly once in the
entire 1,346,920-byte file:

```python
prefix = target[:16]
# data.find loop over whole file -> [0xf1bab]   (only one hit)
```

**Full-file sliding mismatch scan** (every byte offset 0..n-96, not
just aligned/chunked positions — 9.1s runtime, pure Python, no
numpy/capstone available on this box):

```python
for i in range(len(data)-96):
    matches = sum(1 for j in range(96) if data[i+j]==target[j])
    # keep any offset with >=12 matches
# result: exactly one offset clears even 12/96 matches:
#   0xf1bab -> 16/96 matches
# every other offset in the whole file has <12/96 (chance level for
# random data is ~0.375/96 expected matches)
```

So `0xf1bab` is not just the best match, it is the **only** location
in the file with any statistically meaningful overlap with the known
constant at all. A 16-byte exact coincidental match has probability
~2⁻¹²⁸ under a null hypothesis of random data — this is not chance.

**Interpretation:** the first 16 bytes of `PSK_WHITE_BOX` appear to be
a fixed value Goodix's SDK reuses across chip generations (shared
IV/salt/header — 96 = 6×16 is consistent with e.g. one AES block of
IV followed by 5 blocks of per-generation ciphertext), while the
remaining 80 bytes are generation-specific and differ for the 53xc
family.

## Step 3 — entropy scan (as instructed)

Sliding 96-byte window, stride 8, Shannon entropy, over `.rodata`,
`.data.rel.ro`, `.data` (37,590 windows total):

Top hits are dominated by algorithmic lookup tables (e.g. the highest,
entropy 6.585 at file offset `0xda5c0`, has the byte pattern
`00 07 0e 09 1c 1b 12 15 38 3f 36 31 24 23 2a 2d ...` — classic
arithmetic-progression structure of a compiled CRC/checksum table, not
a secret) and a duplicated-looking blob at `0xda7c8` / `0x147450`
(same table referenced/duplicated in two sections). These are false
positives for "crypto constant" — high entropy but clearly algorithmic
tables, not random secrets.

Our candidate at `0xf1bab` (closest scanned stride window `0xf1ba8`):

```
entropy = 6.172 bits/byte
rank    = 238 of 37,590 windows  (top 0.63%)
```

Reasonably high, consistent with — but not uniquely diagnostic of —
cryptographic material (the very top of the ranking is CRC tables, not
this candidate).

## Step 4 — code cross-reference attempt

Extracted every RIP-relative-addressed instruction's resolved target
address from the full disassembly (`grep`-style scan of `# <hex> <`
comments objdump emits for `lea`/`mov`/`movdqu`/etc.) and checked for
any instruction targeting `0xf1bab` ± 64 bytes:

```
0 hits
```

No direct `lea reg,[rip+disp]` (or similar) in the entire `.text`
section resolves to this exact address or its immediate neighborhood.
This does **not** disprove the candidate — Goodix's code could well
reach it through a computed/indexed address (base pointer + variable
offset via a register, which objdump cannot resolve statically) rather
than a fixed RIP-relative literal — but it means the cross-reference
step from the task instructions came up empty; this is not confirmed
by control-flow evidence.

For context, the debug string `"2.process encrypted psk"` (file offset
`0xdddd7`) is referenced from exactly one place, `.text` VA `0x24f06`,
inside a function that issues protocol command `0xbb010003` (seen as
`movabs rax,0x7f4bb010003` at VA `0x24f5b`) — this is the same command
ID the sibling drivers use for `preset_psk_write`. A near-identical
function at VA `0x139c6` issues `0xbb010002`/`0xbb010003` too. However,
both of these are `calloc(0x800)` + "set 8-byte header, call a
send/receive helper, get back an out-length/out-pointer" query-style
call sequences — not a `memcpy`-from-static-blob pattern — so they read
as **read/query** commands (e.g. reading back a PMK hash to verify),
not the **write** of the white-box blob itself. Grepping all 234
`memcpy@plt` call sites in the binary for one preceded by both a
`0x60` (96-decimal) size load and an rip-relative `.rodata` address
found **zero** matches — i.e., no visible "hardcoded 96-byte blob →
memcpy → send" pattern anywhere in `.text`. The actual write call-site
(if compiled the way I expected) was not located.

## Step 5 — related sanity checks

- Reversed / bit-complemented (`XOR 0xFF`) / `+1` rotated variants of
  the known constant: none found anywhere in the file (whole-constant
  search and 16-byte-prefix search both `-1`).
- `SHA256(candidate)` = `b6de3b96a9b54ae5a82f8735f4f8b3918b9a8f563f2b03d09de1d3bf67813c76`
  — searched for this 32-byte hash anywhere in the file: **not found**
  (expected — per the task background, `PMK_HASH` is derived at
  runtime / on-device, not compiled into the driver as a literal, so
  this was a bonus check, not a hunt requirement).

## Byte context around the candidate

```
000f1b80  1a 03 24 4b 08 04 24 3a 08 18 22 54 13 01 62 14   ..$K..$:.."T..b.
000f1b90  01 01 64 12 10 69 14 12 52 3a 08 18 01 1d 1a f6   ..d..i..R:......
000f1ba0  c2 01 1d 12 03 34 01 bb 60 18 62 ec 35 ae 3a bb   .....4..`.b.5.:.
000f1bb0  45 ed 3f 12 c4 75 1f 1e 5c 2c c0 2f d3 af 40 24   E.?..u..\,./..@$
000f1bc0  9d 50 d3 e5 49 67 4d 4d c2 98 9d 96 45 0d f0 5d   .P..IgMM....E..]
000f1bd0  56 eb 6c 15 7a f7 76 b4 d3 37 82 0c 49 ac fd 5e   V.l.z.v..7..I..^
000f1be0  27 02 d3 81 67 e3 d3 9c ea 16 0a 54 7d d2 84 cc   '...g......T}...
000f1bf0  bc f2 79 e1 04 98 9c 3a 9e 9f ec 34 2f ea 69 2e   ..y....:...4/.i.
000f1c00  b9 42 d0 f6 9e 8a b6 c0 0c 2d 26 02 68 32 08 10   .B.......-&.h2..
000f1c10  0a 01 02 03 04 05 06 07 08 b2 03 85 e9 e8 1e 21   ...............!
   ...    (more non-printable binary bytes)
000f1cf0  2e 2e 2f 6d 63 75 2f 47 65 6e 65 76 61 2f 55 70   ../mcu/Geneva/Up
000f1d00  64 61 74 65 46 69 72 6d 77 61 72 65 2e 63 00 00   dateFirmware.c..
000f1d10  63 68 65 63 6b 20 61 70 70 20 63 72 63 20 66 61   check app crc fa
000f1d20  69 6c 65 64 2c 20 64 6f 20 6e 6f 74 20 75 70 64   iled, do not upd
000f1d30  61 74 65 00 00 00 00 00 70 72 6f 64 75 63 74 69   ate.....producti
000f1d40  6f 6e 5f 67 65 74 5f 70 6d 6b 5f 68 6d 61 63 20   on_get_pmk_hmac 
000f1d50  66 69 6c 61 65 64 20 77 69 74 68 20 65 72 72 6f   filaed with erro
000f1d60  72 3a 25 78 00 00 00 00 53 65 63 48 6d 61 63 53   r:%x....SecHmacS
000f1d70  68 61 32 35 36 20 66 69 6c 61 65 64 20 77 69 74   ha256 filaed wit
000f1d80  68 20 65 72 72 6f 72 3a 25 78 00 00 00 00 00 00   h error:%x......
```

Note: the candidate is embedded in a run of otherwise-opaque binary
bytes (from before `0xf1b80` through `0xf1cee`) that sits immediately
before a cluster of debug strings about MCU firmware update and
PMK/HMAC ("production_get_pmk_hmac filaed with error:%x",
"SecHmacSha256 filaed with error:%x" — note the vendor's own typo
"filaed"). This is thematically consistent with the blob being
crypto-adjacent material bundled near firmware-update code, but that
is circumstantial — the preceding bytes (`1a 03 24 4b 08 04 24 3a ...`)
look plausibly like an unrelated TLV/binary-config fragment, not proven
to be structurally part of the same object as the 96-byte candidate.

## Findings summary

| Offset (file == VA) | Length | Confidence | Notes |
|---|---|---|---|
| `0xf1bab` | 96 bytes | **Strong hypothesis** for the full 96-byte `PSK_WHITE_BOX`; **confirmed** for the first 16 bytes as a deliberately-shared constant | Only location in the whole file with any significant byte-overlap against the known cross-model constant (16/96 exact, unique, everywhere else scores <12/96 by full sliding scan). No direct static code cross-reference located despite exhaustive RIP-relative-address and `memcpy`-pattern searches. |

Full candidate bytes (hex):
```
ec35ae3abb45ed3f12c4751f1e5c2cc02fd3af40249d50d3e549674d4dc2989d
96450df05d56eb6c157af776b4d337820c49acfd5e2702d38167e3d39cea160a
547dd284ccbcf279e104989c3a9e9fec342fea692eb942d0f69e8ab6c00c2d26
```

**Honest confidence assessment:**
- **Confirmed**: bytes 0‑15 (`ec35ae3abb45ed3f12c4751f1e5c2cc`) are a
  deliberate, unique, exact match to the first 16 bytes of the
  cross-model `PSK_WHITE_BOX` constant used by 8 sibling open-source
  Goodix drivers. This cannot be coincidence.
- **Strong hypothesis, not confirmed**: that the full 96 bytes at
  `0xf1bab` is the complete, correct `PSK_WHITE_BOX` for the 53xc
  family. Supporting: right length (96), right section (`.rodata`),
  unique 16-byte prefix match, reasonably high entropy (6.17
  bits/byte, top 0.63% of all 96-byte windows in the data sections),
  general location near PMK/firmware-crypto debug strings. Against /
  unresolved: no static code cross-reference was found actually
  loading this address in any GTLS/PSK-handling function; the
  immediately surrounding bytes look like they could belong to a
  larger, structurally distinct binary blob rather than a clean
  standalone 96-byte array, so the exact start/end boundary (is it
  really bytes `[0xf1bab, 0xf1bab+96)` and not, say, offset by a few
  bytes one way or the other?) is inferred from the reference length
  (96) rather than proven from a struct/array boundary in the binary.
- I did **not** find a second, independent, higher-confidence
  candidate anywhere else in `.rodata`, `.data.rel.ro`, or `.data` —
  the entropy scan's top hits are all explainable as CRC/lookup
  tables, and the full-file mismatch scan shows no other location
  scores above chance against the known constant.

## What I'd try next (not done here — outside "pure static analysis
from strings" scope, or needs tools not on this box)

- Disassemble the two `0xbb010002`/`0xbb010003` handler functions
  (`.text` VA `~0x24de8`–`~0x25100` and `~0x13930`–`~0x139e0`) more
  completely (I only pulled ~200 lines of context) to find the actual
  write path / how `cd700`'s callee resolves buffer contents — it's
  plausible the 96-byte payload is assembled from multiple smaller
  RIP-relative loads (e.g. several 16-byte `movdqu` loads from
  different addresses concatenated) rather than one contiguous `lea` +
  `memcpy`, which the searches here would not catch.
  - inline-`movdqu`-concatenation instead of `lea`+`memcpy` would
    let the 96 bytes be split across several string. This is a
    concrete follow-up but requires deeper manual disassembly than
    fits the entropy/xref sweep done here.
- A real hardware test (writing `0xf1bab`'s 96 bytes as
  `PSK_WHITE_BOX` to a 27c6:533c device via the in-progress Python
  capture tool and checking `read_psk_hash()`) is the only way to
  move this from "strong hypothesis" to "confirmed" — this is
  explicitly out of scope for this read-only static-analysis task.
