# Vivado 2023.2 Utilization & Timing (`XC7A100TCSG324-1`)

Measured post-route metrics for `N64Core` (`elipsitz.N64` `v0.3.0`, MIRLO64 `v1.0`, `gamebub/framework` `v1.1.0-beta5`) built with **Vivado 2023.2** targeting **Game Bub Rev4** (`xc7a100tcsg324-1`).

---

## 1. Resource Utilization

| Resource | Used | Available | Utilization | Notes |
| :--- | ---: | ---: | ---: | :--- |
| **Slice LUTs** | `36,103` | `63,400` | `56.94%` | `34,784` logic (`54.86%`), `1,102` distributed RAM, `217` SRL |
| **Slice Registers** | `20,732` | `126,800` | `16.35%` | `20,732` FFs, **`0` latches** |
| **Slices** | `10,512` | `15,850` | `66.32%` | `7,261` SLICEL, `3,251` SLICEM |
| **F7 / F8 Muxes** | `961` / `279` | `31,700` / `15,850` | `3.03%` / `1.76%` | — |
| **Block RAM Tiles** | **`123.5`** | `135` | **`91.48%`** | `96` `RAMB36E1` + `55` `RAMB18E1` |
| **`DSP48E1`** | `35` | `240` | `14.58%` | CPU mul/FPU + RSP VU + RDP |
| **Bonded IOBs** | `183` | `210` | `87.14%` | `143` IOB Flip-Flops (100% SDRAM/SRAM IOB-packed) |

---

## 2. Post-Route Timing Summary

| Metric | Measured | Failing Endpoints | Total Endpoints | Status |
| :--- | ---: | ---: | ---: | :---: |
| **Setup (`WNS` / `TNS`)** | **`+0.047 ns`** / `0.000 ns` | `0` | `65,456` | PASS |
| **Hold (`WHS` / `THS`)** | **`+0.016 ns`** / `0.000 ns` | `0` | `65,348` | PASS |
| **Pulse Width (`WPWS` / `TPWS`)** | **`+2.167 ns`** / `0.000 ns` | `0` | `23,700` | PASS |

- **Synthesis / Implementation:** `0` Errors, `0` Critical Warnings, `0` DRC Errors, `0` combinational loops, `0` latch loops.
- **Compressed Bitstream (`N64Core-gamebub_rev4.bit`):** `2,664,969 B`.

---

## 3. Clock Domains (`top_handheld`)

| Clock | Period (`ns`) | Frequency (`MHz`) | Purpose |
| :--- | ---: | ---: | :--- |
| `sys_clk_pin` | `20.000` | `50.000` | Board oscillator input |
| `clk_sys_unbuf` | `16.000` | `62.500` | N64 RCP, `mirlo_regs`, `gb_host_bridge`, `clockOutSystem` |
| `clk_cpu_unbuf` | `10.667` | `93.750` | VR4300 CPU + COP1 FPU (`3:2` synchronous to `clk_sys`) |
| `clk_sys2x_unbuf` | `8.000` | `125.000` | Dual-rank SDRAM PHY & async SRAM controller |
| `clk_sdram_unbuf` | `8.000` | `125.000` | Phase-shifted SDRAM pad clock (`-150°`) |
| `clk_spi_unbuf` | `5.333` | `187.500` | MCU QSPI oversampling (`clockOutSpi`) |
| `clk_display_unbuf` | `33.333` | `30.000` | Rev4 `ILI9806E` display clock (`clockOutDisplay`) |
| `clk_vid_unbuf` | `40.000` | `25.000` | N64 VI active-window pixel timing |
| `clk_hdmi_clk_wiz_hdmi` | `36.994` | `27.031` | Dock HDMI pixel clock (`framework`) |
| `clk_hdmi_x5_clk_wiz_hdmi` | `7.399` | `135.156` | Dock HDMI TMDS serializer (`framework`) |
