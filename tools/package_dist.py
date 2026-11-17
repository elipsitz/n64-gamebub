#!/usr/bin/env python3
"""Packages verified Game Bub Rev4 N64 FPGA core deliverables under `dist/`.

Each bundle under `dist/<bundle>/cores/<CoreId>/` is a drop-in SD card directory
containing `core.json`, optional `files.json` & `settings.json`, `<Core>-gamebub_rev4.bit`,
and (for N64Core) `n64rt.sys` + `n64savedb.txt`, plus a `BUILD_MANIFEST.txt` recording
Vivado 2023.2 utilization and timing closure (`WNS`, `TNS`, `WHS`, `THS`, `WPWS`).
"""

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent

BUNDLES = {
    "01-mem-diag": {
        "core_id": "GameBub.N64MemDiag",
        "core_class": "N64MemDiagCore",
        "core_json": "metadata/mem_diag_core.json",
        "files_json": None,
        "settings_json": "metadata/mem_diag_settings.json",
        "with_runtime": False,
    },
    "02-mips-self-test": {
        "core_id": "GameBub.N64SelfTest",
        "core_class": "N64SelfTestCore",
        "core_json": "metadata/self_test_core.json",
        "files_json": None,
        "settings_json": None,
        "with_runtime": False,
    },
    "03-n64-core": {
        "core_id": "GameBub.N64",
        "core_class": "N64Core",
        "core_json": "metadata/core.json",
        "files_json": "metadata/files.json",
        "settings_json": "metadata/settings.json",
        "with_runtime": True,
    },
    "04-n64-polished": {
        "core_id": "GameBub.N64",
        "core_class": "N64Core",
        "core_json": "metadata/core.json",
        "files_json": "metadata/files.json",
        "settings_json": "metadata/settings.json",
        "with_runtime": True,
    },
    "05-n64-64mb-ondemand": {
        "core_id": "GameBub.N64",
        "core_class": "N64Core",
        "core_json": "metadata/core.json",
        "files_json": "metadata/files_ondemand.json",
        "settings_json": "metadata/settings.json",
        "with_runtime": True,
    },
}


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
    new_raw = re.sub(rb";GitRev=[0-9a-fA-F]{12}", b";GitRev=" + git_rev.encode("ascii"), bytes(raw), count=1)
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


def package_one(bundle_name: str) -> None:
    cfg = BUNDLES[bundle_name]
    core_class = cfg["core_class"]
    target = "gamebub_rev4"
    bit_name = f"{core_class}-{target}.bit"
    build_dir = ROOT / "build" / f"{core_class}-{target}"
    src_bit = build_dir / bit_name
    if not src_bit.exists():
        raise SystemExit(f"Missing built bitstream: {src_bit}")

    out_root = ROOT / "dist" / bundle_name
    core_dir = out_root / "cores" / cfg["core_id"]
    if out_root.exists():
        shutil.rmtree(out_root)
    core_dir.mkdir(parents=True, exist_ok=True)

    git_rev = subprocess.check_output(["git", "rev-parse", "--short=12", "HEAD"], cwd=ROOT, text=True).strip()
    dst_bit = core_dir / bit_name
    shutil.copy2(src_bit, dst_bit)
    refresh_bitstream_gitrev(dst_bit, git_rev)

    shutil.copy2(ROOT / cfg["core_json"], core_dir / "core.json")
    if cfg["files_json"]:
        shutil.copy2(ROOT / cfg["files_json"], core_dir / "files.json")
    if cfg["settings_json"]:
        shutil.copy2(ROOT / cfg["settings_json"], core_dir / "settings.json")
    if cfg["with_runtime"]:
        rt_bin = ROOT / "lang" / "n64rt" / "build" / "n64rt.bin"
        if not rt_bin.exists():
            raise SystemExit(f"Missing built runtime binary: {rt_bin}")
        shutil.copy2(rt_bin, core_dir / "n64rt.sys")
        shutil.copy2(ROOT / "assets" / "n64savedb.txt", core_dir / "n64savedb.txt")

    metrics = extract_vivado_metrics(build_dir)

    lines = [
        f"Bundle:      {bundle_name}",
        f"Core ID:     {cfg['core_id']}",
        f"Core Class:  {core_class}",
        f"Target:      {target} (XC7A100TCSG324-1)",
        f"Git Rev:     {git_rev}",
        "",
        "=== Vivado 2023.2 Post-Route Utilization & Timing ===",
    ]
    for k, v in metrics.items():
        lines.append(f"  {k:16s}: {v}")
    lines.append("")
    lines.append("=== Packaged Files ===")
    for p in sorted(core_dir.iterdir()):
        lines.append(f"  {p.name:38s}  {p.stat().st_size:9d} B  sha256:{sha256_short(p)}")

    manifest = out_root / "BUILD_MANIFEST.txt"
    manifest.write_text("\n".join(lines) + "\n")
    print(f"[OK] Packaged {bundle_name} -> {core_dir} (WNS={metrics.get('WNS_ns', '?')} ns)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", default="n64", choices=["all", "n64", *BUNDLES.keys()])
    args = parser.parse_args()
    if args.bundle == "all":
        targets = list(BUNDLES.keys())
    elif args.bundle == "n64":
        targets = [k for k, v in BUNDLES.items() if v["core_class"] == "N64Core"]
    else:
        targets = [args.bundle]
    for b in targets:
        package_one(b)


if __name__ == "__main__":
    main()
