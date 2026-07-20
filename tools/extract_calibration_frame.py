#!/usr/bin/env python3
"""Extract one frame from a video for VisionPilot homography calibration."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract a calibration frame from input.mp4.")
    parser.add_argument("video", type=Path, help="Video file to read.")
    parser.add_argument("output", type=Path, help="Output image path, usually frame.jpg.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--frame", type=int, default=0, help="Zero-based frame index. Default: 0.")
    group.add_argument("--time", type=float, help="Timestamp in seconds.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        import cv2  # type: ignore
    except Exception as exc:
        print(f"error: OpenCV Python is required: {exc}", file=sys.stderr)
        return 1

    video = args.video.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if not video.is_file():
        print(f"error: video not found: {video}", file=sys.stderr)
        return 1

    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        print(f"error: cannot open video: {video}", file=sys.stderr)
        return 1

    if args.time is not None:
        cap.set(cv2.CAP_PROP_POS_MSEC, max(0.0, args.time) * 1000.0)
    else:
        cap.set(cv2.CAP_PROP_POS_FRAMES, max(0, args.frame))

    ok, frame = cap.read()
    cap.release()
    if not ok or frame is None:
        print("error: could not read requested frame", file=sys.stderr)
        return 1

    output.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(output), frame):
        print(f"error: failed to write image: {output}", file=sys.stderr)
        return 1

    print(f"wrote: {output}")
    print(f"size:  {frame.shape[1]}x{frame.shape[0]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
