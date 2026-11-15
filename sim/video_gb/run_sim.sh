#!/bin/bash
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$HERE/../.." && pwd)"
OBJ="${OBJ:-$HERE/obj_video_gb}"
V="${VERILATOR:-verilator}"

"$V" --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    --top-module video_gb_tb_top -Mdir "$OBJ" \
    "$R/rtl/soc/afifo.sv" \
    "$R/rtl/soc/n64_video.sv" \
    "$R/rtl/video_gb/n64_video_gb_downsampler.sv" \
    "$HERE/video_gb_tb_top.sv" \
    "$HERE/tb_video_gb.cpp" \
    -CFLAGS "-O2" -o tb_video_gb > "$OBJ.log" 2>&1 || { cat "$OBJ.log"; exit 1; }

"$OBJ/tb_video_gb"
