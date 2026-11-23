# Nintendo 64 for Game Bub (`elipsitz.N64`)

> [!WARNING]
> **Unofficial / Unsupported Proof of Concept**
> - **This is NOT an official Game Bub project.**
> - **This core is essentially an AI slop proof of concept** put together to demonstrate that Nintendo 64 can run on the Game Bub hardware.
> - **No support is provided.** Use at your own risk — bug reports, compatibility requests, and support questions will not be answered.

A Nintendo 64 FPGA core for the **Game Bub Rev4** handheld (`XC7A100TCSG324-1`), porting the clean-room [MIRLO64](https://github.com/tortugaveloz/MIRLO64) `v1.0` core (`Apache-2.0`) onto [`gamebub/framework`](https://github.com/gamebub/framework) (`v1.1.0-beta5`).

## Features

- **Full N64 hardware core (MIRLO64 `v1.0`):** `VR4300` CPU at `93.75 MHz` (with 53-bit IEEE-754 double-precision FPU and `Status.FR=1` 32×64-bit FPU mode), `8`-lane `RSP`, per-pixel console-timed `RDP`, and hardware `VI`/`AI`/`SI`/`PI2`/`MI`.
- **Up to `64 MiB` ROMs:** Supports `.z64`, `.n64`, and `.v64` (auto-detected and byteswapped in hardware). ROMs up to `52 MiB` load completely into SDRAM at boot with an on-screen loading bar; `64 MiB` titles (*Resident Evil 2*, *Pokemon Stadium 2*, *Conker's Bad Fur Day*, *Paper Mario*) preload `51 MiB` and page the remaining `13 MiB` on demand.
- **Saves & Accessories:** Auto-detected `EEPROM 4K/16K`, `SRAM 32K`, and `FlashRAM 128K` via `n64savedb.txt`, plus Player 1 **Controller Pak** (`.mpk`), **Rumble Pak** (handheld haptic motor & docked controller rumble), and **physical Game Boy / Game Boy Color Transfer Pak** through Game Bub's cartridge slot.
- **Video & Audio:** `320x240` `RGB666` with horizontal blend, `480i/p -> 240p` weave de-interlacing, `2x2` Bayer dithering, optional overscan crop and live FPS counter HUD (`2x` scaled to `640x480` 4:3 on LCD and Dock HDMI), plus exact `48 kHz` 16-bit stereo audio.
- **Handheld & 4-Player Docked Controls:** Automatic layout switching between Game Bub's built-in buttons and up to 4 docked analog gamepads.

---

## Installation

1. Download the release archive (`elipsitz.N64-v0.3.0.zip`), which contains a single `elipsitz.N64/` folder.
2. Copy `elipsitz.N64/` to `/cores/elipsitz.N64/` on your Game Bub microSD card (requires Game Bub firmware `1.1.0-beta.5` or later).
3. Place `.z64`, `.n64`, or `.v64` ROMs anywhere on your microSD card and select one when launching the core.

---

## Controls

Input mapping automatically adapts to whether you are using **Game Bub's built-in handheld controls** or **docked gamepads** (`InputExtendedV0` slots 1–4).

### Docked Analog Gamepad (Out of the Box)
Every N64 control maps natively 1-to-1 with no modifier chords (`Handheld R Mode` and `Select Shift` never interfere with docked analog controllers):

| N64 Control | Gamepad Input (Default) | Notes |
| :--- | :--- | :--- |
| **Analog Stick** | **Left Stick** | 13% radial deadzone (adjustable via `Stick Deadzone`) |
| **C-Up / Down / Left / Right** | **Right Stick** | Push >50% on dominant axis (`Y` = `C-Left`, `X` = `C-Right` also active as extras) |
| **D-Pad** | **D-Pad** | Enabled automatically when docked (`N64 D-Pad = Auto (Gamepad)`) |
| **`L` / `R` Triggers** | **`L1` / `R1`** | `Docked Triggers = MIRLO` swaps to legacy `L1=Z`, `L2=L`, `R1=R`, `R2=C-Up` |
| **`Z` Trigger** | **`L2 / LT` and `R2 / RT`** | Either analog/digital trigger presses N64 `Z` |
| **`A` / `B` / `Start`** | **`A` / `B` / `Start`** | Direct 1:1 |

### Game Bub Handheld (Built-In Controls)
With defaults (`Handheld R Mode = R + ABXY = C-Btns`, `Handheld Select = Shift (L/R/DPad/C)`), **all 14 N64 buttons + Analog Stick** are reachable in-game:

| Input | Normal Press | Hold `R` (Default `R + ABXY`) | Hold `Select` (Default `Shift Layer`) |
| :--- | :--- | :--- | :--- |
| **D-Pad** | N64 **Analog Stick** (`100%`) | N64 **Analog Stick** | **N64 D-Pad** (Stick centered) |
| **`A` / `B`** | **N64 `A`** / **N64 `B`** | **`C-Right`** / **`C-Down`** | **`C-Right`** / **`C-Down`** |
| **`Y` / `X`** | **`C-Left`** / **`C-Right`** | **`C-Left`** / **`C-Up`** | **`C-Left`** / **`C-Up`** |
| **`L` / `R`** | **N64 `Z`** / *(C-Btn modifier)* | **N64 `Z`** / — | **N64 `L`** / **N64 `R`** |
| **`Start`** | **N64 `Start`** | **N64 `Start`** | **N64 `Start`** |

> **Tip:** For games that use **`R` directly** (*Mario Kart 64*, *F-Zero X*, shielding in *Ocarina of Time*), switch **`Handheld R Mode`** to **`Normal N64 R`** — you can still hit all four C-buttons via **`Select + X/B/Y/A`**, or switch **`Handheld Select`** to **`Start = Sel+Start`** to put `C-Up` on `Start` and `C-Down` on `Select`.

---

## In-Core Settings (`metadata/settings.json`)

| Setting | Options (`*` = Default) | Behavior |
| :--- | :--- | :--- |
| **`Controller 1 Pak`** | `Controller Pak*`, `Rumble Pak`, `Transfer Pak`, `None` | Player 1 accessory (`Transfer Pak` reads physical DMG/CGB carts in the cartridge slot) |
| **`Handheld R Mode`** | `R + ABXY = C-Btns*`, `R + DPad = Walk`, `Normal N64 R`, `R = N64 L Trigger` | Role of handheld `R` shoulder (`Walk` = 60% stick deflection) |
| **`Handheld Select`** | `Shift (L/R/DPad/C)*`, `C-Down (Classic)`, `Start = Sel+Start` | Role of handheld `Select` (`Start = Sel+Start` frees `Start` as `C-Up`) |
| **`Docked Triggers`** | `L/R + L2/R2=Z*`, `MIRLO (L1=Z, R2=C)` | Standard 4-shoulder gamepad layout vs legacy MIRLO64 Pocket Dock triggers |
| **`Analog Stick`** | `L-Stick / D-Pad*`, `D-Pad Only`, `Right Stick` | Analog Stick source (`L-Stick / D-Pad` falls back to D-Pad on handheld) |
| **`C-Buttons Extra`** | `Right Stick*`, `Face Only`, `D-Pad` | Additional source for `C-Up / C-Down / C-Left / C-Right` |
| **`N64 D-Pad`** | `Auto (Gamepad)*`, `Always D-Pad`, `Left Stick`, `Right Stick` | N64 D-Pad source (`Auto` enables D-Pad on docked gamepads only) |
| **`Stick Deadzone`** | `13% (Default)*`, `0%`, `10%`, `20%`, `30%` | Radial analog deadzone for docked sticks |
| **`4MB RDRAM Only`** | Unchecked (`8 MiB Expansion Pak`)* / Checked (`4 MiB`) | Toggle Expansion Pak visibility |
| **`VI Deblur`** | Unchecked* / Checked | Toggle VI de-blur |
| **`Scaling Filter`** | `Smooth + Dither*`, `Crisp + Dither`, `Smooth Raw 6b`, `Crisp Raw 6b` | Downsampler horizontal blend & `2x2` Bayer dithering |
| **`Crop Overscan`** | `Off*`, `4 Lines`, `8 Lines`, `12 Lines` | Crop black overscan borders |
| **`Restart Game`** | Action | Soft-restarts the N64 console (cartridge & Pak states preserved) |
| **`FPS Counter`** | `Top-Right*`, `Top-Left`, `Off` | Toggle zero-BRAM live N64 VI/RDP FPS HUD badge |

---

## Documentation

| Document | Contents |
| :--- | :--- |
| [**`docs/ARCHITECTURE.md`**](docs/ARCHITECTURE.md) | Clock tree, dual-rank SDRAM & SRAM Layout 8 memory map, and CPU/RSP/RDP/VI/AI/SI/Transfer Pak hardware details |
| [**`docs/UTILIZATION.md`**](docs/UTILIZATION.md) | Measured Vivado 2023.2 post-route LUT, register, BRAM, DSP, IOB, and timing reports |
| [**`docs/BUILD_AND_TEST.md`**](docs/BUILD_AND_TEST.md) | Building `n64rt.sys`, running Verilator unit & full-SoC regression suites, synthesizing bitstreams, and packaging/validating release `.zip` archives |
| [**`docs/PORTING_NOTES.md`**](docs/PORTING_NOTES.md) | Vivado 2023.2 / `xsim` synthesis bugs we fixed, Cyclone V -> Artix-7 adaptations, Game Bub hardware gotchas, and the step-by-step guide for syncing future MIRLO64 releases |

---

## License & Attribution

Licensed under the Apache License, Version 2.0 (see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE)). Built on [MIRLO64](https://github.com/tortugaveloz/MIRLO64) by `tortugaveloz` and [`gamebub/framework`](https://github.com/gamebub/framework).
