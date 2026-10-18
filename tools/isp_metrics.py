#!/usr/bin/env python3
"""Replay a raw corpus through the ISP and score the output (fix handover T0.5).

    python3 tools/isp_metrics.py CORPUS_DIR OUT_DIR > metrics.json

For every <name>.raw from gc2607-raw-capture.sh in CORPUS_DIR, runs build/isp_replay on its last frame,
writes OUT_DIR/<name>.yuyv, .json and a viewable .ppm, and prints one JSON object of metrics per file.
Output metrics (display values 0..1): y_mean, dark_quarter (mean of the darkest 25% of 16x16 zones),
clipped (fraction with Y >= 0.98), hl_neutral (mean |R-G| and |B-G| over clipped pixels, 0-255),
false_colour (mean chroma magnitude in the centre half, 0-128) and noise (std of Y in the centre 20%).
Raw metrics, independent of the ISP: corner/centre ratio per Bayer channel, row banding (std of
detrended green row means / mean), and per-channel black level for 'dark' scenes.
"""
import json
import pathlib
import subprocess
import sys

import numpy as np

REPO = pathlib.Path(__file__).resolve().parent.parent
REPLAY = REPO / "build" / "isp_replay"
W, H = 1920, 1080
CLIP_Y = 0.98
ZONES = 16


def yuyv_to_rgb(buf: np.ndarray, width: int, height: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Convert limited-range BT.601 YUYV bytes to (Y 0..1, RGB 0..255, chroma magnitude 0..128)."""
    p = buf.reshape(height, width // 2, 4).astype(np.float32)
    y = np.empty((height, width), np.float32)
    y[:, 0::2], y[:, 1::2] = p[..., 0], p[..., 2]
    u = np.repeat(p[..., 1], 2, axis=1) - 128.0
    v = np.repeat(p[..., 3], 2, axis=1) - 128.0
    c = y - 16.0
    rgb = np.stack([1.164 * c + 1.596 * v, 1.164 * c - 0.392 * u - 0.813 * v, 1.164 * c + 2.017 * u], axis=-1)
    return np.clip(c / 219.0, 0, 1), np.clip(rgb, 0, 255), np.hypot(u, v)


def centre(a: np.ndarray, frac: float) -> np.ndarray:
    """Return the centred sub-array covering `frac` of each dimension."""
    h, w = a.shape[:2]
    dh, dw = int(h * (1 - frac) / 2), int(w * (1 - frac) / 2)
    return a[dh:h - dh, dw:w - dw]


def output_metrics(yuyv: np.ndarray, width: int, height: int) -> dict:
    """Score one ISP output frame."""
    y, rgb, chroma = yuyv_to_rgb(yuyv, width, height)
    zh, zw = height // ZONES, width // ZONES
    zones = np.sort(y[:zh * ZONES, :zw * ZONES].reshape(ZONES, zh, ZONES, zw).mean(axis=(1, 3)).ravel())
    clipped = y >= CLIP_Y
    hl = rgb[clipped]
    return {
        "y_mean": round(float(y.mean()), 4),
        "dark_quarter": round(float(zones[: len(zones) // 4].mean()), 4),
        "clipped": round(float(clipped.mean()), 4),
        "hl_neutral": round(float((np.abs(hl[:, 0] - hl[:, 1]).mean() + np.abs(hl[:, 2] - hl[:, 1]).mean()) / 2), 2)
        if len(hl) else None,
        "false_colour": round(float(centre(chroma, 0.5).mean()), 2),
        "noise": round(float(centre(y, 0.2).std()), 4),
    }


def raw_metrics(raw: np.ndarray) -> dict:
    """Sensor-side metrics from one GRBG frame (independent of the ISP)."""
    planes = {"gr": raw[0::2, 0::2], "r": raw[0::2, 1::2], "b": raw[1::2, 0::2], "gb": raw[1::2, 1::2]}
    out = {"black": {k: round(float(p.mean()), 1) for k, p in planes.items()}}
    ratios = {}
    for k, p in planes.items():
        h, w = p.shape
        ch, cw = h // 20, w // 20
        corners = np.mean([p[:ch, :cw].mean(), p[:ch, -cw:].mean(), p[-ch:, :cw].mean(), p[-ch:, -cw:].mean()])
        ratios[k] = round(float((corners - 64) / max(centre(p, 0.1).mean() - 64, 1e-6)), 3)
    out["corner_centre"] = ratios
    rows = planes["gr"].mean(axis=1) - 64
    x = np.arange(len(rows))
    trend = np.polyval(np.polyfit(x, rows, 3), x)
    out["row_banding"] = round(float((rows - trend).std() / max(rows.mean(), 1e-6)), 5)
    return out


def write_ppm(path: pathlib.Path, rgb: np.ndarray) -> None:
    """Write an 8-bit RGB image as binary PPM."""
    h, w = rgb.shape[:2]
    path.write_bytes(f"P6\n{w} {h}\n255\n".encode() + rgb.astype(np.uint8).tobytes())


def main() -> None:
    """Replay every raw file in the corpus and print the metrics as JSON."""
    args = sys.argv[1:]
    try:
        corpus_arg, out_arg = args
    except ValueError:
        sys.exit(__doc__)
    corpus, out_dir = pathlib.Path(corpus_arg), pathlib.Path(out_arg)
    out_dir.mkdir(parents=True, exist_ok=True)
    results = {}
    for raw_path in sorted(corpus.glob("*.raw")):
        prefix = out_dir / raw_path.stem
        subprocess.run([str(REPLAY), str(raw_path), str(prefix)], check=True)
        info = json.loads(prefix.with_suffix(".json").read_text())
        width, height = info["width"], info["height"]
        yuyv = np.fromfile(prefix.with_suffix(".yuyv"), np.uint8)
        frames = raw_path.stat().st_size // (W * H * 2)
        raw = np.fromfile(raw_path, np.uint16, count=W * H, offset=(frames - 1) * W * H * 2).reshape(H, W)
        write_ppm(prefix.with_suffix(".ppm"), yuyv_to_rgb(yuyv, width, height)[1])
        results[raw_path.stem] = {"controls": info, **output_metrics(yuyv, width, height), "raw": raw_metrics(raw)}
    json.dump(results, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
