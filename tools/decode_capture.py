#!/usr/bin/env python3
"""Decode the captured USB traffic using goodix.py's OWN framing functions
(not hand re-derived math) to avoid transcription errors. Reassembles
multi-packet bulk transfers by concatenating consecutive same-direction
payloads until a full message_pack frame validates.
"""
import sys

sys.path.insert(0, "/home/dhorn/goodix/goodix-533c-re/vendor/goodix-fp-dump")
import goodix

from parse_capture import parse

COMMAND_NAMES = {v: k for k, v in vars(goodix).items()
                  if k.startswith("COMMAND_") and isinstance(v, int)}


def try_decode_message(buf):
    """Try to decode buf as a full message_pack(message_protocol(...)).
    Returns (command_name, inner_payload_bytes, consumed_len) or None."""
    try:
        inner, flags, length = goodix.decode_message_pack(buf)
    except Exception:
        return None
    if flags not in (goodix.FLAGS_MESSAGE_PROTOCOL,
                      goodix.FLAGS_TRANSPORT_LAYER_SECURITY,
                      goodix.FLAGS_TRANSPORT_LAYER_SECURITY_DATA):
        return None
    consumed = 4 + length
    if flags == goodix.FLAGS_MESSAGE_PROTOCOL:
        try:
            payload, command, plen = goodix.decode_message_protocol(inner)
        except Exception:
            return "RAW_MSGPACK(flags=0x%02x)" % flags, inner, consumed
        name = COMMAND_NAMES.get(command, "0x%02x" % command)
        return name, payload, consumed
    else:
        return "TLS(flags=0x%02x)" % flags, inner, consumed


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "capture1.pcapng"
    packets = parse(path)
    bulk = [p for p in packets if p["xfer_type"] == "BULK" and p["devnum"] == 3
            and p["len_cap"] > 0]

    print(f"{len(bulk)} nonzero bulk packets\n")

    for i, p in enumerate(bulk):
        direction = "OUT" if not (p["ep"] & 0x80) else "IN"
        data = p["data"]
        result = try_decode_message(data)
        tag = ""
        if result:
            name, payload, consumed = result
            tag = f"  => {name}  payload({len(payload)})={payload.hex()}"
            if consumed < len(data) and any(data[consumed:]):
                tag += f"  [+{len(data)-consumed} trailing nonzero bytes]"
        print(f"#{i:3d} {direction:3s} status={p['status']:5d} "
              f"len_cap={p['len_cap']:5d}  raw[:24]={data[:24].hex()}{tag}")


if __name__ == "__main__":
    main()
