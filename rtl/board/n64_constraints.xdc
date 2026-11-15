################################################################################
# Game Bub N64 Core — Board & Clock Timing Constraints (XC7A100TCSG324-1)
################################################################################

# Pack external SDRAM (125 MHz) and async SRAM (10 ns) registers into IOBs for
# deterministic board-level setup/hold timing across builds.
set_property IOB TRUE [get_ports {sdram_a[*] sdram_bs[*] sdram_cs_n[*] sdram_cke[*] sdram_ras_n sdram_cas_n sdram_we_n sdram_ldqm sdram_udqm}]
set_property IOB TRUE [get_ports {sram_a[*] sram_ce_n sram_we_n sram_oe_n sram_ub_n sram_lb_n}]

# Fast slew on 125 MHz SDRAM clock and command/data signals
set_property SLEW FAST [get_ports {sdram_clk sdram_dq[*] sdram_a[*] sdram_bs[*] sdram_cs_n[*] sdram_ras_n sdram_cas_n sdram_we_n sdram_ldqm sdram_udqm}]
