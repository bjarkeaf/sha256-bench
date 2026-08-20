# Streaming-scheduler verification (temp)

Temporary hand-off note for verifying `sha256_stream_top` on the Vivado /
iverilog machine. Delete this file once all three checkpoints pass and the
results have been captured in the commit message or PR description.

## What is being verified

The time-multiplexed SHA-256 chaining wrapper (see Peter's BOTEC and the
pipelining explainer under `../`). One `LOOP`-way unrolled SHA-256 core is
round-robined across `NSTREAMS = 64/LOOP` hash chains. Each chain absorbs
100 blocks of PRNG-generated data (`NSTREAMS × 100` blocks total, 6400
cycles of runtime regardless of `LOOP`), then produces one final digest per
stream. XOR of the `NSTREAMS` digests is the placeholder "root".

`sim/ref_stream.py` (bespoke) and `sim/ref_stream_lib.py` (uses
`cloudtools/sha256`) each compute the exact same sequence in software.
Passing = RTL digests match either reference bit-for-bit for every legal
`LOOP ∈ {1, 2, 4, 8, 16, 32, 64}`.

**Clocking**: the streaming wrapper's chain-add path (state RAM mux → adder
→ SHA core `rx_state`) caps at ~75 MHz on this Zynq-7020 speedgrade. The
board wrappers therefore run on a 62.5 MHz `clk_div2` (BUFG /2 divider off
the 125 MHz onboard oscillator; see `rtl/clk_div2.v`). Throughput ≈
`512 × 62.5 / LOOP` Mbps at Fmax — LOOP=1 caps at ~32 Gbps single-core,
LOOP=64 stays at ~0.5 Gbps but exercises the same scheduler. If you need
the compression core's real 400 MHz throughput number, use `synth/ooc.tcl`
(bench_top OOC) — it measures the core in isolation, without the scheduler
overhead.

## Files that were added or touched

Sim side (Part A):
- `rtl/sha256_transform.v` — additive: output `tx_state_final` (combinational
  tap on `HASHERS[64/LOOP-1].state`). No behavioural change for existing
  `bench_top` / `tb_bench_top`.
- `rtl/sha256_stream_top.v` — parametric `#(parameter LOOP=1)`. NSTREAMS,
  state RAM depth, PRNG advance cadence, feedback/cnt drive, DRAIN_END all
  derive from `LOOP`. `PACKETS_PER_STREAM` renamed to `BLOCKS_PER_STREAM`.
- `sim/ref_stream.py` — takes `LOOP` from env; same rename.
- `sim/ref_stream_lib.py` — inherits via `ref_stream` imports.
- `sim/tb_stream_top.v` — accepts `-DLOOP=N`; sizes print loop by
  `NSTREAMS = 64/LOOP`.
- `sim/Makefile` — new `LOOP ?= 1` knob with divisor-of-64 guard, new
  `check-stream-sweep` target that runs the 6 legal LOOPs back-to-back.

HW side, single-vector smoke test (LED BIST, unchanged from earlier commit):
- `rtl/sha256_stream_bist_top.v`, `synth/bist.tcl`, `synth/bist.xdc`.

HW side, full sweep (Parts B and C):
- `rtl/clk_div2.v` — BUFG /2 divider used by both board wrappers to bring
  125 MHz down to 62.5 MHz for the design.
- `rtl/uart_tx.v` — standard 8N1 UART TX at 115200 baud from the 62.5 MHz
  divided clock.
- `rtl/sha256_stream_uart_top.v` — parametric `#(parameter LOOP=1)` wrapper
  that streams `NSTREAMS` STREAM lines + 1 ROOT line via the UART after
  `done` rises. Self-clearing reset, alive+done LEDs.
- `synth/uart.tcl` + `synth/uart.xdc` — per-LOOP full P&R + bitstream to
  `vivado_uart_L${LOOP}/`. PMOD JA1 (Y18) as UART TX pin.
- `bench/hw_sweep.py` — laptop-side sweep orchestrator. Builds missing
  bitstreams, parses `util.rpt`/`timing.rpt` for area+timing, programs each
  bit, reads UART, computes golden, diffs, appends one row to
  `results_hw_sweep.csv`.
- `bench/report_uart.py` — parsing helpers for `util.rpt`/`timing.rpt`.
- `bench/program.tcl` — Vivado batch script to flash a bitfile onto the
  first attached JTAG target.

## Prerequisites

- `iverilog` + `vvp` on `PATH` (for the sim-side checkpoint).
- Vivado on `PATH` (for the HW-side checkpoints). Free WebPACK edition works.
- `python3` (stdlib only for the bespoke reference).
- Optional: `pip install sha256` (for the `ref_stream_lib.py` cross-check).
- For the HW sweep: `pip install pyserial` and a USB-UART adapter connected
  to PMOD JA1 (Y18) → adapter RX (adapter GND → any GND on JA).

## Checkpoint 1: Sim across all 6 LOOPs

Must pass before spending any P&R time.

```sh
cd sim
make check-stream-sweep
```

Expected final line:

```
PASS check-stream-sweep: all 7 LOOP values match
```

If it fails, each per-LOOP failure prints the first 20 lines of `diff` for
that LOOP. Failure triage below.

Optional three-way cross-check (RTL vs. bespoke ref vs. library ref) at a
single LOOP:

```sh
pip install sha256   # once
make check-stream-all LOOP=1
```

## Checkpoint 2: LED BIST smoke test on real HW (LOOP=1)

Single-vector board bring-up: confirms the Pynq-Z2 boots, the pipeline
finishes, the root matches Python. Fastest way to catch pinout or clock
mistakes before running the full sweep.

```sh
cd sha256-bench
vivado -mode batch -source synth/bist.tcl
# Then program vivado_bist/sha256_stream_bist_top.bit via Vivado Hardware
# Manager (Auto Connect → Program Device).
```

LED interpretation (Pynq-Z2 LD0..LD3):

| LEDs after ~1 s                             | Meaning |
|---|---|
| LD3 blinking, LD1 on, LD0 on, LD2 off       | **PASS** — hardware root matches Python golden |
| LD3 blinking, LD1 on, LD0 off, LD2 on       | **FAIL** — root differs from golden |
| LD3 not blinking                            | No clock / bad configuration / wrong board |
| LD3 blinking, LD1 off after several seconds | Pipeline never asserted done — timing violation? re-read `timing.rpt` |

If the LFSR seeds ever change, rerun `python3 sim/ref_stream_lib.py`, take
the `ROOT = ...` line, and update the `GOLDEN_ROOT` `localparam` in
`rtl/sha256_stream_bist_top.v`.

## Checkpoint 3: Full HW sweep (overnight)

Runs the whole `LOOP` sweep on the actual FPGA and compares each result to
its Python golden. Also captures LUT/FF/BRAM/DSP area, WNS/TNS timing, and
projected throughput per LOOP into a CSV for post-hoc plotting.

Two readback modes — pick whichever applies:

### Option A: BSCAN (single USB cable, no extra hardware)

Reads digests back over the same JTAG connection used for programming, via
the `BSCANE2` USER1 scan chain. `bench/program_bscan.tcl` programs the board
and calls `scan_dr_hw_jtag` to shift out all digests in one pass.

```sh
cd sha256-bench
python3 bench/hw_sweep.py --bscan
```

If `scan_dr_hw_jtag` is not found (older Vivado), it will error immediately
with "invalid command name" — fall back to Option B.

### Option B: PMOD UART (requires a USB-UART adapter)

Wire PMOD JA1 (pin 1 of the top PMOD header, Y18) → adapter RX; a PMOD GND
→ adapter GND. The Pynq-Z2's onboard USB-UART is on the PS side and **is
not** what this uses.

```sh
cd sha256-bench
pip install pyserial              # once
python3 bench/hw_sweep.py --port /dev/ttyUSB1
```

First run builds all seven bitstreams (~1.5–3 h P&R total, one Vivado
invocation each). Subsequent runs reuse them (pass `--rebuild` to force
regeneration).

Expected end-of-run summary (also written to `results_hw_sweep.csv`):

```
LOOP  NSTR    LUT      FF  BRAM  DSP    Fmax    Gbps    REF   ROOT     STR    t(s)
   1    64   ...     ...    ...  ...    ...     ...    PASS  PASS   64/64   ~30
   ...
  64     1   ...     ...    ...  ...    ...     ...    PASS  PASS    1/1    ~15
```

Actual numbers land wherever P&R lands them; the point is that all seven
rows should be PASS. Fmax in this table is the clk_div2 Fmax from
`report_timing_summary` (16 ns target − WNS), and throughput is
`512 × Fmax / LOOP / 1000` Gbps. LOOP=1 was seen to have WNS ≈ −5.2 ns at
an 8 ns target on the earlier attempt; with the 16 ns target we expect
positive WNS everywhere.

For the compression core's real 400 MHz Fmax (independent of scheduler
overhead), use `synth/ooc.tcl` and `results.csv` — that flow already
measures it.

### CSV columns

`results_hw_sweep.csv` has one row per LOOP, with these fields (in order):

**Identity + totals**
- `loop`, `nstreams` — configuration.
- `lut`, `ff`, `bram_36k`, `dsp` — post-route totals from `util.rpt`.

**Per-functional-block breakdown** (from `synth/{uart,bscan}.tcl`'s extra
`report_utilization -cells [...]` calls; see the block comment there for
which filter defines each bucket)
- `lut_core`, `ff_core` — the SHA-256 compression pipeline
  (`sha256_transform`).
- `lut_readback`, `ff_readback` — the selected readback interface: UART logic
  for UART builds, or the selector/mux, 257-bit scan register, and BSCANE2
  primitive for BSCAN builds.
- `lut_state_ram`, `ff_state_ram` — cells whose name matches `*state_ram*`,
  i.e. the `NSTREAMS × 256`-bit per-stream H register bank.
- `lut_lfsr`, `ff_lfsr` — the 8×64-bit LFSR PRNG.
- `lut_divider`, `ff_divider` — the `clk_div2` toggle FF + BUFG.
- `lut_rest`, `ff_rest` — derived as `total − (core + readback + state_ram +
  lfsr + divider)`. Contains: scheduler counters (`cyc`, `cnt`, `sid`),
  chain-add adders, XOR-reduce for root, any uncategorized serializer/control
  logic, and the reset counter.

**Timing + throughput**
- `wns_ns`, `tns_ns`, `target_period_ns` — post-route timing on
  `clk_div2`. `target_period_ns = 16.0` (62.5 MHz).
- `fmax_mhz` = `1000 / (target_period_ns − wns_ns)`.
- `throughput_gbps` = `512 × fmax_mhz / loop / 1000`.

**Ref match**
- `ref_match` — PASS if RTL == Python golden (both stream digests and root).
- `root_match` — PASS if just the root matches. Useful for isolating "one
  stream drifted" vs. "everything drifted."
- `streams_matched` — `N/NSTREAMS`, count of stream lines that matched.

**Provenance**
- `git_sha`, `timestamp_utc`, `vivado_version`, `elapsed_s`.

### Sanity checks on the sweep output

Before reading area/throughput numbers, verify these hold. Each catches a
different failure mode:

| Check | What it catches |
|---|---|
| Every `ref_match` is PASS | Scheduler bug or timing violation at runtime |
| `lut_core + lut_readback + lut_state_ram + lut_lfsr + lut_divider + lut_rest == lut` (and same for `ff_`) | Vivado renamed a cell and the `-cells` filter missed it — one bucket got attributed to `rest` instead |
| `ff_lfsr` is ≈512 for every LOOP | LFSR is fixed-size regardless of LOOP; if it varies, the filter is picking up something else |
| `lut_state_ram` shrinks monotonically with LOOP (LOOP=1 largest, LOOP=64 smallest) | State RAM is `NSTREAMS × 256` bits — should scale directly with NSTREAMS |
| `lut_core` shrinks monotonically with LOOP | Compression core has `64/LOOP` stages |
| `lut_readback` is plausible for the selected interface, `lut_divider` tiny (~10) | A report filter accidentally captured unrelated logic |
| `dsp == 0` everywhere | SHA-256 shouldn't infer DSPs; nonzero means Vivado did something odd |
| WNS positive on every LOOP | Design meets timing on `clk_div2` at all LOOPs |

## If it fails

Likely suspects, in order of prior probability:

1. **PMOD wiring** (checkpoint 3 only). Confirm JA1 (Y18) is wired to the
   USB-UART's **RX** pin and PMOD GND → adapter GND. Adapter TX is unused.
   Baud is 115200 8N1. If nothing comes out, first verify LD1 is on (design
   completed) — if it is, wiring is the suspect; if not, the design didn't
   run.
2. **Wrong LOOP passed to Python vs. RTL.** All targets and scripts read
   `LOOP` from a single env / CLI arg, but if you invoke `ref_stream.py`
   manually make sure to `LOOP=X python3 ...`.
3. **Byte / word endianness in the PRNG mapping.** Lane `N` of the LFSR
   packs into `prng_block[64N+63:64N]` = `{W[2N+1], W[2N]}` with each `W`
   big-endian. `ref_stream.py`'s `prng_block_bytes()` mirrors it; check that
   first.
4. **Pipeline invariant.** The scheduler relies on `NSTREAMS × LOOP = 64 =
   LATENCY`. If somebody adds a register somewhere in `sha256_transform` or
   changes `LATENCY`, the write-back slot no longer aligns with the read
   slot and the chain corrupts.
5. **X-propagation across reset.** `sha256_transform`'s internal digester
   registers have no reset; they hold X until enough clean posedges flush
   them. `pipe_valid = (cyc >= 64)` gates the chain-add, so at least 64
   real cycles of input must precede the first captured output.
6. **`tx_state_final` port unconnected.** If the transform-file edit was
   dropped in a rebase, the DUT will still elaborate but `tx_state_final`
   is undriven → chain sees `X + IV`. Grep for `tx_state_final` in
   `rtl/sha256_transform.v`; the `assign tx_state_final = HASHERS[...].state;`
   line should be present.

## Regression check on the existing bench

The `sha256_transform` change should be inert for the old bench flow:

```sh
cd sim
make sim                 # default LOOP=1 N_CORES=1
make sim LOOP=4 N_CORES=2
```

Both should still print `OVERALL: PASS` and a `THROUGHPUT` line matching the
expected `cycles/hash = LOOP`.

## Once it passes

- Capture the sweep summary + one or two `STREAM XX = ...` lines and the
  final PASS count in the commit message or PR body.
- Optionally, upload `results_hw_sweep.csv` as an artefact.
- Delete this file.
