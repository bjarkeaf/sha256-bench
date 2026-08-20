LOOP    ?= 1
N_CORES ?= 1

# Guard: LOOP must be a divisor of 64 for the streaming scheduler to make sense
# (NSTREAMS = 64/LOOP must be a positive integer, and the pipeline invariant
# NSTREAMS*LOOP = 64 assumes both are powers of 2).
_VALID_LOOP := $(filter 1 2 4 8 16 32,$(LOOP))
ifneq ($(LOOP),$(_VALID_LOOP))
$(error LOOP=$(LOOP) not in {1,2,4,8,16,32})
endif

RTL = ../rtl/sha256_functions.v ../rtl/sha256_transform.v ../rtl/bench_top.v
TB  = tb_bench_top.v

STREAM_RTL = ../rtl/sha256_functions.v ../rtl/sha256_transform.v ../rtl/sha256_stream_top.v
STREAM_TB  = tb_stream_top.v

.PHONY: sim sim-stream check-stream check-stream-lib check-stream-all check-stream-sweep clean

sim: $(TB) $(RTL)
	iverilog -g2001 -DLOOP=$(LOOP) -DN_CORES=$(N_CORES) -o bench.vvp $(TB) $(RTL)
	vvp bench.vvp

sim-stream: $(STREAM_TB) $(STREAM_RTL)
	iverilog -g2005 -DLOOP=$(LOOP) -o stream.vvp $(STREAM_TB) $(STREAM_RTL)
	vvp stream.vvp

# Run RTL sim and Python reference, diff their digest logs.
check-stream: sim-stream ref_stream.py
	@vvp stream.vvp > stream_rtl.log
	@LOOP=$(LOOP) python3 ref_stream.py > stream_ref.log
	@grep -E '^(STREAM|ROOT)' stream_rtl.log > stream_rtl.digests
	@grep -E '^(STREAM|ROOT)' stream_ref.log > stream_ref.digests
	@if diff -q stream_rtl.digests stream_ref.digests > /dev/null; then \
		echo "PASS LOOP=$(LOOP): RTL matches Python reference"; \
	else \
		echo "FAIL LOOP=$(LOOP): RTL vs reference mismatch"; \
		diff stream_rtl.digests stream_ref.digests | head -20; \
		exit 1; \
	fi

# Same idea as check-stream, but against the library-based ref (needs `pip install sha256`).
check-stream-lib: sim-stream ref_stream_lib.py
	@vvp stream.vvp > stream_rtl.log
	@LOOP=$(LOOP) python3 ref_stream_lib.py > stream_lib.log
	@grep -E '^(STREAM|ROOT)' stream_rtl.log > stream_rtl.digests
	@grep -E '^(STREAM|ROOT)' stream_lib.log > stream_lib.digests
	@if diff -q stream_rtl.digests stream_lib.digests > /dev/null; then \
		echo "PASS LOOP=$(LOOP): RTL matches library-based reference"; \
	else \
		echo "FAIL LOOP=$(LOOP): RTL vs library-based reference mismatch"; \
		diff stream_rtl.digests stream_lib.digests | head -20; \
		exit 1; \
	fi

# Three-way agreement: RTL, bespoke ref, and library-based ref. Runs the RTL sim
# once and diffs its digest log against both references.
check-stream-all: sim-stream ref_stream.py ref_stream_lib.py
	@vvp stream.vvp > stream_rtl.log
	@LOOP=$(LOOP) python3 ref_stream.py > stream_ref.log
	@LOOP=$(LOOP) python3 ref_stream_lib.py > stream_lib.log
	@grep -E '^(STREAM|ROOT)' stream_rtl.log > stream_rtl.digests
	@grep -E '^(STREAM|ROOT)' stream_ref.log > stream_ref.digests
	@grep -E '^(STREAM|ROOT)' stream_lib.log > stream_lib.digests
	@ok=1; \
	if diff -q stream_rtl.digests stream_ref.digests > /dev/null; then \
		echo "PASS LOOP=$(LOOP): RTL == bespoke ref"; \
	else \
		echo "FAIL LOOP=$(LOOP): RTL vs bespoke ref"; diff stream_rtl.digests stream_ref.digests | head -10; ok=0; \
	fi; \
	if diff -q stream_rtl.digests stream_lib.digests > /dev/null; then \
		echo "PASS LOOP=$(LOOP): RTL == library ref"; \
	else \
		echo "FAIL LOOP=$(LOOP): RTL vs library ref"; diff stream_rtl.digests stream_lib.digests | head -10; ok=0; \
	fi; \
	if diff -q stream_ref.digests stream_lib.digests > /dev/null; then \
		echo "PASS LOOP=$(LOOP): bespoke ref == library ref"; \
	else \
		echo "FAIL LOOP=$(LOOP): bespoke ref vs library ref"; diff stream_ref.digests stream_lib.digests | head -10; ok=0; \
	fi; \
	if [ $$ok -eq 0 ]; then exit 1; fi

# Sweep across all legal LOOP values, running check-stream once each.
# Note: runs recursively so each iteration picks up its own LOOP=X.
check-stream-sweep:
	@ok=1; \
	for L in 1 2 4 8 16 32; do \
		echo "--- LOOP=$$L ---"; \
		$(MAKE) --no-print-directory check-stream LOOP=$$L || ok=0; \
	done; \
	echo "==============="; \
	if [ $$ok -eq 1 ]; then \
		echo "PASS check-stream-sweep: all 6 LOOP values match"; \
	else \
		echo "FAIL check-stream-sweep: at least one LOOP value mismatched"; \
		exit 1; \
	fi

clean:
	rm -f bench.vvp bench.vcd stream.vvp \
	      stream_rtl.log stream_ref.log stream_lib.log \
	      stream_rtl.digests stream_ref.digests stream_lib.digests
