#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OBJ_DIR="${OBJ_DIR:-/tmp/mem_tb_obj}"

echo "[1/2] Compiling RTL + C++ testbench with Verilator..."
verilator --cc --exe --build -j 4 \
    -Wall -Wno-DECLFILENAME -Wno-PROCASSINIT \
    --Mdir "${OBJ_DIR}" \
    --top-module mem_tb_top \
    -CFLAGS "-O2 -std=c++17" \
    "${REPO_ROOT}/rtl/mem/sdr_arb_gb.sv" \
    "${REPO_ROOT}/rtl/mem/sdr_ctrl_w9825.sv" \
    "${REPO_ROOT}/rtl/mem/sdr_phy_x7.sv" \
    "${REPO_ROOT}/rtl/mem/gb_sram_ctrl.sv" \
    "${REPO_ROOT}/rtl/mem/pi_rom_cache.sv" \
    "${SCRIPT_DIR}/mem_tb_top.sv" \
    "${SCRIPT_DIR}/tb_mem.cpp"

echo "[2/2] Running Verilator memory subsystem testbench..."
"${OBJ_DIR}/Vmem_tb_top"
