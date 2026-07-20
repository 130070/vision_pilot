#!/usr/bin/env python3
"""Prepare a VisionPilot video dataset directory from a custom video."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create input.mp4 and frame_speed.txt for a custom VisionPilot video."
    )
    parser.add_argument("video", type=Path, help="Source video path.")
    parser.add_argument("output_dir", type=Path, help="Dataset directory to create/update.")
    parser.add_argument(
        "--speed",
        type=float,
        default=0.0,
        help="Constant ego speed in m/s written for every frame. Default: 0.0.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing input.mp4 and frame_speed.txt.",
    )
    return parser.parse_args()


def count_frames_with_cv2(video: Path) -> int | None:
    try:
        import cv2  # type: ignore
    except Exception:
        return None

    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        return None
    count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    cap.release()
    return count if count > 0 else None


def count_frames_with_ffprobe(video: Path) -> int | None:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-count_frames",
        "-show_entries",
        "stream=nb_read_frames",
        "-of",
        "default=nokey=1:noprint_wrappers=1",
        str(video),
    ]
    try:
        out = subprocess.check_output(cmd, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    try:
        value = int(out.splitlines()[-1])
    except (ValueError, IndexError):
        return None
    return value if value > 0 else None


def main() -> int:
    args = parse_args()
    video = args.video.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()

    if not video.is_file():
        print(f"error: source video not found: {video}", file=sys.stderr)
        return 1

    output_dir.mkdir(parents=True, exist_ok=True)
    target_video = output_dir / "input.mp4"
    target_speed = output_dir / "frame_speed.txt"

    if not args.overwrite:
        existing = [p for p in (target_video, target_speed) if p.exists()]
        if existing:
            names = ", ".join(str(p) for p in existing)
            print(f"error: output exists; use --overwrite to replace: {names}", file=sys.stderr)
            return 1

    if video.suffix.lower() == ".mp4":
        shutil.copy2(video, target_video)
    else:
        if shutil.which("ffmpeg") is None:
            print("error: non-mp4 input requires ffmpeg on PATH", file=sys.stderr)
            return 1
        subprocess.check_call([
            "ffmpeg", "-y", "-i", str(video),
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", str(target_video),
        ])

    frame_count = count_frames_with_cv2(target_video) or count_frames_with_ffprobe(target_video)
    if not frame_count:
        print("error: could not determine frame count", file=sys.stderr)
        return 1

    target_speed.write_text("".join(f"{args.speed:.6f}\n" for _ in range(frame_count)))

    print(f"dataset: {output_dir}")
    print(f"video:   {target_video}")
    print(f"speed:   {target_speed} ({frame_count} frames at {args.speed:.3f} m/s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
