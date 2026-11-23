#!/usr/bin/env python3
"""Packages the Game Bub Rev4 N64 FPGA core (`elipsitz.N64`) as a release .zip.

Creates `dist/<core_id>-v<version>.zip` containing a single top-level `<core_id>/`
directory (`elipsitz.N64/`) with `core.json`, `files.json`, `settings.json`,
`N64Core-gamebub_rev4.bit`, `n64rt.sys`, and `n64savedb.txt`.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def extract_vivado_metrics(build_dir: Path) -> dict[str, str]:
    metrics: dict[str, str] = {}
    impl_dirs = list(build_dir.glob("*.runs/impl_1"))
    if not impl_dirs:
        return metrics
    impl = impl_dirs[0]

    for util_rpt in impl.glob("*_utilization_placed.rpt"):
        txt = util_rpt.read_text(errors="replace")
        for label, key in [
            ("Slice LUTs", "slice_luts"),
            ("Slice Registers", "slice_regs"),
            ("Block RAM Tile", "bram36"),
            ("RAMB36/FIFO*", "ramb36_exact"),
            ("RAMB18", "ramb18"),
            ("DSPs", "dsps"),
        ]:
            m = re.search(
                rf"\|\s*{re.escape(label)}\s*\|\s*([0-9.]+)\s*\|\s*[0-9.]+\s*\|\s*[0-9.]+\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)",
                txt,
            )
            if m:
                metrics[key] = f"{m.group(1)} / {m.group(2)} ({m.group(3)}%)"

    for tim_rpt in impl.glob("*_timing_summary_routed.rpt"):
        txt = tim_rpt.read_text(errors="replace")
        m = re.search(
            r"WNS\(ns\)\s+TNS\(ns\).*?\n\s*-+\s+-+.*?\n\s*([-0-9.]+)\s+([-0-9.]+)\s+\d+\s+\d+\s+([-0-9.]+)\s+([-0-9.]+)\s+\d+\s+\d+\s+([-0-9.]+)",
            txt,
        )
        if m:
            wns, tns, whs, ths, wpws = m.groups()
            metrics["WNS_ns"] = wns
            metrics["TNS_ns"] = tns
            metrics["WHS_ns"] = whs
            metrics["THS_ns"] = ths
            metrics["WPWS_ns"] = wpws
            if float(wns) < 0.0 or float(whs) < 0.0 or float(wpws) < 0.0:
                raise SystemExit(
                    f"TIMING CLOSURE FAILED in {tim_rpt}: WNS={wns} ns, WHS={whs} ns, WPWS={wpws} ns"
                )
    return metrics


def sha256_short(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()[:16]


def refresh_bitstream_gitrev(bit_path: Path, git_rev: str) -> None:
    raw = bytearray(bit_path.read_bytes())
    new_raw = re.sub(
        rb";GitRev=[0-9a-fA-F]{12}",
        b";GitRev=" + git_rev.encode("ascii"),
        bytes(raw),
        count=1,
    )
    if len(new_raw) == len(raw) and new_raw != bytes(raw):
        bit_path.write_bytes(new_raw)
        return
    if b";GitRev=" not in raw:
        header = b"\x00\x09\x0f\xf0\x0f\xf0\x0f\xf0\x0f\xf0\x00\x00\x01a"
        if bytes(raw[: len(header)]) == header:
            idx = len(header)
            tag_len = int.from_bytes(raw[idx : idx + 2], "big")
            if tag_len >= 1:
                tag = bytes(raw[idx + 2 : idx + 2 + tag_len])
                new_tag = tag[:-1] + f";GitRev={git_rev}".encode("ascii") + b"\x00"
                raw[idx + 2 : idx + 2 + tag_len] = new_tag
                raw[idx : idx + 2] = len(new_tag).to_bytes(2, "big")
                bit_path.write_bytes(bytes(raw))


def main() -> None:
    parser = argparse.ArgumentParser(description="Package elipsitz.N64 release zip.")
    parser.add_argument(
        "--build-dir",
        type=Path,
        default=ROOT / "build" / "N64Core-gamebub_rev4",
        help="Path to the Vivado N64Core-gamebub_rev4 build directory",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output .zip path (defaults to dist/<id>-v<version>.zip)",
    )
    args = parser.parse_args()

    core_json_path = ROOT / "metadata" / "core.json"
    core_meta = json.loads(core_json_path.read_text(encoding="utf-8"))
    core_id = core_meta["metadata"]["id"]
    version = core_meta["metadata"]["version"]
    bit_name = core_meta["bitstreams"][0]["filename"]

    src_bit = args.build_dir / bit_name
    if not src_bit.exists():
        raise SystemExit(f"Missing built bitstream: {src_bit}")

    rt_bin = ROOT / "lang" / "n64rt" / "build" / "n64rt.bin"
    if not rt_bin.exists():
        raise SystemExit(f"Missing built runtime binary: {rt_bin}")

    metrics = extract_vivado_metrics(args.build_dir)

    dist_dir = ROOT / "dist"
    stage_dir = dist_dir / core_id
    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    stage_dir.mkdir(parents=True, exist_ok=True)

    git_rev = subprocess.check_output(
        ["git", "rev-parse", "--short=12", "HEAD"], cwd=ROOT, text=True
    ).strip()

    dst_bit = stage_dir / bit_name
    shutil.copy2(src_bit, dst_bit)
    refresh_bitstream_gitrev(dst_bit, git_rev)

    shutil.copy2(core_json_path, stage_dir / "core.json")
    shutil.copy2(ROOT / "metadata" / "files.json", stage_dir / "files.json")
    shutil.copy2(ROOT / "metadata" / "settings.json", stage_dir / "settings.json")
    shutil.copy2(rt_bin, stage_dir / "n64rt.sys")
    shutil.copy2(ROOT / "assets" / "n64savedb.txt", stage_dir / "n64savedb.txt")

    zip_path = args.output or (dist_dir / f"{core_id}-v{version}.zip")
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    if zip_path.exists():
        zip_path.unlink()

    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for p in sorted(stage_dir.iterdir()):
            zf.write(p, arcname=f"{core_id}/{p.name}")

    print(f"[OK] Packaged {core_id} v{version} (git {git_rev}) -> {zip_path}")
    if metrics:
        print("=== Vivado 2023.2 Post-Route Utilization & Timing ===")
        for k, v in metrics.items():
            print(f"  {k:16s}: {v}")
    print("=== Packaged Files ===")
    for p in sorted(stage_dir.iterdir()):
        print(f"  {core_id}/{p.name:30s}  {p.stat().st_size:9d} B  sha256:{sha256_short(p)}")


if __name__ == "__main__":
    main()
