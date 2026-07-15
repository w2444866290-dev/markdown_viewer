#!/usr/bin/env python3
"""Deterministic full-frame pixel analysis shared by visual tools."""

from __future__ import annotations

from collections import deque
from typing import Any

try:
    from PIL import Image, ImageChops, ImageFilter, ImageStat
except ImportError as exc:
    raise SystemExit(
        "pixel_acceptance.py requires Pillow. Install it with: python3 -m pip install Pillow"
    ) from exc


ALGORITHM = "full-frame-spatial-diff-v1"
ANALYSIS_PARAMETERS = {
    "edgeLocalRangeThreshold": 12,
    "edgeRadiusPixels": 1,
    "highMagnitudeThreshold": 48,
    "componentConnectivity": 8,
    "tileSizePixels": 16,
    "partialTilePolicy": "zero-pad-to-full-tile",
}


def flatten_on_white(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    background = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
    return Image.alpha_composite(background, rgba).convert("RGB")


def maximum_channel_image(diff: Image.Image) -> Image.Image:
    red, green, blue = diff.split()
    return ImageChops.lighter(ImageChops.lighter(red, green), blue)


def _binary_threshold(image: Image.Image, minimum_exclusive: int) -> Image.Image:
    return image.point(lambda value: 255 if value > minimum_exclusive else 0, mode="L")


def _edge_mask(image: Image.Image) -> Image.Image:
    radius = ANALYSIS_PARAMETERS["edgeRadiusPixels"]
    filter_size = radius * 2 + 1
    luminance = image.convert("L")
    local_maximum = luminance.filter(ImageFilter.MaxFilter(filter_size))
    local_minimum = luminance.filter(ImageFilter.MinFilter(filter_size))
    local_range = ImageChops.subtract(local_maximum, local_minimum)
    return _binary_threshold(
        local_range,
        ANALYSIS_PARAMETERS["edgeLocalRangeThreshold"] - 1,
    )


def _run_and_tile_metrics(mask: Image.Image) -> tuple[int, int, float]:
    width, height = mask.size
    pixels = mask.load()
    tile_size = ANALYSIS_PARAMETERS["tileSizePixels"]
    tile_columns = (width + tile_size - 1) // tile_size
    tile_rows = (height + tile_size - 1) // tile_size
    tile_counts = [0] * (tile_columns * tile_rows)
    longest_horizontal = 0
    for y in range(height):
        current = 0
        for x in range(width):
            if pixels[x, y]:
                current += 1
                longest_horizontal = max(longest_horizontal, current)
                tile_index = (y // tile_size) * tile_columns + (x // tile_size)
                tile_counts[tile_index] += 1
            else:
                current = 0

    longest_vertical = 0
    runs = [0] * width
    for y in range(height):
        for x in range(width):
            if pixels[x, y]:
                runs[x] += 1
                longest_vertical = max(longest_vertical, runs[x])
            else:
                runs[x] = 0
    maximum_tile_ratio = max(tile_counts, default=0) / (tile_size * tile_size)
    return longest_horizontal, longest_vertical, maximum_tile_ratio


def _largest_component(mask: Image.Image) -> dict[str, Any]:
    width, height = mask.size
    raw = mask.tobytes()
    visited = bytearray(width * height)
    largest_pixels = 0
    largest_bounds: dict[str, int] | None = None
    connectivity = ANALYSIS_PARAMETERS["componentConnectivity"]
    if connectivity != 8:
        raise RuntimeError("only 8-connected analysis is supported")

    for start, value in enumerate(raw):
        if value == 0 or visited[start]:
            continue
        visited[start] = 1
        queue: deque[int] = deque([start])
        count = 0
        minimum_x = width
        minimum_y = height
        maximum_x = -1
        maximum_y = -1
        while queue:
            index = queue.popleft()
            y, x = divmod(index, width)
            count += 1
            minimum_x = min(minimum_x, x)
            minimum_y = min(minimum_y, y)
            maximum_x = max(maximum_x, x)
            maximum_y = max(maximum_y, y)
            for delta_y in (-1, 0, 1):
                neighbor_y = y + delta_y
                if neighbor_y < 0 or neighbor_y >= height:
                    continue
                row_offset = neighbor_y * width
                for delta_x in (-1, 0, 1):
                    if delta_x == 0 and delta_y == 0:
                        continue
                    neighbor_x = x + delta_x
                    if neighbor_x < 0 or neighbor_x >= width:
                        continue
                    neighbor = row_offset + neighbor_x
                    if raw[neighbor] and not visited[neighbor]:
                        visited[neighbor] = 1
                        queue.append(neighbor)
        if count > largest_pixels:
            largest_pixels = count
            largest_bounds = {
                "x": minimum_x,
                "y": minimum_y,
                "width": maximum_x - minimum_x + 1,
                "height": maximum_y - minimum_y + 1,
            }
    return {
        "pixels": largest_pixels,
        "bounds": largest_bounds,
    }


def _mask_metrics(mask: Image.Image, total_pixels: int) -> dict[str, Any]:
    histogram = mask.histogram()
    pixels = total_pixels - histogram[0]
    longest_horizontal, longest_vertical, maximum_tile_ratio = _run_and_tile_metrics(mask)
    return {
        "pixels": pixels,
        "pixelRatio": pixels / total_pixels,
        "largestConnectedComponent": _largest_component(mask),
        "longestHorizontalRunPixels": longest_horizontal,
        "longestVerticalRunPixels": longest_vertical,
        "maximumTilePixelRatio": maximum_tile_ratio,
    }


def analyze_images(
    reference: Image.Image,
    app: Image.Image,
    changed_pixel_threshold: int,
) -> dict[str, Any]:
    if not 0 <= changed_pixel_threshold <= 255:
        raise ValueError("changed pixel threshold must be from 0 through 255")
    reference = flatten_on_white(reference)
    app = flatten_on_white(app)
    if reference.size != app.size:
        raise ValueError(
            f"image size mismatch: reference {reference.size[0]}x{reference.size[1]}, "
            f"app {app.size[0]}x{app.size[1]}"
        )

    difference = ImageChops.difference(reference, app)
    maximum = maximum_channel_image(difference)
    changed_mask = _binary_threshold(maximum, changed_pixel_threshold)
    high_magnitude_mask = _binary_threshold(
        maximum,
        ANALYSIS_PARAMETERS["highMagnitudeThreshold"],
    )
    bounded_difference_mask = ImageChops.subtract(changed_mask, high_magnitude_mask)
    common_edges = ImageChops.multiply(_edge_mask(reference), _edge_mask(app))
    antialias_candidate_mask = ImageChops.multiply(
        bounded_difference_mask,
        common_edges,
    )
    structural_mask = ImageChops.subtract(changed_mask, antialias_candidate_mask)

    width, height = reference.size
    total_pixels = width * height
    exact_changed_pixels = total_pixels - maximum.histogram()[0]
    channel_histograms = difference.histogram()
    absolute_sum = 0
    for channel in range(3):
        offset = channel * 256
        absolute_sum += sum(
            value * channel_histograms[offset + value]
            for value in range(256)
        )
    mean_absolute_channel_difference = absolute_sum / (total_pixels * 3)
    rms_channels = ImageStat.Stat(difference).rms
    root_mean_square_channel_difference = (
        sum(value * value for value in rms_channels) / len(rms_channels)
    ) ** 0.5

    return {
        "algorithm": ALGORITHM,
        "parameters": {
            "changedPixelThreshold": changed_pixel_threshold,
            **ANALYSIS_PARAMETERS,
        },
        "pixelSize": {"width": width, "height": height},
        "totalPixels": total_pixels,
        "exactChangedPixels": exact_changed_pixels,
        "exactChangedPixelRatio": exact_changed_pixels / total_pixels,
        "meanAbsoluteChannelDifference": mean_absolute_channel_difference,
        "rootMeanSquareChannelDifference": root_mean_square_channel_difference,
        "maximumChannelDifference": maximum.getextrema()[1],
        "changed": _mask_metrics(changed_mask, total_pixels),
        "antialiasCandidates": _mask_metrics(antialias_candidate_mask, total_pixels),
        "structural": _mask_metrics(structural_mask, total_pixels),
        "highMagnitude": {
            "pixels": total_pixels - high_magnitude_mask.histogram()[0],
            "pixelRatio": (
                total_pixels - high_magnitude_mask.histogram()[0]
            ) / total_pixels,
        },
    }
