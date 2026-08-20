#!/usr/bin/env python3
"""Library-based golden reference for sha256_stream_top.

Same computation as ref_stream.py, but delegates the SHA-256 compression to
the `cloudtools/sha256` PyPI package (`pip install sha256`). That package is
one of the few that exposes SHA-256 midstate, letting us drive raw
compression rounds without triggering the length-padding that hashlib always
tacks on at `.digest()`.

Trick: never call `.digest()` on the sha256 objects. Instead we keep one
`sha256()` instance per stream, call `.update(block)` once per 64-byte block
(each call = exactly one raw compression round because blocks are always 64
bytes), and read `.state` (which returns the current internal h[0..7] plus
byte counter) at the end. That's the pre-finalisation state, which is what
the RTL produces.

Output format is byte-identical to ref_stream.py so all three logs (RTL,
bespoke ref, lib-based ref) can be diffed pairwise.
"""
import struct
import sys

try:
    from sha256 import sha256 as SHA256Ctx
except ImportError:
    sys.stderr.write(
        "ERROR: this reference requires the `sha256` PyPI package "
        "(cloudtools/sha256).\n  pip install sha256\n"
    )
    sys.exit(2)

from ref_stream import (
    LOOP,
    NSTREAMS,
    BLOCKS_PER_STREAM,
    TOTAL_BLOCKS,
    MASK32,
    LFSR_SEEDS,
    lfsr_step,
    prng_block_bytes,
)


def state_bytes_to_hex(state_be_bytes):
    """Convert the library's big-endian h[0..7] pack to the RTL hex order.

    Library returns struct.pack('>8I', h0, h1, ..., h7). The RTL packs the
    256-bit state as {h,g,f,e,d,c,b,a} with `a` at bits[31:0], so the printed
    64 hex chars start at bit 255 (word h7) and end at bit 0 (word h0).
    """
    words = struct.unpack(">8I", state_be_bytes)  # h0..h7
    n = 0
    for i, w in enumerate(words):
        n |= (w & MASK32) << (i * 32)
    return f"{n:064x}"


def _selftest():
    """SHA-256('abc') via the library, exercising the same state-read path."""
    padded = b"abc" + b"\x80" + b"\x00" * 52 + b"\x00\x00\x00\x00\x00\x00\x00\x18"
    assert len(padded) == 64
    ctx = SHA256Ctx()
    ctx.update(padded)
    state_be, _counter = ctx.state
    got = state_be.hex()
    expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    assert got == expected, f"selftest FAIL: got {got}"


def main():
    _selftest()

    streams = [SHA256Ctx() for _ in range(NSTREAMS)]
    lfsr_lanes = list(LFSR_SEEDS)

    for t in range(TOTAL_BLOCKS):
        sid = t % NSTREAMS
        block = prng_block_bytes(lfsr_lanes)
        streams[sid].update(block)
        lfsr_lanes = [lfsr_step(l) for l in lfsr_lanes]

    stream_hex = []
    for i, ctx in enumerate(streams):
        state_be, _counter = ctx.state
        h = state_bytes_to_hex(state_be)
        stream_hex.append(h)
        print(f"STREAM {i:02d} = {h}")

    root = 0
    for h in stream_hex:
        root ^= int(h, 16)
    print(f"ROOT      = {root:064x}")


if __name__ == "__main__":
    main()
