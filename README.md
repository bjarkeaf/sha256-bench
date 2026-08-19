# sha256-bench

Parametric SHA-256 pipeline benchmark for Zynq-7020 (Pynq-Z2).

Sweeps two design knobs and reports LUT/FF area and Fmax after Vivado place-and-route:

| Knob | Values | Effect |
|---|---|---|
| `LOOP` | 1, 2, 4, 8, 16, 32 | Unroll factor. `LOOP=1` = fully pipelined (64 stages, 1 cycle/hash). `LOOP=2` = 32 stages, 2 cycles/hash. Etc. |
| `N_CORES` | 1, 2, 4, 8 | Independent SHA-256 pipelines in parallel. |

At `LOOP=1`, `N_CORES=1`: one 512-bit block enters the pipeline every clock cycle, producing one 256-bit hash 64 cycles later. Throughput = 512 × Fmax bits/s per core.

See `../README.md` (FPGA hashing project root) for the motivation: line-rate SHA-256 for AI compute verification at 400 Gbps.

## RTL source

Two files lifted verbatim from [Open-Source-FPGA-Bitcoin-Miner](https://github.com/progranism/Open-Source-FPGA-Bitcoin-Miner) (GPL-3.0):

- `rtl/sha256_functions.v` — combinational SHA-256 round primitives (e0, e1, ch, maj, s0, s1)
- `rtl/sha256_transform.v` — parametric SHA-256 compression core (`sha256_transform` + `sha256_digester`)

One new file:

- `rtl/bench_top.v` — instantiates `N_CORES` transforms, shared scheduling, per-core LFSR input, XOR-accumulator output

## Simulate

Requires [Icarus Verilog](https://github.com/steveicarus/iverilog) (`iverilog`, `vvp`).

```sh
cd sim

# Default: LOOP=1, N_CORES=1 — correctness check + throughput report
make sim

# Override parameters
make sim LOOP=4 N_CORES=2
```

The testbench prints:
- `PASS correctness` / `FAIL correctness` — checks SHA-256("abc") = `ba7816bf...`
- `THROUGHPUT` line with cycles/hash and aggregate bits/cycle
- `OVERALL: PASS` / `OVERALL: FAIL`

## Synthesise (single point)

Requires Vivado with the `xc7z020clg400-1` device (free WebPACK edition works).

```sh
cd sha256-bench   # repo root
vivado -mode batch -source synth/ooc.tcl -tclargs 1 1
python3 synth/report.py 1 1
```

Reports are written to `vivado_ooc_L1_N1/util.rpt` and `timing.rpt`. One CSV row is appended to `results.csv`.

To try a different clock period (e.g., 3 ns = 333 MHz):
```sh
vivado -mode batch -source synth/ooc.tcl -tclargs 1 1 3.0
```

## Full sweep

```sh
cd sha256-bench
bash bench/sweep.sh
```

Runs all 24 combinations (6 LOOP values × 4 N_CORES values) and builds `results.csv`. Large unroll factors with many cores (`LOOP=1, N_CORES=8`) may fail place-and-route on the 53.2k-LUT Z-7020 — these are logged as FAILED.

## Target

- Board: Pynq-Z2
- Part: `xc7z020clg400-1` (Zynq-7020, 53200 LUTs, 106400 FFs)
- Default clock target: 2.5 ns (400 MHz)

## Scope

This bench covers the SHA-256 compression function only. Not included (yet):
- SHA-256 message padding or multi-block chaining
- Packet-stream scheduler (time-multiplexed 128-stream design from the project notes)
- AXI-Stream wrapper for PS integration

## License

New files (bench_top.v, tb_bench_top.v, Makefile, ooc.tcl, ooc.xdc, report.py, sweep.sh): MIT.
Lifted files (sha256_functions.v, sha256_transform.v): GPL-3.0 per original source.
See LICENSE.
