# Out-of-context clock constraint for SHA-256 bench
# Adjust PERIOD to explore Fmax: lower = more aggressive, higher = relaxed
create_clock -name clk -period 2.5 [get_ports clk]
