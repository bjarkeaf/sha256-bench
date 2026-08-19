# 125 MHz system clock
set_property -dict { PACKAGE_PIN H16 IOSTANDARD LVCMOS33 } [get_ports sysclk]
create_clock -name sysclk -period 8.000 [get_ports sysclk]

# SW0
set_property -dict { PACKAGE_PIN M20 IOSTANDARD LVCMOS33 } [get_ports sw0]

# LED0 = SHA pass
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports led_pass]

# LED1 = heartbeat
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports led_heartbeat]

# LED2 = our bitstream is loaded
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports led_loaded]