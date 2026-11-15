# Game Bub Nintendo 64 FPGA Core (`GameBub.N64`)

Nintendo 64 FPGA core for the **Game Bub Rev4** handheld (`XC7A100TCSG324-1`), adapting the clean-room [MIRLO64](https://github.com/tortugaveloz/MIRLO64) architecture (`Apache-2.0`) onto the unmodified [`gamebub/framework`](https://github.com/gamebub/framework).

## Hardware Architecture Summary

- **Clock Tree (`n64_mmcm.sv`):** Single `MMCME2_ADV` (`VCO = 750.000 MHz` from `50 MHz` reference, `0.000 ppm` error):
  - `62.500 MHz` (`/12`): `clk_sys` — N64 RCP (`RSP`, `RDP`, `VI`, `AI`, `SI`, `PI`, `MI`) & Game Bub `clockOutSystem`
  - `93.750 MHz` (`/8`): `clk_cpu` — N64 `VR4300` + `COP1` FPU (`3:2` synchronous to `clk_sys`)
  - `125.000 MHz` (`/6`): `clk_sys2x` + phase-shifted `clk_sdram_pad` (with dynamic fine-phase shift)
  - `187.500 MHz` (`/4`): `clk_spi` — MCU QSPI oversampling (`clockOutSpi`)
  - `30.000 MHz` (`/25`): `clk_display` — Rev4 `ILI9806E` display clock (`clockOutDisplay`)
- **External Memory Hierarchy:**
  - **SDRAM (`64 MiB`):** Dual `Winbond W9825G6KH-6` (`2x 32 MiB`, 16-bit bus @ `125 MHz` = `250 MB/s`, `8` independent open-page `{rank, bank}` trackers) + `16 KiB` L1 BRAM PI burst cache.
  - **Async SRAM (`512 KiB`):** `ISSI IS61WV25616EDBLL-10TLI` (`256K x 16-bit`, `10 ns`) backing N64 Cartridge Saves (`EEPROM 4K/16K`, `SRAM 32K`, `FlashRAM 128K`), `4x 32 KiB` Controller Paks, `n64savedb.txt`, and an L2 PI ROM cache.
- **Video & Audio:** `VideoV0(320, 240, 6, 6, 6)` (`RGB666` with `640->320` horizontal & `480i/p->240p` vertical hardware filtering + ordered dithering, scaled `2x` to `640x480` 4:3 on LCD and HDMI) and `AudioV0` (`48 kHz` 16-bit stereo I2S/HDMI).
- **Controls:** `InputExtendedV0(numSlots = 4)` (4 docked gamepads with analog sticks/triggers + handheld mode presets) and `VibrateV0` (Rumble Pak).

## Building

Ensure Xilinx Vivado 2023.2 is in `PATH`:

```bash
export PATH="$HOME/Xilinx2023.2/Vivado/2023.2/bin:$PATH"
./mill root.buildCore --target gamebub_rev4
```

## License

Licensed under the Apache License, Version 2.0 (see `LICENSE` and `NOTICE`).
