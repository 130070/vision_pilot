#!/usr/bin/env python3
"""Generate VisionPilot H.yaml from four image points and simple road geometry."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Iterable


def parse_point(text: str) -> tuple[float, float]:
    try:
        x, y = text.split(",", 1)
        return float(x), float(y)
    except Exception as exc:
        raise argparse.ArgumentTypeError(f"expected POINT as x,y, got {text!r}") from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Create H.yaml mapping raw image pixels to road coordinates. "
            "Image point order: near-left near-right far-left far-right."
        )
    )
    parser.add_argument(
        "--image-point",
        action="append",
        type=parse_point,
        required=True,
        metavar="X,Y",
        help="Image point in pixels. Provide exactly four values.",
    )
    parser.add_argument("--output", type=Path, required=True, help="Output H.yaml path.")
    parser.add_argument("--lane-width", type=float, default=3.6, help="Lane width in meters. Default: 3.6.")
    parser.add_argument("--near-distance", type=float, default=6.0, help="Near reference distance in meters. Default: 6.0.")
    parser.add_argument("--far-distance", type=float, default=30.0, help="Far reference distance in meters. Default: 30.0.")
    parser.add_argument("--preview-image", type=Path, help="Optional calibration frame for drawing a point preview.")
    parser.add_argument("--preview-output", type=Path, help="Optional output image with point labels.")
    return parser.parse_args()


def format_yaml(matrix: Iterable[Iterable[float]]) -> str:
    values = [float(v) for row in matrix for v in row]
    rows = []
    for i in range(0, 9, 3):
        rows.append("          " + ", ".join(f"{v:.15e}" for v in values[i:i + 3]))
    data = ",\n".join(rows)
    return (
        "%YAML:1.0\n"
        "---\n"
        "# Camera homography transform matrix\n"
        "# Maps raw image pixels to road coordinates: x=forward meters, y=left meters.\n"
        "H: !!opencv-matrix\n"
        "  rows: 3\n"
        "  cols: 3\n"
        "  dt: d\n"
        "  data: [ " + data.lstrip() + " ]\n"
    )


def main() -> int:
    args = parse_args()
    if len(args.image_point) != 4:
        print("error: provide exactly four --image-point values", file=sys.stderr)
        return 1
    if args.near_distance <= 0 or args.far_distance <= args.near_distance:
        print("error: require 0 < near-distance < far-distance", file=sys.stderr)
        return 1
    if args.lane_width <= 0:
        print("error: lane-width must be positive", file=sys.stderr)
        return 1

    try:
        import cv2  # type: ignore
        import numpy as np  # type: ignore
    except Exception as exc:
        print(f"error: OpenCV and NumPy are required: {exc}", file=sys.stderr)
        return 1

    half_width = args.lane_width / 2.0
    image_points = np.array(args.image_point, dtype=np.float32)
    world_points = np.array([
        [args.near_distance, +half_width],
        [args.near_distance, -half_width],
        [args.far_distance, +half_width],
        [args.far_distance, -half_width],
    ], dtype=np.float32)

    H, mask = cv2.findHomography(image_points, world_points, method=0)
    if H is None:
        print("error: cv2.findHomography failed", file=sys.stderr)
        return 1

    output = args.output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(format_yaml(H))
    print(f"wrote: {output}")
    print("image point order: near-left, near-right, far-left, far-right")
    print(f"road model: lane_width={args.lane_width:.3f}m near={args.near_distance:.3f}m far={args.far_distance:.3f}m")

    if args.preview_image or args.preview_output:
        if not (args.preview_image and args.preview_output):
            print("error: --preview-image and --preview-output must be used together", file=sys.stderr)
            return 1
        image = cv2.imread(str(args.preview_image.expanduser().resolve()))
        if image is None:
            print(f"error: cannot read preview image: {args.preview_image}", file=sys.stderr)
            return 1
        labels = ["near-left", "near-right", "far-left", "far-right"]
        for label, (x, y) in zip(labels, args.image_point):
            pt = (int(round(x)), int(round(y)))
            cv2.circle(image, pt, 8, (0, 255, 255), -1)
            cv2.putText(image, label, (pt[0] + 10, pt[1] - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)
        preview = args.preview_output.expanduser().resolve()
        preview.parent.mkdir(parents=True, exist_ok=True)
        if not cv2.imwrite(str(preview), image):
            print(f"error: failed to write preview: {preview}", file=sys.stderr)
            return 1
        print(f"preview: {preview}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
