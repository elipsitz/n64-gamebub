#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERILATOR="${VERILATOR:-verilator}"
BUILD_DIR="${BUILD_DIR:-/tmp/gb_n64_soc_sim}"
mkdir -p "$BUILD_DIR"

echo "=== [1/3] Building guest N64 test ROMs (.z64, .v64, .n64, and 64 MiB .z64) ==="
mips-linux-gnu-gcc -EB -march=vr4300 -mabi=32 -mno-abicalls -fno-pic -G0 \
    -ffreestanding -O2 -Wall -Wextra \
    -c sim/gb_n64_soc/n64_guest_rom.c -o "$BUILD_DIR/n64_guest_rom.o"
mips-linux-gnu-ld -EB -T lang/n64rt/test/layout_game.ld --gc-sections \
    -o "$BUILD_DIR/n64_guest_rom.elf" "$BUILD_DIR/n64_guest_rom.o"
mips-linux-gnu-objcopy -O binary "$BUILD_DIR/n64_guest_rom.elf" "$BUILD_DIR/n64_guest_rom.bin"
python3 sim/gb_n64_soc/make_test_rom.py "$BUILD_DIR/n64_guest_rom.bin" "$BUILD_DIR/guest_rom" --with-64mb

COMMON_RTL=(
    rtl/board/n64_mmcm.sv
    rtl/mem/sdr_ctrl_w9825.sv
    rtl/mem/sdr_arb_gb.sv
    rtl/mem/sdr_phy_x7.sv
    rtl/mem/gb_sram_ctrl.sv
    rtl/mem/pi_rom_cache.sv
)

N64_RTL=(
    "${COMMON_RTL[@]}"
    rtl/board/n64_gamebub_top.sv
    rtl/bridge/gb_host_bridge.sv
    rtl/video_gb/n64_video_gb_downsampler.sv
    rtl/mips/fpu_d64.sv
    rtl/mips/fpu_n64.sv
    rtl/mips/mips_core.sv
    rtl/rsp/rsp_dpram.sv
    rtl/rsp/rsp_lutram.v
    rtl/rsp/rsp_su.sv
    rtl/rsp/rsp_vu.sv
    rtl/rsp/rsp_top.sv
    rtl/rdp/rdp_dpc.sv
    rtl/rdp/rdp_mem.v
    rtl/rdp/rdp_pix.v
    rtl/rdp/rdp_rcp_rom.v
    rtl/rdp/rdp_sdpram.v
    rtl/rdp/rdp_tmem.v
    rtl/rdp/rdp_top.v
    rtl/soc/afifo.sv
    rtl/soc/cpu_port.sv
    rtl/soc/fifo_fwft.sv
    rtl/soc/gb_cart.sv
    rtl/soc/mips_sys.sv
    rtl/soc/mirlo_regs.sv
    rtl/soc/mon_ram.sv
    rtl/soc/n64_ports.sv
    rtl/soc/n64_video.sv
    rtl/soc/rcp_ai.sv
    rtl/soc/rcp_dpc_view.sv
    rtl/soc/rcp_mi.sv
    rtl/soc/rcp_si.sv
    rtl/soc/rcp_vi.sv
    rtl/soc/n64_soc_gb.sv
    sim/gb_n64_soc/gb_cart_model_gb.sv
    sim/gb_n64_soc/gb_soc_tb_top.sv
)

VFLAGS=(
    --cc --exe --build -j 8
    -O3 --x-assign 0 --x-initial 0
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST
    -Irtl/soc -Irtl/rsp -Irtl/rdp -Irtl/mips
    -CFLAGS "-O3 -std=c++17"
    --top-module gb_soc_tb_top
)

cp -f rtl/rsp/rsp_div_rom.hex .

echo "=== [2/3] Building N64Core Full-SoC Simulator & Running Hardware Regression Suite ==="
"$VERILATOR" "${VFLAGS[@]}" --Mdir "$BUILD_DIR/obj_n64" \
    "${N64_RTL[@]}" "$ROOT/sim/gb_n64_soc/tb_gb_soc.cpp" -o tb_n64

for t in cpu_test int64_test ddiv64_test ualn_test fr1_test fpu_d64_test tlbram_test dma_coh_test mi_test pi2_test vi_test ai_test si_test; do
    "$BUILD_DIR/obj_n64/tb_n64" --mode mipstest --file "lang/mips/test/build/${t}.bin"
done

echo "=== [3/3] Verifying Commercial N64 Boot (.z64/.v64/.n64), .sav/.mpk, Rumble, Transfer Pak, Soft Restart, & 64 MiB On-Demand Paging ==="
"$BUILD_DIR/obj_n64/tb_n64" --mode n64rom     --file "$BUILD_DIR/guest_rom.z64" --pak 1 --test-restart
"$BUILD_DIR/obj_n64/tb_n64" --mode n64rom     --file "$BUILD_DIR/guest_rom.v64" --pak 2
"$BUILD_DIR/obj_n64/tb_n64" --mode n64rom     --file "$BUILD_DIR/guest_rom.n64" --pak 1
"$BUILD_DIR/obj_n64/tb_n64" --mode n64rom     --file "$BUILD_DIR/guest_rom.z64" --pak 9 --cart-switch 0
"$BUILD_DIR/obj_n64/tb_n64" --mode n64rom     --file "$BUILD_DIR/guest_rom.z64" --pak 9 --cart-switch 1 --test-restart
"$BUILD_DIR/obj_n64/tb_n64" --mode ondemand64 --file "$BUILD_DIR/guest_rom_64m.z64" --pak 1

rm -f rsp_div_rom.hex
echo "=== ALL FULL-SOC VERILATOR SUITES PASSED ==="
