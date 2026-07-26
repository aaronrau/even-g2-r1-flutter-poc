#!/usr/bin/env python3
"""Generate deterministic Android and iOS app icons from the 64-unit design."""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
BLACK = (0, 0, 0)
DARK_GRAY = (58, 58, 58)
WHITE = (255, 255, 255)
SUPERSAMPLE = 8


def _round_line(
    draw: ImageDraw.ImageDraw,
    points: tuple[tuple[float, float], tuple[float, float]],
    *,
    scale: float,
    width: float,
) -> None:
    scaled = [(round(x * scale), round(y * scale)) for x, y in points]
    pixel_width = max(1, round(width * scale))
    radius = pixel_width / 2
    draw.line(scaled, fill=WHITE, width=pixel_width)
    for x, y in scaled:
        draw.ellipse(
            (x - radius, y - radius, x + radius, y + radius),
            fill=WHITE,
        )


def render_icon(size: int, destination: Path) -> None:
    canvas_size = size * SUPERSAMPLE
    logical_scale = canvas_size / 64
    image = Image.new("RGB", (canvas_size, canvas_size), BLACK)
    draw = ImageDraw.Draw(image)

    circle_width = 3 * logical_scale
    radius = 23 * logical_scale
    center = 32 * logical_scale
    half_stroke = circle_width / 2
    draw.ellipse(
        (
            center - radius + half_stroke,
            center - radius + half_stroke,
            center + radius - half_stroke,
            center + radius - half_stroke,
        ),
        outline=DARK_GRAY,
        width=max(1, round(circle_width)),
    )

    for segment in (
        ((32, 21.5), (32, 42.5)),
        ((22.9, 26.75), (41.1, 37.25)),
        ((41.1, 26.75), (22.9, 37.25)),
    ):
        _round_line(draw, segment, scale=logical_scale, width=4)

    image = image.resize((size, size), Image.Resampling.LANCZOS)
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, format="PNG", optimize=True)


def main() -> None:
    android_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    android_root = ROOT / "android/app/src/main/res"
    for density, size in android_sizes.items():
        for filename in ("ic_launcher.png", "ic_launcher_round.png"):
            render_icon(size, android_root / density / filename)

    ios_sizes = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    ios_root = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for filename, size in ios_sizes.items():
        render_icon(size, ios_root / filename)


if __name__ == "__main__":
    main()
