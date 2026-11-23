# Hardware & Runtime Architecture

`elipsitz.N64` adapts the [MIRLO64](https://github.com/tortugaveloz/MIRLO64) `v1.0` N64 architecture onto the **Game Bub Rev4** (`XC7A100TCSG324-1`) and [`gamebub/framework`](https://github.com/gamebub/framework) (`v1.1.0-beta5`).

---

## 1. Single-MMCM Clock Tree (`rtl/board/n64_mmcm.sv`)

All 6 clock domains derive from a single `MMCME2_ADV` (`VCO = 750.000 MHz` from the `50.000 MHz` board oscillator, `0.000 ppm` error):

| Clock | Divider | Frequency | Domain / Purpose |
| :--- | :---: | ---: | :--- |
| `clk_sys` | `/12` | `62.500 MHz` | N64 RCP (`RSP`, `RDP`, `VI`, `AI`, `SI`, `PI2`, `MI`), `mirlo_regs`, `gb_host_bridge`, and Game Bub `clockOutSystem` |
| `clk_cpu` | `/8` | `93.750 MHz` | `VR4300` CPU + `COP1` FPU (`3:2` synchronous to `clk_sys`) |
| `clk_sys2x` | `/6` | `125.000 MHz` | Dual-rank SDRAM PHY (`sdr_phy_x7.sv`) & async SRAM controller (`gb_sram_ctrl.sv`) |
| `clk_sdram_pad` | `/6` | `125.000 MHz` | Phase-shifted SDRAM output clock (`-150°` centered VCO tap + runtime `MMCME2_ADV` fine phase shift) |
| `clk_spi` | `/4` | `187.500 MHz` | MCU QSPI oversampling (`clockOutSpi`) |
| `clk_display` | `/25` | `30.000 MHz` | Rev4 `ILI9806E` display clock (`clockOutDisplay`) |
| `clk_vid` | `/30` | `25.000 MHz` | N64 `VI` active-window pixel timing generator |

---

## 2. External Memory Hierarchy (`rtl/mem/`, Layout 8)

Game Bub uses **Layout 8** (`LAYOUT_MARK = 0x4D4C0008` in `lang/mips/include/layout.h`), mapping 64 MiB of dual-rank SDRAM and 512 KiB of 10 ns asynchronous SRAM.

### 2.1 64 MiB Dual-Rank SDRAM (`sdr_ctrl_w9825.sv`, `sdr_arb_gb.sv`, `sdr_phy_x7.sv`)
- Two `Winbond W9825G6KH-6` devices (`2 x 32 MiB`, `9-bit` columns `A[8:0]`, `13-bit` rows, `4` banks/rank = **8 independent open-page `{rank, bank}` trackers** at `125 MHz` = `250 MB/s`).
- 6-port priority/look-ahead arbiter (`0`: VI scan-out, `1`: VR4300 CPU, `2`: RDP pixels/Z, `3`: RSP DMA, `4`: Bridge/PI/AI/SI/ROM-cache, `5`: RDP command fetch) with 9-bit-column `hmap` coverage bank permutation.
- 100% `ILOGICE2.IFF` / `OLOGICE2.OUTFF` / `OLOGICE2.TFF` pad IOB packing.

| CPU Address (`FLAT`) | SDRAM Offset | Size | Contents |
| :--- | :--- | ---: | :--- |
| `0x4000_0000 – 0x400F_FFFF` | `0x0000_0000` | `1 MiB` | `n64rt.sys` runtime & stack (`File ID 3`) |
| `0x4010_0000 – 0x434F_FFFF` | `0x0010_0000` | `52 MiB` | Resident Cartridge ROM (`File ID 0`); for `64 MiB` ROMs, `51 MiB` resident + `1 MiB` (`16 x 64 KiB`) on-demand page cache |
| `0x4350_0000 – 0x436F_FFFF` | `0x0350_0000` | `2 MiB` | Reserved / spare SDRAM headroom (32-bit RDP shadow plane omitted on Game Bub) |
| `0x4370_0000 – 0x437F_FFFF` | `0x0370_0000` | `1 MiB` | RDP hidden coverage plane |
| `0x4380_0000 – 0x43FF_FFFF` | `0x0380_0000` | `8 MiB` | N64 Main RDRAM (`4 MiB` base + `4 MiB` Expansion Pak) |

### 2.2 512 KiB 10 ns Async SRAM (`gb_sram_ctrl.sv`, `pi_rom_cache.sv`)
- `ISSI IS61WV25616EDBLL-10TLI` (`256K x 16-bit`, IOB-registered glitch-free `WE#`, 32 ns read window per halfword for comfortable `10 ns` `tAA` setup margin).
- Accessed by the CPU via `0x3410_0000 – 0x3417_FFFF` and by the PI engine with bit 25 (`ps = 1`).

| CPU Address | SRAM Offset | Size | Contents |
| :--- | :--- | ---: | :--- |
| `0x3410_0000 – 0x3410_7FFF` | `0x00000` | `32 KiB` | Reserved / Controller Paks 2–4 |
| `0x3410_8000 – 0x3410_FFFF` | `0x08000` | `32 KiB` | Controller Pak 1 (`File ID 2`, `.mpk`) |
| `0x3411_0000 – 0x3412_FFFF` | `0x10000` | `128 KiB` | Reserved / extended Pak space |
| `0x3413_0000 – 0x3413_FFFF` | `0x30000` | `64 KiB` | `n64savedb.txt` (`File ID 4`) |
| `0x3414_0000 – 0x3415_FFFF` | `0x40000` | `128 KiB` | Cartridge Domain-2 Save (`File ID 1`, `.sav`: EEPROM / SRAM / FlashRAM) |
| `0x3416_0000 – 0x3416_0FFF` | `0x60000` | `4 KiB` | FlashRAM page buffer & status words (`LAYOUT_SAVE_AUX`) |
| `0x3416_2000 – 0x3416_3FFF` | `0x62000` | `8 KiB` | Soft-restart `.data` snapshot (`LAYOUT_RESTART`) |
| `0x3416_8000 – 0x3417_7FFF` | `0x68000` | `64 KiB` | Zero-SDRAM-contention L2 Cartridge ROM Cache (paired with `16 KiB` L1 BRAM burst cache) |

---

## 3. Core Subsystems

- **VR4300 CPU & COP1 FPU (`rtl/mips/`, `rtl/soc/mips_sys.sv`):**
  - Full 64-bit integer instructions (`W64_ALU`, `W64_SH`, `W64_MD`, `W64_DIV`, `W64_UA`), 32-entry hardware TLB (`TLB_EN`), `16 KiB` I-cache / `8 KiB` D-cache, monitor exception level (`MON`), and hardware RCP pass-through (`MI`, `PIW`, `PI2W`, `ROM64W`, `VIW`, `AIW`, `SIW`, `SPW`).
  - `fpu_n64.sv` with `Status.FR=1` (two 32-word banks for 32×64-bit FPU registers) and `fpu_d64.sv` (53-bit exact IEEE-754 double-precision add/sub/mul/compare).
- **RSP (`rtl/rsp/`):**
  - `rsp_top.sv` (`LANES=8`, `MULW=1`), 4-bank 128-bit DMEM built from 8× Artix-7 `RAMB18E1` primitives (`rsp_dpram.sv`), distributed LUTRAM vector register file (`rsp_lutram.v`), and `4 KiB` IMEM with `rspboot` self-DMA support.
- **RDP (`rtl/rdp/`):**
  - `rdp_top.v`, `rdp_pix.v`, `rdp_mem.v`, `rdp_tmem.v`, `rdp_dpc.sv`, and `rcp_dpc_view.sv` with MIRLO64 `v1.0` per-pixel 1/8-clock timing, 12-bit `LOAD_BLOCK` count, zero-Z depth-compared rectangles, and `LOD_FRACTION` fix.
- **PI Cartridge Bus & Host Bridge (`rtl/soc/n64_soc_gb.sv`, `rtl/bridge/gb_host_bridge.sv`):**
  - Hardware PI2 DMA engine + MIRLO64 `v1.0` asynchronous PI write latch (`X_PIR`, 112-cycle `pi_busy`).
  - Translates MIRLO64 `APF`-style bridge/interact/pad CSRs (`mirlo_regs.sv`) onto Game Bub `HostV0` (with `SETSIZE` and `FLUSH` extensions), `InputExtendedV0(numSlots = 4, hasRumble = true)`, and `CartridgePortV0`.
- **Video & HUD (`rtl/soc/n64_video.sv`, `rtl/video_gb/n64_video_gb_downsampler.sv`):**
  - `VideoV0(320, 240, 6, 6, 6)`: `640 -> 320` horizontal blend + `480i/p -> 240p` vertical weave de-interlacing + `2x2` Bayer ordered dithering (`RGB888 -> RGB666`) + optional zero-BRAM live N64 `FPS Counter` badge, scaled `2x` by `HandheldTop` to `640x480` (4:3) on both LCD and Dock HDMI.
- **Audio (`rtl/soc/rcp_ai.sv`):**
  - `AudioV0`: Exact `48,000.000 Hz` (`12 / 15,625` of `62.5 MHz`) 16-bit stereo ring buffer.
- **Physical Transfer Pak (`rtl/soc/gb_cart.sv`, `lang/n64rt/n64rt_pak.c`):**
  - `CartridgePortV0` DMG/CGB bus at `976.6 kHz` `PHI`, gated in both RTL and runtime by hardware `cartridge.switch` (`5 V` DMG/CGB detect; all level shifters & drivers forced tri-state/disabled for empty slots or `3.3 V` GBA carts), open-drain `nRST`, Nintendo logo/checksum `TRUST` write-protection, and hot-swap detection.

---

## 4. Utilization & Timing

See [`docs/UTILIZATION.md`](UTILIZATION.md) for measured Vivado 2023.2 post-route LUT, register, BRAM, DSP, IOB, and timing reports.
