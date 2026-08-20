# Pynq-Z2 (TUL, xc7z020clg400-1) pin constraints for sha256_stream_bist_top.
#
# Pinout matches the TUL Pynq-Z2 master XDC. If you're on a different board
# (e.g. PYNQ-Z1) the LED pins differ — check your board's master XDC before
# generating a bitstream.

# 125 MHz onboard clock (routed from the Ethernet PHY to the PL)
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -name sys_clk -period 8.000 -waveform {0.000 4.000} [get_ports clk]

# LEDs LD0..LD3
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports led_match]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports led_done]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports led_mismatch]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports led_alive]

# Bank voltage / config voltage for Zynq bank 34 (LEDs live here).
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
