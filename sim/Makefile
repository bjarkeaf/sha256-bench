LOOP    ?= 1
N_CORES ?= 1

RTL = ../rtl/sha256_functions.v ../rtl/sha256_transform.v ../rtl/bench_top.v
TB  = tb_bench_top.v

STREAM_RTL = ../rtl/sha256_functions.v ../rtl/sha256_transform.v ../rtl/sha256_stream_top.v
STREAM_TB  = tb_stream_top.v

.PHONY: sim sim-stream check-stream clean

sim: $(TB) $(RTL)
	iverilog -g2001 -DLOOP=$(LOOP) -DN_CORES=$(N_CORES) -o bench.vvp $(TB) $(RTL)
	vvp bench.vvp

sim-stream: $(STREAM_TB) $(STREAM_RTL)
	iverilog -g2005 -o stream.vvp $(STREAM_TB) $(STREAM_RTL)
	vvp stream.vvp

# Run RTL sim and Python reference, diff their digest logs.
check-stream: sim-stream ref_stream.py
	@vvp stream.vvp > stream_rtl.log
	@python3 ref_stream.py > stream_ref.log
	@grep -E '^(STREAM|ROOT)' stream_rtl.log > stream_rtl.digests
	@grep -E '^(STREAM|ROOT)' stream_ref.log > stream_ref.digests
	@if diff -q stream_rtl.digests stream_ref.digests > /dev/null; then \
		echo "PASS: RTL matches Python reference (64 stream digests + root)"; \
	else \
		echo "FAIL: RTL vs reference mismatch"; \
		diff stream_rtl.digests stream_ref.digests | head -20; \
		exit 1; \
	fi

clean:
	rm -f bench.vvp bench.vcd stream.vvp stream_rtl.log stream_ref.log stream_rtl.digests stream_ref.digests
