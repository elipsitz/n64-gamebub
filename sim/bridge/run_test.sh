#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/build"

rm -rf "$BUILD"
${VERILATOR:-verilator} --cc -sv -Wall -Wno-DECLFILENAME \
    --Mdir "$BUILD" \
    --top-module gb_host_bridge \
    --exe "$HERE/tb_bridge.cpp" \
    --build -j 4 \
    "$ROOT/rtl/bridge/gb_host_bridge.sv"

"$BUILD/Vgb_host_bridge"
