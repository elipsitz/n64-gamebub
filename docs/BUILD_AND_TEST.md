# Building, Testing, & Packaging

## 1. Prerequisites

- **Submodules:** `framework/` (`gamebub/framework`), `vendor/pythondata-software-picolibc`, and `vendor/pythondata-software-compiler_rt`
- **MIPS cross-toolchain (`mirlo64-tools` Docker image):** `gcc-mips-linux-gnu`, `binutils-mips-linux-gnu`, `meson`, `ninja-build`, `make`
- **Verilator `5.024+`:** Used for RTL unit & full-SoC regression tests
- **Vivado `2023.2` + Mill:** Required for Chisel generation (`chisel/src/N64Core.scala`) and Artix-7 bitstream synthesis/place-and-route (`N64Core-gamebub_rev4.bit`)

---

## 2. Building `n64rt.sys` & MIPS Hardware Tests

```bash
git submodule update --init --recursive
docker build -t mirlo64-tools tools/docker

# Build picolibc, compiler_rt, and libmirlo for the VR4300 runtime
tools/docker/run.sh make -C lang/mips -f lib.mk VARIANT=game

# Build lang/n64rt/build/n64rt.bin (packaged as n64rt.sys)
tools/docker/run.sh make -C lang/n64rt clean all

# Build MIPS hardware test binaries (lang/mips/test/build/*.bin)
tools/docker/run.sh make -C lang/mips/test
```

> **Note:** On Apple Silicon macOS hosts, you can run MIPS GCC builds inside `mirlo64-tools` (`--platform linux/amd64`) and run Verilator natively via Homebrew (`/opt/homebrew/bin/verilator`, ARM64 `5.024+`) for much faster simulation.

---

## 3. Running Verilator Verification Suites

### Unit Benches
```bash
# Dual-rank W9825G6KH-6 SDRAM AC timing + 10 ns SRAM tAA + L1/L2 ROM cache
bash sim/mem/run_test.sh

# HostV0 bridge, settings/interact, pad/rumble InputExtendedV0 gating, save flush
bash sim/bridge/run_test.sh

# VI + 320x240 RGB666 downsampler, weave de-interlacing, Bayer dithering
bash sim/video_gb/run_sim.sh
```

### Full-SoC Hardware & Commercial Boot Regression
```bash
bash sim/gb_n64_soc/run_all.sh
```
This runs:
- **13 MIPS hardware tests:** `cpu_test`, `int64_test`, `ddiv64_test`, `ualn_test`, `fr1_test`, `fpu_d64_test`, `tlbram_test`, `dma_coh_test`, `mi_test`, `pi2_test`, `vi_test`, `ai_test`, `si_test`
- **6 commercial N64 boot flows:**
  1. `.z64` + Controller Pak + double soft restart / system-menu reset
  2. `.v64` byteswap + Rumble Pak motor actuation
  3. `.n64` word-swap boot
  4. Transfer Pak with empty/GBA slot (`cart-switch 0` isolation)
  5. Transfer Pak with physical MBC3 cart (`cart-switch 1`) + restart
  6. `64 MiB` on-demand ROM paging (`ondemand64`)

> **Important limitation:** All suites above run **RTL in Verilator**, which does **not** catch Vivado 2023.2 synthesis mis-optimizations (see [`docs/PORTING_NOTES.md`](PORTING_NOTES.md#2-vivado-20232--xsim-synthesis-bugs--fixes)). Always inspect Vivado synthesis/implementation reports after RTL changes.

---

## 4. Building the Bitstream (Vivado 2023.2)

```bash
./mill root.buildCore --target gamebub_rev4
```

Output lands in `build/N64Core-gamebub_rev4/N64Core-gamebub_rev4.bit`. Before releasing, verify in `build/N64Core-gamebub_rev4/N64Core-gamebub_rev4.runs/`:
- `synth_1/runme.log`: `0` Errors, `0` Critical Warnings, no new `implicit net` / `VRFC` / inferred-latch (`Synth 8-327`) warnings, no unexpected `Synth 8-3936` / `Synth 8-6014` register trimming.
- `impl_1/top_handheld_timing_summary_routed.rpt`: `WNS > 0`, `TNS = 0.000 ns`, `WHS > 0`, `THS = 0.000 ns`.
- `impl_1/top_handheld_utilization_placed.rpt`: `Block RAM Tile <= 135`.
- `impl_1/top_handheld_io_placed.rpt`: 100% IOB packing and `SLEW FAST` on all `sdram_*` and `sram_*` pins.
- `impl_1/top_handheld_drc_routed.rpt`: `0` DRC errors.

---

## 5. Packaging & Validating the Release `.zip`

Commit all changes first (so the embedded `;GitRev=<sha>` in the `.bit` header matches `HEAD`), then run:

```bash
python3 tools/package_dist.py
```

This stages `dist/elipsitz.N64/` and writes a single release archive `dist/elipsitz.N64-v<version>.zip` containing:
- `elipsitz.N64/N64Core-gamebub_rev4.bit` (with `;GitRev=<sha>` stamped in the header)
- `elipsitz.N64/core.json`
- `elipsitz.N64/files.json`
- `elipsitz.N64/settings.json`
- `elipsitz.N64/n64rt.sys`
- `elipsitz.N64/n64savedb.txt`

If you have the Game Bub `core-directory` repo checked out locally, validate the `.zip` against strict schema rules (`allow_legacy=False`) before uploading:
```bash
python3 -c '
import sys; sys.path.insert(0, "/path/to/core-directory/scripts"); import sync
meta, warns = sync.inspect_zip_bytes(open("dist/elipsitz.N64-v0.3.0.zip", "rb").read(), allow_legacy=False)
assert not warns, warns
print("OK:", meta)
'
```
