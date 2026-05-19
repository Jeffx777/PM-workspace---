#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pipeline.py — SingleFile 一键处理流水线

用法:
  python pipeline.py <source.html> [output_dir] [--purge-css]

输出:
  <output_dir>/reviewable/index.html  ← 给模型使用（体积小，不含 base64 资产）
  <output_dir>/demo_final.html        ← 交付文件（完整自包含，可离线双击）
"""
import sys, subprocess
from pathlib import Path


def run_step(cmd: list, desc: str) -> int:
    print(f"\n[PIPELINE] {desc}", flush=True)
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"[PIPELINE] FAILED: {desc}")
    return result.returncode


def main():
    import argparse
    parser = argparse.ArgumentParser(description="SingleFile 一键流水线")
    parser.add_argument("input", help="SingleFile HTML 路径")
    parser.add_argument("output_dir", nargs="?", help="输出目录（默认: <input>_pipeline）")
    parser.add_argument("--purge-css", action="store_true",
                        help="启用 CSS 清洗（默认关闭，B端后台有动态类名时慎用）")
    args = parser.parse_args()

    script_dir = Path(__file__).parent
    forge = script_dir / "sf-forge.py"
    checker = script_dir / "check-singlefile-prototype.py"

    input_path = Path(args.input).resolve()
    if not input_path.exists():
        print(f"[ERROR] 文件不存在: {input_path}")
        sys.exit(1)

    out_dir = (Path(args.output_dir).resolve() if args.output_dir
               else input_path.parent / f"{input_path.stem}_pipeline")
    reviewable = out_dir / "reviewable" / "index.html"
    demo_final = out_dir / "demo_final.html"

    # Step 1: Extract — 去肥瘦身，产出给模型用的轻量 HTML
    if run_step(
        [sys.executable, "-X", "utf8", str(forge), "extract", str(input_path), str(out_dir)],
        "Extract 去肥瘦身"
    ) != 0:
        sys.exit(1)

    # Step 2: Build — 重新内联资产，产出自包含交付文件
    build_cmd = [sys.executable, "-X", "utf8", str(forge), "build",
                 str(reviewable), str(demo_final)]
    if args.purge_css:
        build_cmd.append("--purge-css")
    if run_step(build_cmd, f"Build 重装{'＋CSS清洗' if args.purge_css else ''}") != 0:
        sys.exit(1)

    # Step 3: Quality Check — 结构质检，非阻断（只报告）
    if checker.exists():
        print(f"\n[PIPELINE] Quality Check")
        if subprocess.run([sys.executable, "-X", "utf8", str(checker), str(demo_final)]).returncode != 0:
            sys.exit(1)

    # Summary
    reviewable_kb = reviewable.stat().st_size // 1024 if reviewable.exists() else 0
    demo_kb = demo_final.stat().st_size // 1024 if demo_final.exists() else 0
    print(f"\n{'='*55}")
    print(f"[PIPELINE] 完成")
    print(f"  给模型  : {reviewable}")
    print(f"           ({reviewable_kb} KB — 喂给模型用这个)")
    print(f"  交付文件: {demo_final}")
    print(f"           ({demo_kb} KB — 发给别人用这个)")
    print(f"{'='*55}")


if __name__ == "__main__":
    main()
