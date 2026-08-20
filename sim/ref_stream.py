#!/usr/bin/env python3
"""Golden reference for sha256_stream_top.

Replicates in software:
  - The 8x64-bit Fibonacci LFSR PRNG (same taps, same seeds, single-bit advance)
  - Round-robin NSTREAMS-stream chaining of BLOCKS_PER_STREAM blocks per stream,
    where NSTREAMS = 64 / LOOP and LOOP is read from the LOOP env var (default 1)
  - Final XOR-reduce of all NSTREAMS stream digests

Output format matches sim/tb_stream_top.v so the two logs can be diffed:

    STREAM 00 = <64 hex chars>
    STREAM 01 = <64 hex chars>
    ...
    STREAM <NSTREAMS-1> = <64 hex chars>
    ROOT      = <64 hex chars>

Hex encoding matches the RTL packing of the 256-bit state {h,g,f,e,d,c,b,a}
where `a` is bits[31:0] and `h` is bits[255:224]; the printed 64 hex chars
correspond to bit 255 first, bit 0 last.
"""
import os
import struct
import sys

LOOP = int(os.environ.get("LOOP", "1"))
if LOOP not in (1, 2, 4, 8, 16, 32):
    sys.stderr.write(f"ERROR: LOOP={LOOP} not in {{1,2,4,8,16,32}}\n")
    sys.exit(2)

NSTREAMS = 64 // LOOP
BLOCKS_PER_STREAM = 100
TOTAL_BLOCKS = NSTREAMS * BLOCKS_PER_STREAM

K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

# SHA-256 initial hash values: standard order H0..H7 = [a, b, c, d, e, f, g, h].
IV = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
]

MASK32 = 0xFFFFFFFF
MASK64 = 0xFFFFFFFFFFFFFFFF


def rotr(x, n):
    return ((x >> n) | (x << (32 - n))) & MASK32


def sha256_compress(state, block_bytes):
    """One SHA-256 block compression. state: list of 8 uint32, block: 64 bytes."""
    w = list(struct.unpack(">16I", block_bytes))
    for i in range(16, 64):
        s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
        s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
        w.append((w[i-16] + s0 + w[i-7] + s1) & MASK32)

    a, b, c, d, e, f, g, h = state
    for i in range(64):
        S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
        ch = (e & f) ^ ((~e & MASK32) & g)
        t1 = (h + S1 + ch + K[i] + w[i]) & MASK32
        S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
        mj = (a & b) ^ (a & c) ^ (b & c)
        t2 = (S0 + mj) & MASK32
        h = g
        g = f
        f = e
        e = (d + t1) & MASK32
        d = c
        c = b
        b = a
        a = (t1 + t2) & MASK32

    return [(x + y) & MASK32 for x, y in zip(state, [a, b, c, d, e, f, g, h])]


def lfsr_step(x):
    """Fibonacci LFSR: shift-left 1, fb = x63 ^ x62 ^ x60 ^ x59 into bit 0."""
    fb = ((x >> 63) ^ (x >> 62) ^ (x >> 60) ^ (x >> 59)) & 1
    return ((x << 1) | fb) & MASK64


LFSR_SEEDS = [
    0x0123456789abcdef,
    0xfedcba9876543210,
    0xdeadbeefcafebabe,
    0xbadc0ffee0ddf00d,
    0x5a5a5a5aa5a5a5a5,
    0x1234567890abcdef,
    0xf00dfacef00dface,
    0x13579bdf2468ace0,
]


def prng_block_bytes(lfsr_lanes):
    """Map 8 x 64-bit LFSR lanes to a 64-byte SHA-256 message block.

    RTL prng_block = {lfsr[7], lfsr[6], ..., lfsr[0]}: lane N occupies
    prng_block[64*N+63 : 64*N]. That 64-bit chunk holds two SHA-256 words:
    W[2N] in the low 32 bits, W[2N+1] in the high 32 bits. Each W is
    big-endian in message bytes (W[k][31:24] is the earliest byte of W[k]).
    """
    out = bytearray(64)
    for lane_idx, lane in enumerate(lfsr_lanes):
        w_low  = lane & MASK32             # W[2*lane_idx]     -> msg bytes N*8+0..3
        w_high = (lane >> 32) & MASK32     # W[2*lane_idx + 1] -> msg bytes N*8+4..7
        base = lane_idx * 8
        out[base + 0] = (w_low  >> 24) & 0xFF
        out[base + 1] = (w_low  >> 16) & 0xFF
        out[base + 2] = (w_low  >>  8) & 0xFF
        out[base + 3] =  w_low         & 0xFF
        out[base + 4] = (w_high >> 24) & 0xFF
        out[base + 5] = (w_high >> 16) & 0xFF
        out[base + 6] = (w_high >>  8) & 0xFF
        out[base + 7] =  w_high        & 0xFF
    return bytes(out)


def state_to_hex(state):
    """Format state as 64 hex chars, matching RTL packing (bit 255 first, bit 0 last)."""
    n = 0
    for i, word in enumerate(state):
        n |= (word & MASK32) << (i * 32)
    return f"{n:064x}"


def _selftest():
    """SHA-256('abc') = ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 96177a9c b410ff61 f20015ad"""
    padded = b"abc" + b"\x80" + b"\x00" * 52 + b"\x00\x00\x00\x00\x00\x00\x00\x18"
    assert len(padded) == 64
    state = sha256_compress(list(IV), padded)
    got = "".join(f"{w:08x}" for w in state)
    expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    assert got == expected, f"selftest FAIL: got {got}"


def main():
    _selftest()

    stream_state = [list(IV) for _ in range(NSTREAMS)]
    lfsr_lanes = list(LFSR_SEEDS)

    for t in range(TOTAL_BLOCKS):
        sid = t % NSTREAMS
        block = prng_block_bytes(lfsr_lanes)
        stream_state[sid] = sha256_compress(stream_state[sid], block)
        # Advance LFSR after the current cycle's value has been consumed
        # (matches HW: combinational read at cyc T, register update at posedge -> cyc T+1).
        lfsr_lanes = [lfsr_step(l) for l in lfsr_lanes]

    for i, s in enumerate(stream_state):
        print(f"STREAM {i:02d} = {state_to_hex(s)}")

    root = 0
    for s in stream_state:
        n = 0
        for j, word in enumerate(s):
            n |= (word & MASK32) << (j * 32)
        root ^= n
    print(f"ROOT      = {root:064x}")


if __name__ == "__main__":
    main()
