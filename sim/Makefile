LOOP    ?= 1
N_CORES ?= 1

RTL = ../rtl/sha256_functions.v ../rtl/sha256_transform.v ../rtl/bench_top.v
TB  = tb_bench_top.v

STREAM_RTL = ../rtl/sha256_functions.v ../rtl/sha256_transform.v ../rtl/sha256_stream_top.v
STREAM_TB  = tb_stream_top.v

.PHONY: sim sim-stream check-stream check-stream-lib check-stream-all clean

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

# Same idea as check-stream, but against the library-based ref (needs `pip install sha256`).
check-stream-lib: sim-stream ref_stream_lib.py
	@vvp stream.vvp > stream_rtl.log
	@python3 ref_stream_lib.py > stream_lib.log
	@grep -E '^(STREAM|ROOT)' stream_rtl.log > stream_rtl.digests
	@grep -E '^(STREAM|ROOT)' stream_lib.log > stream_lib.digests
	@if diff -q stream_rtl.digests stream_lib.digests > /dev/null; then \
		echo "PASS: RTL matches library-based reference"; \
	else \
		echo "FAIL: RTL vs library-based reference mismatch"; \
		diff stream_rtl.digests stream_lib.digests | head -20; \
		exit 1; \
	fi

# Three-way agreement: RTL, bespoke ref, and library-based ref. Runs the RTL sim
# once and diffs its digest log against both references.
check-stream-all: sim-stream ref_stream.py ref_stream_lib.py
	@vvp stream.vvp > stream_rtl.log
	@python3 ref_stream.py > stream_ref.log
	@python3 ref_stream_lib.py > stream_lib.log
	@grep -E '^(STREAM|ROOT)' stream_rtl.log > stream_rtl.digests
	@grep -E '^(STREAM|ROOT)' stream_ref.log > stream_ref.digests
	@grep -E '^(STREAM|ROOT)' stream_lib.log > stream_lib.digests
	@ok=1; \
	if diff -q stream_rtl.digests stream_ref.digests > /dev/null; then \
		echo "PASS: RTL == bespoke ref"; \
	else \
		echo "FAIL: RTL vs bespoke ref"; diff stream_rtl.digests stream_ref.digests | head -10; ok=0; \
	fi; \
	if diff -q stream_rtl.digests stream_lib.digests > /dev/null; then \
		echo "PASS: RTL == library ref"; \
	else \
		echo "FAIL: RTL vs library ref"; diff stream_rtl.digests stream_lib.digests | head -10; ok=0; \
	fi; \
	if diff -q stream_ref.digests stream_lib.digests > /dev/null; then \
		echo "PASS: bespoke ref == library ref"; \
	else \
		echo "FAIL: bespoke ref vs library ref"; diff stream_ref.digests stream_lib.digests | head -10; ok=0; \
	fi; \
	if [ $$ok -eq 0 ]; then exit 1; fi

clean:
	rm -f bench.vvp bench.vcd stream.vvp \
	      stream_rtl.log stream_ref.log stream_lib.log \
	      stream_rtl.digests stream_ref.digests stream_lib.digests
