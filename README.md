# Game Bub Nintendo 64 FPGA Core (`Eli.N64`)

Nintendo 64 FPGA core for the **Game Bub Rev4** handheld (`XC7A100TCSG324-1`), adapting the clean-room [MIRLO64](https://github.com/tortugaveloz/MIRLO64) architecture (`Apache-2.0`) onto [`gamebub/framework`](https://github.com/gamebub/framework).

## 1. Hardware Architecture Summary

- **Single-MMCM Clock Tree (`rtl/board/n64_mmcm.sv`):** Single `MMCME2_ADV` (`VCO = 750.000 MHz` from `50.000 MHz` reference, `0.000 ppm` error):
  - `62.500 MHz` (`/12`): `clk_sys` — N64 RCP (`RSP`, `RDP`, `VI`, `AI`, `SI`, `PI2`, `MI`) & Game Bub `clockOutSystem`
  - `93.750 MHz` (`/8`): `clk_cpu` — N64 `VR4300` + `COP1` FPU (`fpu_n64.sv` + 53-bit IEEE-754 double-precision `fpu_d64.sv`, `3:2` synchronous to `clk_sys`)
  - `125.000 MHz` (`/6`): `clk_sys2x` + phase-shifted `clk_sdram_pad` (`-150°` centered VCO tap + runtime `MMCME2_ADV` fine phase shift, with 100% `ILOGICE2.IFF` / `OLOGICE2.OUTFF` / `OLOGICE2.TFF` pad IOB packing)
  - `187.500 MHz` (`/4`): `clk_spi` — MCU QSPI oversampling (`clockOutSpi`)
  - `30.000 MHz` (`/25`): `clk_display` — Rev4 `ILI9806E` display clock (`clockOutDisplay`)
  - `25.000 MHz` (`/30`): `clk_vid` — N64 `VI` active-window pixel timing generator
- **External Memory Hierarchy (`rtl/mem/`):**
  - **64 MiB Dual-Rank SDRAM (`sdr_ctrl_w9825.sv`, `sdr_arb_gb.sv`, `sdr_phy_x7.sv`):** Two `Winbond W9825G6KH-6` (`2x 32 MiB`, `9-bit` columns `A[8:0]`, `13-bit` rows, `4` banks/rank = **`8` independent open-page `{rank, bank}` trackers** at `125 MHz` = `250 MB/s`) with updated 9-bit-column `hmap` coverage bank permutation:
    - `0x0000_0000 – 0x000F_FFFF` (`1 MiB`): `n64rt.sys` runtime & stack
    - `0x0010_0000 – 0x034F_FFFF` (`52 MiB`): Resident Cartridge ROM (`.z64`/`.v64`/`.n64` hardware auto-byteswapped on load; or `51 MiB` resident + `1 MiB` `16 x 64 KiB` on-demand page cache in `05-n64-64mb-ondemand`)
    - `0x0350_0000 – 0x036F_FFFF` (`2 MiB`): Reserved / spare SDRAM headroom
    - `0x0370_0000 – 0x037F_FFFF` (`1 MiB`): RDP hidden coverage plane
    - `0x0380_0000 – 0x03FF_FFFF` (`8 MiB`): N64 Main RDRAM (`4 MiB` base + `4 MiB` Expansion Pak)
  - **512 KiB 10 ns Async SRAM (`gb_sram_ctrl.sv`, `pi_rom_cache.sv`):** `ISSI IS61WV25616EDBLL-10TLI` (`256K x 16-bit`, IOB-registered glitch-free `WE#`):
    - `0x00000 – 0x07FFF` (`32 KiB`): Soft-restart `.data` snapshot (`0x00000..0x01FFF`) + Controller Paks 2–4 (`0x02000..0x07FFF` future slots)
    - `0x08000 – 0x0FFFF` (`32 KiB`): Controller Pak 1 (`File ID 2`, `.mpk`)
    - `0x10000 – 0x2FFFF` (`128 KiB`): Reserved / extended Pak space
    - `0x30000 – 0x3FFFF` (`64 KiB`): `n64savedb.txt` (`File ID 4`)
    - `0x40000 – 0x67FFF` (`160 KiB`): Cartridge Domain-2 Save (`File ID 1`, `.sav`: `EEPROM 4K/16K`, `SRAM 32K`, `FlashRAM 128K` + silicon ID)
    - `0x68000 – 0x77FFF` (`64 KiB`): Zero-SDRAM-contention L2 Cartridge ROM Cache (paired with `16 KiB` L1 BRAM burst cache)
- **Video, Audio, Controls, & Host I/O:**
  - `VideoV0(320, 240, 6, 6, 6)` (`n64_video_gb_downsampler.sv`): `640->320` horizontal blend + `480i/p->240p` vertical weave de-interlacing + `2x2` Bayer ordered dithering (`RGB888 -> RGB666`) + optional zero-BRAM `Top-Right` / `Top-Left` live N64 `FPS Counter` badge, scaled `2x` by `HandheldTop` to `640x480` (4:3) on both LCD and Dock HDMI.
  - `AudioV0`: Exact `48,000.000 Hz` (`12 / 15,625` of `62.5 MHz`) 16-bit stereo ring buffer fed by `rcp_ai`.
  - `InputExtendedV0(numSlots = 4)` + `VibrateV0`: Up to 4 docked analog/digital gamepads + handheld `R`-modifier C-button presets + Player 1 Rumble Pak motor support.
  - `CartridgePortV0` (`gb_cart.sv` + `n64rt_pak.c`): Physical Game Boy / Game Boy Color **Transfer Pak** support on Player 1 (`976.6 kHz` `PHI` bus, hardware `cartridge.switch` 5 V DMG/CGB detection & 3.3 V GBA/empty isolation, open-drain `nRST`, Nintendo logo/header checksum `TRUST` write-protection, and live cartridge hot-swap detection).

---

## 2. Measured Vivado 2023.2 Post-Route Utilization & Timing (`XC7A100TCSG324-1`)

| Core Class (`Bundle`) | Slice LUTs (`63,400`) | Slice Regs (`126,800`) | Block RAM (`135`) | `DSP48E1` (`240`) | `WNS` (`ns`) | `WHS` (`ns`) | `WPWS` (`ns`) | `.bit` Size |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **`N64MemDiagCore`** (`01-mem-diag`) | `7,122` (`11.23%`) | `3,977` (`3.14%`) | `86.5` (`64.07%`) | `0` (`0.00%`) | **`+0.585`** | **`+0.052`** | **`+2.167`** | `573,277 B` |
| **`N64SelfTestCore`** (`02-mips-self-test`) | `36,240` (`57.16%`) | `20,432` (`16.11%`) | `128.5` (`95.19%`) | `45` (`18.75%`) | **`+0.077`** | **`+0.050`** | **`+2.167`** | `2,676,349 B` |
| **`N64Core`** (`03..05` Production Core) | **`36,095` (`56.93%`)** | **`20,432` (`16.11%`)** | **`123.5` (`91.48%`)** | **`35` (`14.58%`)** | **`+0.291`** | **`+0.012`** | **`+2.167`** | **`2,652,821 B`** |

All three bitstreams build with **`0` Critical Warnings, `0` DRC Errors, `0` latches, 100% IOB-packed SDRAM/SRAM buses (`36 ps` pin-to-pin DQ skew, `+8.960 ns` physical 10 ns Async SRAM read setup margin), `0.000 ns` `TNS`/`THS`, and 100% Vivado gate-vs-RTL `xsim` lockstep equivalence (`rsp_top`, `rcp_ai`, `mips_sys`, `rdp_top`)**.

---

## 3. Ready-to-Copy SD Card Deliverables (`dist/`) & On-Device Bring-Up Order

Each folder under `dist/<bundle>/cores/` can be copied directly onto the root `cores/` directory of a FAT32 microSD card:

1. **`dist/01-mem-diag/cores/GameBub.N64MemDiag/` — External Memory & Phase-Sweep Diagnostic**
   - Needs **no ROM files**. Continuously sweeps Rank 0 `W9825G6KH-6`, Rank 1 `W9825G6KH-6` (+ CS isolation), `IS61WV25616EDBLL-10TLI` 10 ns SRAM, and the L1/L2 PI ROM cache while rendering a live `320x240` HUD.
   - Top banner turns **solid green** once Pass 1 completes with `0` errors; use `D-Pad Left/Right` or Core Settings (`SDRAM Clock Phase`) to sweep `sdram_clk` fine phase if characterizing board margins, and hold `B` to test `48 kHz` audio + rumble motor.
2. **`dist/02-mips-self-test/cores/GameBub.N64SelfTest/` — Self-Contained VR4300 + RSP + RDP + Audio + Input Self-Test**
   - Needs **no ROM files**. Boots embedded MIPS64 firmware (`rtl/diag/n64_selftest.hex`) exercising `VR4300` 64-bit integer + `COP1` FPU, `64 MiB` SDRAM + `512 KiB` SRAM, 8-lane `RSP` vector unit, `RDP` 3D triangle rasterization (`VI` -> `VideoV0` color bars + live 4-slot controller viewer), `rcp_ai` 440 Hz stereo audio, and Rumble (`Hold A`).
3. **`dist/03-n64-core/cores/Eli.N64/` (and `dist/04-n64-polished/cores/Eli.N64/`) — Full N64 Core (Eager ROM Load up to `52 MiB`)**
   - Copy `cores/Eli.N64/` to `/cores/Eli.N64/` on your microSD card and place `.z64`, `.n64`, or `.v64` ROMs in your ROMs folder.
   - Automatically byteswaps `.v64`/`.n64` images in hardware, detects save type (`EEPROM 4K/16K`, `SRAM 32K`, `FlashRAM 128K`) via `n64savedb.txt` and `?ED?` homebrew ROM headers, persists `.sav` and `.mpk` files via `HostV0`, supports physical GB/GBC cartridges via **Transfer Pak** (`Controller 1 Pak = Transfer Pak`), and exposes Pak type, handheld control presets, N64 D-Pad mapping, deadzone, Expansion Pak toggle, `VI Deblur`, overscan crop, and `Restart Game` in `settings.json`.
4. **`dist/05-n64-64mb-ondemand/cores/Eli.N64/` — Phase 5 `64 MiB` On-Demand Paging Bundle**
   - Identical `N64Core` bitstream paired with `on_demand: true` `files.json` (`metadata/files_ondemand.json`), displaying a live on-screen `"NINTENDO 64 / LOADING ROM..."` progress bar while streaming up to `51 MiB` into resident SDRAM plus `64 KiB` tail pages (`51..64 MiB`) on demand via `HostV0` Core->Host commands (`0x0400` `FileGetSize` & `0x0402` `FileRead`) to support `64 MiB` titles (*Resident Evil 2*, *Pokemon Stadium 2*, *Conker's Bad Fur Day*, *Paper Mario*).
   - For standard `<= 52 MiB` cartridges (*Super Mario 64*, *Mario Kart 64*, *Animal Forest*, *Ocarina of Time*, *Majora's Mask*, *Banjo-Kazooie*), `03-n64-core` / `04-n64-polished` eagerly stream the entire ROM during MCU `Setup` using Game Bub's native `"Loading..."` screen with zero in-game SD paging latency.

---

## 4. Controls & In-Core Settings (`metadata/settings.json`)

Input mapping (`lang/n64rt/n64rt_pad.h`) automatically adapts to whether you are playing on **Game Bub's built-in handheld controls** or with **docked gamepads** (`InputExtendedV0` slots 1–4):

### Docked Analog Gamepad (Out of the Box)
Every N64 control maps natively 1-to-1 with zero modifier chords (`Handheld R Mode` and `Select Shift` never interfere with docked analog controllers):

| N64 Control | Gamepad Input (Default) | Notes |
| :--- | :--- | :--- |
| **Analog Stick** | **Left Stick** | 13% radial deadzone (adjustable via `Stick Deadzone`) |
| **C-Up / Down / Left / Right** | **Right Stick** | Push >50% on dominant axis (`Y` = `C-Left`, `X` = `C-Right` also active as extras) |
| **D-Pad** | **D-Pad** | Enabled automatically when docked (`N64 D-Pad = Auto (Gamepad)`) |
| **`L` / `R` Triggers** | **`L1` / `R1`** | `Docked Triggers = MIRLO` swaps to legacy `L1=Z`, `L2=L`, `R1=R`, `R2=C-Up` |
| **`Z` Trigger** | **`L2 / LT` and `R2 / RT`** | Either analog/digital trigger presses N64 `Z` |
| **`A` / `B` / `Start`** | **`A` / `B` / `Start`** | Direct 1:1 |

### Game Bub Handheld (Built-In Controls)
With defaults (`Handheld R Mode = R + ABXY = C-Btns`, `Handheld Select = Shift (L/R/DPad/C)`), **all 14 N64 buttons + Analog Stick** are accessible in-game:

| Input | Normal Press | Hold `R` (Default `R + ABXY`) | Hold `Select` (Default `Shift Layer`) |
| :--- | :--- | :--- | :--- |
| **D-Pad** | N64 **Analog Stick** (`100%`) | N64 **Analog Stick** | **N64 D-Pad** (Stick centered) |
| **`A` / `B`** | **N64 `A`** / **N64 `B`** | **`C-Right`** / **`C-Down`** | **`C-Right`** / **`C-Down`** |
| **`Y` / `X`** | **`C-Left`** / **`C-Right`** | **`C-Left`** / **`C-Up`** | **`C-Left`** / **`C-Up`** |
| **`L` / `R`** | **N64 `Z`** / *(C-Btn modifier)* | **N64 `Z`** / — | **N64 `L`** / **N64 `R`** |
| **`Start`** | **N64 `Start`** | **N64 `Start`** | **N64 `Start`** |

> **Tip:** For games that use **`R` directly** (such as *Mario Kart 64*, *F-Zero X*, or shielding in *Zelda: Ocarina of Time*), switch **`Handheld R Mode`** to **`Normal N64 R`** — you can still press all four C-buttons via **`Select + X/B/Y/A`** (or switch **`Handheld Select`** to **`Start = Sel+Start`** to put `C-Up` on the standalone `Start` button and `C-Down` on `Select`).

### Core Settings Reference

| Setting | Options (`*` = Default) | Behavior |
| :--- | :--- | :--- |
| **`Controller 1 Pak`** | `Controller Pak*`, `Rumble Pak`, `Transfer Pak`, `None` | Player 1 accessory (`Transfer Pak` reads physical DMG/CGB carts in the cartridge slot) |
| **`Handheld R Mode`** | `R + ABXY = C-Btns*`, `R + DPad = Walk`, `Normal N64 R`, `R = N64 L Trigger` | Role of handheld `R` shoulder (`Walk` = 60% stick deflection) |
| **`Handheld Select`** | `Shift (L/R/DPad/C)*`, `C-Down (Classic)`, `Start = Sel+Start` | Role of handheld `Select` (`Start = Sel+Start` frees `Start` as `C-Up`) |
| **`Docked Triggers`** | `L/R + L2/R2=Z*`, `MIRLO (L1=Z, R2=C)` | Standard 4-shoulder gamepad layout vs legacy `MIRLO64` Pocket Dock triggers |
| **`Analog Stick`** | `L-Stick / D-Pad*`, `D-Pad Only`, `Right Stick` | Analog Stick source (`L-Stick / D-Pad` falls back to D-Pad on handheld) |
| **`C-Buttons Extra`** | `Right Stick*`, `Face Only`, `D-Pad` | Additional source for `C-Up / C-Down / C-Left / C-Right` |
| **`N64 D-Pad`** | `Auto (Gamepad)*`, `Always D-Pad`, `Left Stick`, `Right Stick` | N64 D-Pad source (`Auto` enables D-Pad on docked gamepads only) |
| **`Stick Deadzone`** | `13% (Default)*`, `0%`, `10%`, `20%`, `30%` | Radial analog deadzone for docked sticks |
| **`4MB RDRAM Only`** | Unchecked (`8 MiB Expansion Pak`)* / Checked (`4 MiB`) | Toggle Expansion Pak visibility |
| **`VI Deblur`** | Unchecked* / Checked | Toggle VI de-blur |
| **`Scaling Filter`** | `Smooth + Dither*`, `Crisp + Dither`, `Smooth Raw 6b`, `Crisp Raw 6b` | Downsampler horizontal blend & `2x2` Bayer dithering |
| **`Crop Overscan`** | `Off*`, `4 Lines`, `8 Lines`, `12 Lines` | Crop black overscan borders |
| **`Restart Game`** | Action | Soft-restarts the N64 console (`Cartridge + Pak` states preserved) |
| **`FPS Counter`** | `Top-Right*`, `Top-Left`, `Off` | Toggle zero-BRAM live N64 VI/RDP FPS HUD badge |

---

## 5. Verification & Rebuilding from Source

### Run Verilator Suites (via `mirlo64-tools` Docker image)
```bash
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -e VERILATOR=verilator -e VERILATOR_ROOT=/usr/share/verilator \
  -v "$PWD:$PWD" -w "$PWD" mirlo64-tools bash -c '
    bash sim/mem_gb/run_all.sh &&
    bash sim/bridge/run_all.sh &&
    bash sim/video_gb/run_all.sh &&
    bash sim/gb_n64_soc/run_all.sh
  '
```

### Build `N64Core` Bitstream & Repackage `dist/` (Vivado 2023.2)
```bash
export PATH="$HOME/Xilinx2023.2/Vivado/2023.2/bin:$PATH"
./mill root.buildCore --target gamebub_rev4 --core-class N64Core
python3 tools/package_dist.py --bundle n64
```

## 6. Framework Notes & Upstream Proposals

`Eli.N64` builds against **100% unmodified** upstream [`gamebub/framework`](https://github.com/gamebub/framework) (`f2b000c`). See [`docs/FRAMEWORK_PROPOSALS.md`](docs/FRAMEWORK_PROPOSALS.md) for:
1. Notes on `(* IOB = "TRUE" *)` scalar-to-vector `OLOGICE2.TFF` auto-replication across `HandheldTop` (`SdramV0`/`SramV0`).
2. **Option B Upstream RFC:** Cycle-accurate `10 ns` `IS61WV25616EDBLL-10TLI` SRAM display framebuffer interleaving design for `HandheldTop.scala` (reclaiming `73.0` `RAMB36E1`s for future cores that do not use `SramV0`).

## License

Licensed under the Apache License, Version 2.0 (see `LICENSE` and `NOTICE`).
