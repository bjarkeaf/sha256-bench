# Pynq-Z2 (TUL, xc7z020clg400-1) pin constraints for sha256_stream_uart_top.
#
# Pinout matches the TUL Pynq-Z2 master XDC. If you're on a different board
# (e.g. PYNQ-Z1) the pins differ — check the board's master XDC before
# generating a bitstream.

# 125 MHz onboard clock (routed from the Ethernet PHY to the PL)
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -name sys_clk -period 8.000 -waveform {0.000 4.000} [get_ports clk]

# PMOD JA1 = UART TX from the FPGA to the laptop's USB-UART adapter.
# Pynq-Z2 PMOD JA pins are on bank 34 (LVCMOS33).
#   JA1 = Y18
#   JA2 = Y19  (available if you ever need RX)
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports uart_tx_pin]

# LEDs LD0..LD1
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports led_alive]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports led_done]

# Bank voltage / config voltage for bank 34.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
