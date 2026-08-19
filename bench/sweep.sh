#!/usr/bin/env bash
# Sweep (LOOP, N_CORES) combinations, synthesise each OOC, append to results.csv.
#
# Usage:
#   cd sha256-bench
#   bash bench/sweep.sh [PERIOD_NS] [PART]
#
# Defaults: PERIOD_NS=2.5, PART=xc7z020clg400-1 (Pynq-Z2)
# vivado must be on PATH.

set -euo pipefail

PERIOD="${1:-2.5}"
PART="${2:-xc7z020clg400-1}"

LOOPS=(1 2 4 8 16 32)
CORES=(1 2 4 8)

for LOOP in "${LOOPS[@]}"; do
    for N in "${CORES[@]}"; do
        echo "=== LOOP=$LOOP N_CORES=$N ==="
        if vivado -mode batch \
                  -source synth/ooc.tcl \
                  -tclargs "$LOOP" "$N" "$PERIOD" "$PART" \
                  -journal "vivado_ooc_L${LOOP}_N${N}/vivado.jou" \
                  -log     "vivado_ooc_L${LOOP}_N${N}/vivado.log"; then
            python3 synth/report.py "$LOOP" "$N" "$PERIOD" "$PART"
        else
            echo "FAILED L=$LOOP N=$N" | tee -a results.csv
        fi
    done
done

echo ""
echo "Sweep done. Results in results.csv"
