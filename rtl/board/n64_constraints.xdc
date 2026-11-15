################################################################################
# Game Bub N64 Core — Board & Clock Timing Constraints (XC7A100TCSG324-1)
################################################################################

# Pack external SDRAM (125 MHz: address, command, DQM, and bidirectional DQ
# input/output/tristate FFs) and async SRAM (10 ns) registers into Artix-7
# ILOGICE2 / OLOGICE2 IOBs for deterministic sub-100 ps pin-to-pin skew.
set_property IOB TRUE [get_ports {sdram_dq[*] sdram_a[*] sdram_bs[*] sdram_cs_n[*] sdram_cke[*] sdram_ras_n sdram_cas_n sdram_we_n sdram_ldqm sdram_udqm}]
set_property IOB TRUE [get_ports {sram_a[*] sram_ce_n sram_we_n sram_oe_n sram_ub_n sram_lb_n}]

# Fast slew on 125 MHz SDRAM clock and command/data signals
set_property SLEW FAST [get_ports {sdram_clk sdram_dq[*] sdram_a[*] sdram_bs[*] sdram_cs_n[*] sdram_ras_n sdram_cas_n sdram_we_n sdram_ldqm sdram_udqm}]

# N64 VI pixel clock (clk_vid, 25.000 MHz on MMCME2_ADV CLKOUT6) is an
# asynchronous CDC domain crossing to clk_sys exclusively via Gray-code AFIFOs
# and 2-FF synchronizers (afifo.sv, n64_video.sv, n64_video_gb_downsampler.sv).
# NOTE: clk_sys (62.5 MHz), clk_cpu (93.75 MHz, 3:2), and clk_sys2x (125 MHz, 2:1)
# remain strictly synchronous and fully timed by Vivado STA.
set_clock_groups -name async_n64_vid -asynchronous \
    -group [get_clocks -quiet -of_objects [get_pins -quiet -hierarchical *u_mmcm/CLKOUT6]]
