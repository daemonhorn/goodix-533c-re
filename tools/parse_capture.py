#!/usr/bin/env python3
"""Pure-Python pcapng parser for the usbmon capture (no tshark/wireshark on
the host). Uses dpkt for pcapng framing, then manually parses the Linux USB
mmapped-mode capture header (DLT_USB_LINUX_MMAPPED = 220, 64-byte header)
to get to the raw URB payload bytes.

Header layout (linux usbmon mmapped format, all little-endian):
  8B  id
  1B  type ('S'=submit, 'C'=complete, 'E'=error)
  1B  xfer_type (0=isochronous, 1=interrupt, 2=control, 3=bulk)
  1B  epnum (bit 0x80 = IN direction)
  1B  devnum
  2B  busnum
  1B  flag_setup
  1B  flag_data
  8B  ts_sec
  4B  ts_usec
  4B  status
  4B  length (actual URB length)
  4B  len_cap (captured length, i.e. how many payload bytes follow)
  8B  setup/iso union (unused here, bulk transfer)
  4B  interval
  4B  start_frame
  4B  xfer_flags
  4B  ndesc
  -- total 64 bytes --
followed by len_cap bytes of actual data.
"""
import struct
import sys

import dpkt

HEADER_FMT = "<Q B B B B H B B q i i I I 8s i i I I"
HEADER_SIZE = struct.calcsize(HEADER_FMT)
assert HEADER_SIZE == 64, HEADER_SIZE

XFER_TYPES = {0: "ISO", 1: "INTR", 2: "CTRL", 3: "BULK"}


def parse(path):
    packets = []
    with open(path, "rb") as f:
        reader = dpkt.pcapng.Reader(f)
        for ts, buf in reader:
            if len(buf) < HEADER_SIZE:
                continue
            fields = struct.unpack(HEADER_FMT, buf[:HEADER_SIZE])
            (urb_id, urb_type, xfer_type, epnum, devnum, busnum,
             flag_setup, flag_data, ts_sec, ts_usec, status, length,
             len_cap, _setup, interval, start_frame, xfer_flags,
             ndesc) = fields
            data = buf[HEADER_SIZE:HEADER_SIZE + len_cap]
            packets.append({
                "id": urb_id,
                "type": chr(urb_type) if 32 <= urb_type < 127 else urb_type,
                "xfer_type": XFER_TYPES.get(xfer_type, xfer_type),
                "ep": epnum,
                "devnum": devnum,
                "busnum": busnum,
                "status": status,
                "length": length,
                "len_cap": len_cap,
                "data": data,
            })
    return packets


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "capture1.pcapng"
    packets = parse(path)
    print(f"Parsed {len(packets)} packets from {path}")

    bulk = [p for p in packets if p["xfer_type"] == "BULK" and p["devnum"] == 3]
    print(f"{len(bulk)} bulk packets involving devnum=2 (our device)")

    # Search for the predicted TLV tags from psk-algorithm-analysis.md
    tag_0002 = bytes.fromhex("020001bb")  # LE encoding of 0xbb010002
    tag_0003 = bytes.fromhex("030001bb")  # LE encoding of 0xbb010003

    print("\n--- Packets with nonzero bulk data, devnum=2 ---")
    for p in bulk:
        if p["len_cap"] == 0:
            continue
        direction = "IN" if p["ep"] & 0x80 else "OUT"
        ep_num = p["ep"] & 0x7F
        hexdata = p["data"].hex()
        flags = []
        if tag_0002 in p["data"]:
            flags.append("HAS_0xbb010002")
        if tag_0003 in p["data"]:
            flags.append("HAS_0xbb010003")
        if p["data"][:1] == b"\xe0":
            flags.append("STARTS_0xE0")
        if b"\xa0" in p["data"][:2]:
            flags.append("MSG_PACK_FLAGS_0xa0")
        flag_str = f"  [{', '.join(flags)}]" if flags else ""
        print(f"id={p['id']:6d} {p['type']} EP{ep_num}_{direction} "
              f"len_cap={p['len_cap']:4d} status={p['status']:4d}{flag_str}")
        if flags or p["len_cap"] < 200:
            print(f"    {hexdata}")


if __name__ == "__main__":
    main()
