# Getting started on Windows with the Pynq-Z2

This guide gets you from a bare Windows machine to running the SHA-256 benchmark sweep and reading results. No Linux knowledge required, though one optional step uses WSL.

---

## What you need

| Tool | Purpose | Free? |
|---|---|---|
| [Vivado ML Edition (WebPACK)](https://www.xilinx.com/support/download.html) | Synthesis, place-and-route, timing reports | Yes |
| [Python 3](https://www.python.org/downloads/) | Parsing reports into CSV | Yes |
| [Git for Windows](https://git-scm.com/download/win) | Clone the repo; provides Git Bash for running the sweep | Yes |
| [Icarus Verilog (Windows)](https://bleyer.org/icarus/) | Optional, simulation only | Yes |

You do **not** need a Pynq-Z2 connected to run the synthesis benchmark. Vivado runs entirely on your PC and reports how the design would perform on the board.

---

## Step 1: Install Vivado

1. Go to [xilinx.com/support/download.html](https://www.xilinx.com/support/download.html) and download **Vivado ML Edition**.
2. Run the installer. When asked which devices to support, make sure **Zynq-7000** is ticked (it is by default). Everything else can be unchecked to save disk space (~30 GB with Zynq only vs ~100 GB full install).
3. After install, open **Vivado** once from the Start menu to confirm it launches.

To use Vivado from the command line (needed for the batch synthesis scripts), add it to your PATH. In PowerShell:

```powershell
# Adjust year/version as installed, e.g. 2024.1
[System.Environment]::SetEnvironmentVariable(
    "Path",
    $env:Path + ";C:\Xilinx\Vivado\2024.1\bin",
    "User"
)
```

Then open a new terminal and check: `vivado -version`

---

## Step 2: Install Python 3

Download from [python.org](https://www.python.org/downloads/). During install, tick **"Add Python to PATH"**. Verify: `python --version`

No extra packages are needed. The report parser uses only the standard library.

---

## Step 3: Get the repo

Install [Git for Windows](https://git-scm.com/download/win), then in Git Bash (or any terminal):

```bash
git clone <repo-url> sha256-bench
cd sha256-bench
```

Or download a ZIP from GitHub and extract it.

---

## Step 4: Run a single synthesis point (quickest test)

Open **Git Bash** and run:

```bash
cd sha256-bench
vivado -mode batch -source synth/ooc.tcl -tclargs 1 1
```

This synthesises `LOOP=1, N_CORES=1` (fully pipelined, one core) for the `xc7z020clg400-1` part. It takes a few minutes. When done:

```bash
python synth/report.py 1 1
```

This creates `results.csv` with one row containing LUT count, FF count, worst negative slack, achieved Fmax, and estimated throughput in Gbps.

---

## Step 5: Run the full sweep

The sweep script is a bash script, so it needs Git Bash (or WSL, see the optional section below).

In **Git Bash**:

```bash
cd sha256-bench
bash bench/sweep.sh
```

This runs all 24 combinations (LOOP ∈ {1,2,4,8,16,32} × N\_CORES ∈ {1,2,4,8}). Each combination takes a few minutes; the full sweep takes 1–2 hours. Results append to `results.csv` as they complete.

Large, fully-unrolled configs (`LOOP=1, N_CORES=8`) may exceed the Z-7020's 53 200 LUTs and fail place-and-route. These are logged as FAILED in the CSV and can be ignored.

### Alternative: run individual points manually

If you don't want to use Git Bash, you can call Vivado directly from PowerShell or CMD for each combination:

```powershell
vivado -mode batch -source synth/ooc.tcl -tclargs 2 1
python synth/report.py 2 1

vivado -mode batch -source synth/ooc.tcl -tclargs 4 2
python synth/report.py 4 2
# ... and so on
```

---

## Step 6: Read results

Open `results.csv` in Excel or any spreadsheet. Columns:

| Column | Meaning |
|---|---|
| `loop` | Unroll factor (1 = deepest pipeline) |
| `n_cores` | Number of independent cores |
| `luts` | Slice LUTs used |
| `ffs` | Slice registers (flip-flops) used |
| `wns_ns` | Worst negative slack in ns (positive = met timing) |
| `achieved_fmax_mhz` | Clock frequency the design actually meets |
| `throughput_gbps` | `n_cores × 512 bits × Fmax / loop` |

Plot `throughput_gbps` vs `luts` to find the area-efficient sweet spot for the Pynq-Z2.

---

## Optional: simulation (correctness check)

Install [Icarus Verilog for Windows](https://bleyer.org/icarus/). The installer adds `iverilog` and `vvp` to your PATH.

In Git Bash:

```bash
cd sha256-bench/sim
make sim LOOP=1 N_CORES=1
```

Prints `PASS correctness` (checks SHA-256("abc") output) and a throughput report. Try other configs:

```bash
make sim LOOP=4 N_CORES=2
```

---

## Optional: WSL instead of Git Bash

If you already have WSL (Windows Subsystem for Linux) with Ubuntu, you can use it instead of Git Bash for both the sweep and simulation:

```bash
# Inside WSL
sudo apt install iverilog
cd /mnt/c/path/to/sha256-bench/sim
make sim
```

To run Vivado from WSL, point to the Windows Vivado binary:

```bash
/mnt/c/Xilinx/Vivado/2024.1/bin/vivado -mode batch -source synth/ooc.tcl -tclargs 1 1
```

---

## Troubleshooting

**`vivado: command not found`**: Vivado isn't on your PATH. Either add it (Step 1) or use the full path: `/c/Xilinx/Vivado/2024.1/bin/vivado` in Git Bash.

**`ERROR: [Place 30-640] ...` (place-and-route fails)**: the config doesn't fit on the Z-7020. Logged as FAILED in the CSV, nothing to fix.

**`WNS` is negative in results**: timing wasn't met at the target 2.5 ns (400 MHz). The `achieved_fmax_mhz` column accounts for this and gives you the real Fmax. Try a relaxed period: `vivado -mode batch -source synth/ooc.tcl -tclargs 1 1 3.0`

**Vivado takes very long**: normal. `LOOP=1` with many cores is the biggest design (~64×N_CORES pipeline stages). `LOOP=32` configs are small and fast.
