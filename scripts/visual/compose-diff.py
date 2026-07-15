#!/usr/bin/env python3
"""Create an unmasked 50% overlay, heatmap, and visual-difference metrics."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import re
import sys

try:
    from PIL import Image, ImageChops
except ImportError as exc:
    raise SystemExit(
        "compose-diff.py requires Pillow. Install it with: python3 -m pip install Pillow"
    ) from exc

from pixel_acceptance import analyze_images, flatten_on_white, maximum_channel_image


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare full app and reference PNGs without masking any UI pixels."
    )
    parser.add_argument("--reference", required=True, type=pathlib.Path)
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    parser.add_argument("--label", default="comparison")
    parser.add_argument(
        "--threshold",
        type=int,
        default=8,
        help="A pixel is changed when any RGB channel difference exceeds this value. Default: 8.",
    )
    return parser.parse_args()


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def heatmap(magnitude: Image.Image) -> Image.Image:
    red = magnitude.point(lambda value: min(255, value * 4))
    green = magnitude.point(lambda value: max(0, min(255, (value - 24) * 4)))
    blue = magnitude.point(lambda value: max(0, min(255, (value - 96) * 3)))
    return Image.merge("RGB", (red, green, blue))


def safe_label(raw_label: str) -> str:
    label = re.sub(r"[^A-Za-z0-9._-]+", "-", raw_label).strip("-.")
    if not label:
        raise SystemExit("--label must contain at least one filename-safe character")
    return label


def main() -> int:
    arguments = parse_arguments()
    if not 0 <= arguments.threshold <= 255:
        raise SystemExit("--threshold must be from 0 through 255")
    label = safe_label(arguments.label)

    reference = flatten_on_white(Image.open(arguments.reference))
    app = flatten_on_white(Image.open(arguments.app))
    if reference.size != app.size:
        raise SystemExit(
            f"image size mismatch: reference {reference.size[0]}x{reference.size[1]}, "
            f"app {app.size[0]}x{app.size[1]}"
        )

    arguments.output_dir.mkdir(parents=True, exist_ok=True)
    overlay_path = arguments.output_dir / f"{label}-overlay-50.png"
    heatmap_path = arguments.output_dir / f"{label}-diff-heatmap.png"
    metrics_path = arguments.output_dir / f"{label}-metrics.json"

    Image.blend(reference, app, 0.5).save(overlay_path, format="PNG", optimize=False)
    difference = ImageChops.difference(reference, app)
    maximum = maximum_channel_image(difference)
    heatmap(maximum).save(heatmap_path, format="PNG", optimize=False)

    analysis = analyze_images(reference, app, arguments.threshold)
    total_pixels = analysis["totalPixels"]
    root_mean_square_channel_difference = analysis[
        "rootMeanSquareChannelDifference"
    ]
    if root_mean_square_channel_difference == 0:
        peak_signal_to_noise_ratio = None
    else:
        peak_signal_to_noise_ratio = 20 * math.log10(
            255 / root_mean_square_channel_difference
        )

    metrics = {
        "schemaVersion": 2,
        "kind": "unmasked-full-frame-visual-measurement",
        "measurementOnly": True,
        "acceptance": {
            "evaluated": False,
            "status": "notEvaluated",
            "reason": (
                "This artifact contains recomputable measurements; "
                "evaluate-acceptance.py applies the pinned acceptance contract."
            ),
        },
        "label": label,
        "reference": {
            "path": str(arguments.reference),
            "sha256": sha256(arguments.reference),
        },
        "app": {
            "path": str(arguments.app),
            "sha256": sha256(arguments.app),
        },
        "outputs": {
            "overlay50": str(overlay_path),
            "diffHeatmap": str(heatmap_path),
        },
        "pixelSize": analysis["pixelSize"],
        "totalPixels": total_pixels,
        "threshold": arguments.threshold,
        "thresholdMeaning": (
            "A pixel is counted as changed when any RGB channel exceeds this difference."
        ),
        "exactChangedPixels": analysis["exactChangedPixels"],
        "exactChangedPixelRatio": analysis["exactChangedPixelRatio"],
        "changedPixels": analysis["changed"]["pixels"],
        "changedPixelRatio": analysis["changed"]["pixelRatio"],
        "meanAbsoluteChannelDifference": analysis[
            "meanAbsoluteChannelDifference"
        ],
        "rootMeanSquareChannelDifference": root_mean_square_channel_difference,
        "peakSignalToNoiseRatioDB": peak_signal_to_noise_ratio,
        "maximumChannelDifference": analysis["maximumChannelDifference"],
        "pixelAnalysis": analysis,
        "masking": "none",
    }
    metrics_path.write_text(
        json.dumps(metrics, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(metrics_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
