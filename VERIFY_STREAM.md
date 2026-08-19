# Streaming-scheduler verification (temp)

Temporary hand-off note for verifying `sha256_stream_top` on the machine with
`iverilog` installed. Delete this file once verification passes and the diffs
have been captured in a commit message or PR description.

## What is being verified

The new 64-stream time-multiplexed chaining wrapper (see Peter's BOTEC and the
pipelining explainer under `../`). One `LOOP=1` pipelined SHA-256 core is
round-robined across 64 hash chains. Each chain absorbs 100 blocks of
PRNG-generated data (6400 blocks total), then produces one final digest per
stream. XOR of the 64 digests is the placeholder "root".

`sim/ref_stream.py` computes the exact same 6400-block sequence and chain
structure in Python. Passing = RTL digests match the Python reference bit for
bit.

## Files that were added or touched

- `rtl/sha256_transform.v` — additive: new output `tx_state_final`
  (combinational tap on `HASHERS[64/LOOP-1].state`). No behavioral change for
  existing `bench_top` / `tb_bench_top` (named-port instances leave the new
  port unconnected).
- `rtl/sha256_stream_top.v` — new. 64-stream scheduler, LFSR PRNG, state RAM,
  external chain-add, XOR-reduce root.
- `sim/ref_stream.py` — new. Golden reference. Includes a SHA-256("abc")
  self-test at startup.
- `sim/tb_stream_top.v` — new. Runs the DUT, prints per-stream digests + root
  in the same format as the Python reference.
- `sim/Makefile` — added `sim-stream` and `check-stream` targets.
- `README.md` — added a "Streaming sim" subsection.

## Prerequisites

- `iverilog` + `vvp` on `PATH` (already required for `make sim`).
- `python3` (stdlib only, no packages).

## Run

```sh
cd sim
make check-stream
```

Expected final line:

```
PASS: RTL matches Python reference (64 stream digests + root)
```

If it fails, the target prints the first 20 lines of `diff`.

## Regression check on the existing bench

The transform-file change should be inert for the old flow. Confirm:

```sh
cd sim
make sim                 # default LOOP=1 N_CORES=1
make sim LOOP=4 N_CORES=2
```

Both should still print `OVERALL: PASS` and a `THROUGHPUT` line matching the
expected `cycles/hash = LOOP`.

## If it fails

Likely suspects, in order of prior probability:

1. **Byte / word endianness in the PRNG mapping.** The RTL packs
   `prng_block = {lfsr[7], ..., lfsr[0]}`, so lane `N` occupies bits
   `[64N+63 : 64N]`, which is `W[2N]` in the low 32 bits and `W[2N+1]` in the
   high 32 bits, each `W` big-endian in message bytes. `ref_stream.py`
   `prng_block_bytes()` mirrors this — check there first.
2. **Pipeline latency ≠ 64.** The chaining relies on `LATENCY == NSTREAMS`. If
   somebody bumps `LOOP` for the streaming instance or adds an extra register
   somewhere, the write-back slot no longer aligns with the read slot and the
   chain corrupts. `sha256_stream_top` hard-codes `LOOP=1`; don't parameterise
   that without also revisiting the scheduler.
3. **X-propagation across reset.** `sha256_transform`'s internal digester
   registers have no reset; they hold X until enough clean posedges flush them.
   `pipe_valid = (cyc >= 64)` gates the chain-add, so 64 real cycles of input
   must precede the first captured output. If somebody shortens the reset or
   changes when `cyc` starts counting, the first stream can pick up an X.
4. **`tx_state_final` port unconnected.** If the transform-file edit was
   dropped in a rebase, the DUT will still elaborate but `tx_state_final`
   is undriven → chain sees `X + IV`. Grep for `tx_state_final` in
   `rtl/sha256_transform.v`; the `assign tx_state_final = HASHERS[...].state;`
   line should be present.

## Once it passes

- Capture the PASS line (and optionally the first few `STREAM XX = ...` lines)
  in the commit message or PR body.
- Delete this file.
