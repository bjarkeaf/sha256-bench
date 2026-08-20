# Pynq-Z2 (TUL, xc7z020clg400-1) pin constraints for sha256_stream_bscan_top.
#
# No PMOD pin required: readback is via the JTAG TAP on the existing USB cable.

# 125 MHz onboard clock
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -name sys_clk -period 8.000 -waveform {0.000 4.000} [get_ports clk]

# The design runs on a BUFG-driven /2 divider (see rtl/clk_div2.v).
create_generated_clock -name clk_div2                    \
                       -source [get_ports clk]           \
                       -divide_by 2                      \
                       [get_pins divider/bufg_inst/O]

# LEDs LD0..LD1
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports led_alive]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports led_done]

# Bank voltage / config voltage for bank 34.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
