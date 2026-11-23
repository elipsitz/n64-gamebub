# Porting Notes, Vivado Bugs, Game Bub Gotchas, & MIRLO64 Sync Guide

This document captures **everything a developer or agent needs** when maintaining `elipsitz.N64` or updating to a new upstream [MIRLO64](https://github.com/tortugaveloz/MIRLO64) release: Vivado 2023.2 synthesis bugs we hit and how we fixed them, Cyclone V -> Artix-7 adaptations, Game Bub hardware/runtime gotchas, and the step-by-step sync workflow.

- **Current synced MIRLO64 baseline:** `v1.0` (`d064535d444ba5426ef1dbc6afb87df41aca5bad`)
- **Current `gamebub/framework` baseline:** `v1.1.0-beta5` (`3845381be15929c4b51b92e60e41ec5094509e47`)

---

## 1. Upstream MIRLO64 Sync Workflow

**Never blindly overwrite local files from upstream.** Follow this process:

1. Clone upstream MIRLO64 into a scratch folder and review every commit since the baseline SHA above (also recorded in `NOTICE`):
   ```bash
   git log --oneline <old_sha>..<new_sha>
   ```
2. **Exclude Analogue Pocket-only files and features** unless explicitly requested:
   - `platform/pocket/`, `sim/mips_soc/`, `tools/area2/`, Quartus `.qsf`/`.sdc` files
   - Unused RTL: `rtl/mips/mips_geom.sv`, `rtl/mips/mips_lite.sv`, `rtl/soc/mirlo_mips.sv`, `rtl/soc/n64_bus.sv`, `rtl/soc/n64_geom.sv`, `rtl/soc/n64_uart.sv`, `rtl/soc/jtag_uart_bridge.v`
   - Pocket GameShark overlay/database (`lang/n64rt/n64rt_gs*.{c,h}`, `lang/n64rt/gsdz/`)
   - 2 MiB 32-bit RDP shadow plane (`vi_out32`, `wr_sh`, `rd_sh`, `slb_*`, `dither_off`, `out_sh`, `sh_crc`, `un565sh`) — see §3.4
3. **3-way merge shared files** (`rtl/mips/`, `rtl/rsp/`, `rtl/rdp/`, `rtl/soc/` submodules, `lang/mips/`, `lang/n64rt/`, `lang/c/`):
   ```bash
   git merge-file <local_file> <old_upstream_file> <new_upstream_file>
   ```
4. **Manually port `rtl/soc/mirlo_mips.sv` changes into `rtl/soc/n64_soc_gb.sv`:**
   Game Bub replaces `mirlo_mips.sv` with `n64_soc_gb.sv`. Always inspect:
   ```bash
   git diff <old_sha>..<new_sha> -- rtl/soc/mirlo_mips.sv
   ```
   and port any CPU/RCP/PI/MI/VI/AI/SI bus or behavioral additions (such as `v1.0`'s PI cartridge write latch `X_PIR` / `pi_busy` / `pi_word`) into `rtl/soc/n64_soc_gb.sv`.
5. **Sync `vendor/` submodule pins** (`git ls-tree <new_sha> vendor/`) if upstream updated `pythondata-software-picolibc` or `pythondata-software-compiler_rt`.
6. **Audit every changed RTL file** against §2 and §3 below, rebuild `n64rt.sys`, run all tests in [`docs/BUILD_AND_TEST.md`](BUILD_AND_TEST.md), run Vivado 2023.2, and update `NOTICE` + the baseline SHA at the top of this file.

---

## 2. Vivado 2023.2 / `xsim` Synthesis Bugs & Fixes

Upstream MIRLO64 targets **Quartus** and **Verilator 5.052+**. Several constructs that simulate cleanly in Verilator and synthesize cleanly in Quartus **silently mis-synthesize or fail in Vivado 2023.2**:

### 2.1 Dynamic `int'(...)` Array Indexing & Width Truncation (SILENT HARDWARE CORRUPTION)
Verilator evaluates these correctly, so **RTL Verilator tests will NOT catch regressions here**:
- **RSP VU accumulator trimming (`rtl/rsp/rsp_vu.sv`, commit `91e032a`):**
  Indexing unpacked `[8]` arrays via `3'(int'(x_pass) * LANES + l)` caused Vivado 2023.2 to **trim `acc_h/m/l[5..7]` to zero bits**, corrupting 3D vertex matrix transforms (`gspFast3D`) and ADPCM audio (`aspMain`) on FPGA.
  - **Fix:** Split `if (NP == 1) ... else ...` explicitly, compute `automatic logic [2:0] idx_li = {x_pass, 2'(l)};`, and reset `x_pass <= 1'b0;`.
- **RSP 128-bit DMEM rotator truncation (`rtl/rsp/rsp_top.sv` & `rtl/rsp/rsp_vu.sv`, commit `91e032a`):**
  `4 * int'(x_rot[3:2])` and `4 * int'(st_rot[3:2])` caused Vivado to optimize away `x_rot_reg[3:2]`, breaking unaligned 128-bit DMEM vector loads/stores.
  - **Fix:** Decompose the 128-bit rotator into explicit 4-word (`q16_w[0:3]`) and 16-byte (`q_rot_b[0:15]`) stages using fixed-width index arithmetic (`2'(2'(w) + x_rot[3:2])`, `4'(4'(m) + {2'b00, x_rot[1:0]})`).
- **VR4300 unaligned `SDL`/`SDR` byte strobes (`rtl/mips/mips_core.sv`, commit `f9c18cd`):**
  Comparing `p <= int'(m_addr[2:0])` caused Vivado to drop upper strobe lanes in `m_ua_mask`.
  - **Fix:** Compare with explicit 3-bit width: `3'(p) <= m_addr[2:0]` / `3'(p) >= m_addr[2:0]`.
- **Sized casts in arithmetic (`rtl/rsp/rsp_top.sv`):**
  Replace `pf_n + 2'(pf_rd)` with explicit zero-extension `pf_n + {1'b0, pf_rd}` so Vivado preserves exact 2-bit width.

### 2.2 Forward Signal References (SILENT 1-BIT IMPLICIT WIRES IN `.v`!)
Quartus and Verilator tolerate referencing signals before their declarations. **Vivado elaborates strictly top-down:**
- In `.sv` files with `` `default_nettype none ``, forward references fail with `[VRFC 10-2063]`.
- In `.v` files **without** `` `default_nettype none `` (`rtl/rdp/*.v`), a forward reference **silently creates an implicit 1-bit scalar wire**, truncating multi-bit signals (like 32-bit Z-slope `zdy` or 3-bit copy-mode `m0r..m4r`) with **no synthesis error**!
- **Maintained declaration-order fixes (commits `2d0c619`, `f9c18cd`):**
  - `rtl/rdp/rdp_top.v`: Declare `vgx`, `vde`, `vval`, `zdy`, `cp_m_q`, `px_cnt` before first use.
  - `rtl/rdp/rdp_pix.v`: Declare `m0r..m4r` before first use; fix 4-bit literal truncation in `tc_pow`.
  - `rtl/mips/fpu_n64.sv`: Keep `sel_d`/`sel_w`/`sel_l` declared *before* `fbits_t up; wire cmp_s; assign up = ...`.
  - `rtl/mips/mips_core.sv`: Keep `m_k_ua`, `m_shw2`, `m_shwait` declared before first use.
  - `rtl/soc/afifo.sv`: Declare `rptr`, `rptr_g`, `wptr_g_r1`, `wptr_g_r2` before the write-side block that reads `rptr_g`.
  - `rtl/soc/rcp_ai.sv`: Declare `typedef enum ... st_t; st_t st;` before `wire c_end = st == S_FRD ...`.
  - `rtl/rsp/rsp_vu.sv`: Forward-declare `wire sel0;` before `wire sel_fire = sel0 || sel1;` and use `assign sel0 = ...`.

### 2.3 `always @(*)` Sensitivity & Function Scoping in `xsim` (`2d0c619`)
- Vivado `xsim` does not reliably trigger `always @(*)` when unpacked array elements or indexed bit-slices are read inside `for (integer ...)` loops.
  - **Fix (`rtl/rdp/rdp_top.v`, `rtl/rdp/rdp_pix.v`):** Replaced procedural `integer` bit-slice loops (`aa_cj`, `dzc_p`, `sh_c`, `rk2`, `dz_calc`) with `generate for` + continuous `assign` or explicit `casez` blocks.
- `rtl/rdp/rdp_mem.v`: Pass explicit `(w, w_x0, w_x1)` arguments to `range_sel` rather than relying on outer-scope references inside Verilog functions.

### 2.4 Explicit Unpacked Array Bounds `[0:N-1]` & `automatic` Locals
- Replace C-style unpacked array bounds `[N]` with explicit `[0:N-1]` across RAMs/FIFOs (`fpu_n64.sv`, `mips_core.sv`, `sdr_ctrl_w9825.sv`, `afifo.sv`, `rdp_dpc.sv`, `mips_sys.sv`, `mirlo_regs.sv`, `n64_ports.sv`).
- Mark all block-local variables inside `always_ff` / `always_comb` as `automatic` (`fpu_d64.sv`, `fpu_n64.sv`, `mips_core.sv`).

### 2.5 Verilator 5.024 Compatibility
- Do **not** put default values on module `input` ports (e.g., `input wire gbc_present = 1'b1` in `rtl/soc/mirlo_regs.sv` fails Verilator 5.024).
- Do **not** pass `-Wno-PROCASSINIT` (unsupported in 5.024).

---

## 3. Cyclone V (Quartus) -> Artix-7 (Vivado) Adaptations

### 3.1 Synthesis Attribute Translation
| Upstream Quartus Attribute | Game Bub Vivado Equivalent | Notes |
| :--- | :--- | :--- |
| `(* ramstyle = "MLAB, no_rw_check" *)` | `(* ram_style = "distributed" *)` | LUTRAM (`RAM32M` / `RAM64M`) |
| `(* ramstyle = "M10K, no_rw_check" *)` | `(* ram_style = "block" *)` or `"distributed"` | Use `"distributed"` for <=16-entry tables to preserve BRAM |
| `(* multstyle = "dsp" *)` | `(* use_dsp = "yes" *)` | `DSP48E1` (`rdp_top.v`) |
| *(none on ROMs)* | `(* rom_style = "block" *)` | `mips_sys.sv` `boot`, `rsp_top.sv` `div_rom` |

### 3.2 Altera Megafunctions Replaced for Artix-7
- **`rtl/rsp/rsp_dpram.sv`:** Replaced `altsyncram` with 8× `RAMB18E1` (`4.0` BRAM36 tiles) in true dual-port mode with hardware byte enables (`WEA` / `WEBWE`).
- **`rtl/rsp/rsp_lutram.v`:** Replaced `altdpram` MLAB with 16 independent 8-bit `(* ram_style = "distributed" *)` arrays (`RAM32M`).
- **`rtl/soc/mon_ram.sv`:** Collapsed 4 separate byte-lane M10K arrays into a single `(* ram_style = "block" *) logic [31:0] m [0:511]` (`0.5` BRAM36 tile).
- **`rtl/soc/rcp_si.sv`:** Merged separate CPU and DMA `always @(posedge clk)` write blocks on `m[0:15]` (PIF RAM) into a single write port (`eng_wr || cpu_wr`) on `(* ram_style = "distributed" *)`.

### 3.3 BRAM Collision Guards, Init, & 135-Tile Budget (`123.5 / 135` Used)
- **`rtl/rsp/rsp_top.sv` (`imem`):** Guard Port A fetch with `if (su_run || !iw_we) i_data <= imem[i_addr];` (not `!im_dma`) so `rspboot` keeps fetching instructions while self-DMAing `gspFast3D` / `aspMain` into IMEM without triggering `RAMB36E1` write-read collisions when halted.
- **`rtl/rdp/rdp_tmem.v`:** Keep the TDP collision guard `if (!we || addr_b != addr_a) q_b <= mem[addr_b];`.
- **`rtl/soc/mirlo_regs.sv`:** Keep `` `define CMDQ_AW 11 `` (Pocket uses `12`) to stay within 135 BRAM tiles.
- **Small RAMs -> distributed:** `rcp_si.sv`, `rcp_vi.sv`, `mirlo_regs.sv` (`pad_ram`), `cpu_port.sv` (`wf`), `rsp_su.sv` (`rf_a`/`rf_b`), `mips_core.sv` (`rf_lo`, `bh`, `ras`), `fpu_n64.sv` (`fl0/fl1/fh0/fh1`).
- **`rtl/rdp/rdp_pix.v`:** Keep `sb_ram` (`16 x 68-bit`) as `(* ram_style = "block" *)` with synchronous reset on `sb_wa <= rst ? 4'd0 : (sb_wa + 4'd1);`.
- **Explicit `initial` zeroing:** Keep `initial` loops on `mips_core.sv` caches/`ras`, `rsp_su.sv` `rf_a/b`, `rsp_lutram.v`, `rdp_pix.v` `sb_ram`, `rdp_sdpram.v`, and `rdp_tmem.v` so simulation matches FPGA power-on zeros.
- **FPD64 default (`rtl/soc/mips_sys.sv`):** Game Bub defaults `CPU_FPD64 = 1` (opt-out via `MIRLO_NO_FPD64`); upstream defaults `0`.

### 3.4 Omitted 2 MiB 32-Bit RDP Shadow Plane
Game Bub outputs `RGB666` (`VideoV0(320, 240, 6, 6, 6)`) with Bayer dithering and has a tight Artix-7 BRAM budget. Keep upstream's 32-bit shadow plane (`vi_out32`, `rd_sh`, `wr_sh`, `slb_*`, `dither_off`, `out_sh`, `sh_crc`, `un565sh`) stripped from `rdp_mem.v`, `rdp_pix.v`, `rdp_top.v`, `n64_video.sv`, and `mirlo_regs.sv`.

---

## 4. Game Bub Hardware, Framework, & `n64rt` Gotchas

- **100% SDRAM & SRAM IOB Packing (`6f7d4d7`, `de99058`):**
  - At `125 MHz`, SDRAM DQ/address/control and SRAM address/data/`WE#` **must** pack into `ILOGICE2.IFF` / `OLOGICE2.OUTFF` / `OLOGICE2.TFF` with `SLEW FAST` (`rtl/board/n64_constraints.xdc`).
  - `sram_in_q` in `gb_sram_ctrl.sv` must be a **non-reset** flip-flop with `(* IOB = "TRUE" *)` so Vivado packs all 16 bits into `ILOGICE2.IFF`. Each 16-bit halfword read spans 4 `clk2x` subcycles (`32 ns`) for `+8.96 ns` setup margin over the `10 ns` `IS61WV25616EDBLL-10TLI` `tAA`.
- **Clock Frequency (`lang/mips/include/generated/soc.h`):**
  - `CONFIG_CLOCK_FREQUENCY` is `62500000` (not Pocket's `62832000`).
- **Layout 8 & SRAM PI Bit 25 (`layout.h`, `n64rt_io.c`, `pi2_test.c`):**
  - Any PI engine DMA targeting Game Bub's SRAM (`0x3400_0000 – 0x341F_FFFF`) must set bit 25 (`ps_dst` / `ps_src`) in `PIDST` / `PISRC`.
  - In `n64_soc_gb.sv`, `port_apf` must force `.sel(4'hF)` when servicing `rcp_ai` or `rcp_si` DMA requests (`f9c18cd`).
- **Host Bridge Extensions (`gb_host_bridge.sv`, `mirlo_regs.sv{,h}`, `csr.h`):**
  - Adds `REQUEST_SETSIZE` (`0x0140`) and `REQUEST_FLUSH` (`0x0144`) for `HostV0` save sizing/flushing.
  - Reset values `ia0 <= 32'h0000_0401; ia1 <= 32'h0000_8400;` must match `metadata/settings.json` defaults.
- **Rumble via `InputExtendedV0` (`framework` `v1.1.0-beta5`):**
  - `VibrateV0` was removed in `v1.1.0-beta5`. `N64Core.scala` uses `new InputExtendedV0(numSlots = 4, hasRumble = true)`. `n64rt_pak.c` toggles `INTERACT2` bit 30 (`ia_rumble`), which drives `input_rumble_0_strong = 8'hFF` when `core_running && core_focused`.
- **Transfer Pak 5 V / 3.3 V Hardware Safety (`n64_soc_gb.sv`, `gb_cart.sv`, `n64rt_pak.c`):**
  - All `CartridgePortV0` outputs and level-shifter enables are gated by synchronized `cartridge_switch` (`1` = 5 V DMG/CGB cart seated, `0` = empty or 3.3 V GBA cart). Never enable upstream's Pocket Analogizer `slot_owner()` probe on Game Bub.
- **Uncached SRAM Soft-Restart Snapshot (`n64rt_restart.c`):**
  - Stored at `LAYOUT_RESTART = 0x3416_2000` in uncached SRAM; must be copied with explicit `volatile u32` loops (not `memcpy` / `flush_cpu_dcache`), and must clear rumble bit `0x40000000u` on restart.
- **System-Menu Reset & Controller Boot Race (`1079876`):**
  - Keep `gb_host_bridge.sv` reset/focus gating and `n64rt` boot-time controller readiness behavior intact so titles like *Animal Forest* don't miss Player 1 on cold boot or system-menu Reset.
- **`pi2_test.c` Register-Only Delay Loop:**
  - Inside `pi2_game()` (executed at `0x8000_1000` with `MCTL.GAME=1` while `$sp` is `0x43FF_FFE8`, outside `n64win`), never declare a `volatile` stack loop counter — it traps to `exception_entry` on every iteration and loops forever. Use `for (int i = 0; i < 400; i++) __asm__ volatile("" ::: "memory");` so the counter stays in a register.

---

## 5. Verification Blind Spots to Keep in Mind

Because the current automated regression suite (`sim/gb_n64_soc/run_all.sh`) runs **RTL in Verilator**, it does **not** catch:
1. Vivado synthesis trimming/width bugs (`rsp_vu.sv`, `rsp_top.sv`, `mips_core.sv` `m_ua_mask`).
2. Silent 1-bit implicit wires in `rtl/rdp/*.v`.
3. Xilinx `RAMB18E1` / `RAMB36E1` write-read collision semantics (Verilator executes behavioral arrays under `` `ifdef VERILATOR ``).
4. SDRAM/SRAM IOB packing regressions or BRAM overruns.

When syncing upstream RTL, always audit `build/N64Core-gamebub_rev4/N64Core-gamebub_rev4.runs/synth_1/runme.log` for new `Synth 8-3936`, `Synth 8-6014`, `Synth 8-327`, `VRFC`, or `implicit net` warnings, and verify IOB packing in `impl_1/top_handheld_io_placed.rpt`.
