LOOP    ?= 1
N_CORES ?= 1

RTL = ../rtl/sha256_functions.v ../rtl/sha256_transform.v ../rtl/bench_top.v
TB  = tb_bench_top.v

.PHONY: sim clean

sim: $(TB) $(RTL)
	iverilog -g2001 -DLOOP=$(LOOP) -DN_CORES=$(N_CORES) -o bench.vvp $(TB) $(RTL)
	vvp bench.vvp

clean:
	rm -f bench.vvp bench.vcd
