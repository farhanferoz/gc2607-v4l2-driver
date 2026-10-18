#!/usr/bin/env python3
"""Fit the lens-shading correction table from flat-field captures (fix handover Q8).

    python3 tools/lsc_calibrate.py --out gc2607_lsc_table.h FLAT.raw...
    python3 tools/lsc_calibrate.py --verify FLAT.raw...

FLAT.raw are captures from gc2607-raw-capture.sh of an evenly lit white surface over the lens (2026-10-18:
printer paper facing a window, `dayflat_*`). Each Bayer channel is averaged over its frames and over
BLOCK x BLOCK blocks of its plane, then fitted in the log domain by a polynomial in even powers of the
distance from the frame centre on each axis: the fit is symmetric left-right and top-bottom by construction,
so the light's own gradient across the paper (which differs between captures and light sources, and is not
the lens) drops out. The flat fields put the brightest point within ~2% of the frame width of the centre.

The table holds, at LSC_NX x LSC_NY nodes spanning the frame corner to corner (bilinear in between, as in
gc2607_isp.c), the luminance gain (centre green / green at the node, >= 1) and the red and blue colour gains
(the red/green and blue/green ratios at the centre over those at the node). Following libcamera's ALSC
(src/ipa/rpi/controller/rpi/alsc.cpp), the ISP scales only the luminance part by its strength, as
1 + strength * (luma - 1), and always applies the colour part in full.

--verify prints each capture's corner/centre ratio per channel (tools/isp_metrics.py raw_metrics) before and
after a full-strength correction with the current gc2607_lsc_table.h.
"""
import argparse
import pathlib
import re
import sys

import numpy as np
from isp_metrics import H, W, raw_metrics

REPO = pathlib.Path(__file__).resolve().parent.parent
TABLE = REPO / "gc2607_lsc_table.h"
BLACK = 64
BLOCK = 10                 # plane pixels per block side: 54 x 96 blocks
LUMA_ORDER = 4             # highest power of u^2, v^2 (with i + j <= order) in the luminance fit
COLOUR_ORDER = 2           # same for the colour ratios, which vary by a few percent only
GRID = [32, 18]            # nodes across, down (--grid); 16 x 9 left a 3.8% bilinear error in the corners
Q12_LIMIT = 65535 / 4096   # gc2607_isp.c keeps gains as uint16 in Q12 (LSC_SHIFT 12)
# Bayer GRBG: plane name -> (row offset, column offset) of its site in each 2x2 block
SITES = {"gr": (0, 0), "r": (0, 1), "b": (1, 0), "gb": (1, 1)}


def load_planes(path: pathlib.Path) -> dict[str, np.ndarray]:
    """Return each Bayer plane of a raw capture, averaged over its frames, minus the black level."""
    frames = np.fromfile(path, np.uint16).reshape(-1, H, W).astype(np.float64)
    mosaic = frames.mean(axis=0) - BLACK
    return {k: mosaic[dy::2, dx::2] for k, (dy, dx) in SITES.items()}


def block_means(plane: np.ndarray) -> np.ndarray:
    """Mean over BLOCK x BLOCK blocks of one plane."""
    h, w = plane.shape
    return plane.reshape(h // BLOCK, BLOCK, w // BLOCK, BLOCK).mean(axis=(1, 3))


def frame_coords(x: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Full-resolution pixel coordinates -> offsets from the frame centre in units of half the width."""
    half = (W - 1) / 2
    return (x - half) / half, (y - (H - 1) / 2) / half


def even_terms(u: np.ndarray, v: np.ndarray, order: int) -> np.ndarray:
    """Design matrix of u^(2i) v^(2j) for i + j <= order, one column per term."""
    return np.stack([(u ** (2 * i) * v ** (2 * j)).ravel() for i in range(order + 1) for j in range(order + 1 - i)], axis=1)


def block_centres(sy: int, sx: int, shape: tuple[int, int]) -> tuple[np.ndarray, np.ndarray]:
    """Frame coordinates (u, v) of the block centres of a plane whose site is at row sy, column sx."""
    ny, nx = shape
    x = 2 * (np.arange(nx) * BLOCK + (BLOCK - 1) / 2) + sx
    y = 2 * (np.arange(ny) * BLOCK + (BLOCK - 1) / 2) + sy
    u, v = frame_coords(*np.meshgrid(x, y))
    return u, v


def fit_log(values: np.ndarray, u: np.ndarray, v: np.ndarray, order: int) -> tuple[np.ndarray, float]:
    """Least-squares fit of log(values) by even_terms; return the coefficients and the symmetric residual.

    The residual is the largest |data / fit - 1| after averaging the data over its four mirror images,
    i.e. the part of the shading the symmetric model fails to describe.
    """
    coef = np.linalg.lstsq(even_terms(u, v, order), np.log(values.ravel()), rcond=None)[0]
    fit = np.exp(even_terms(u, v, order) @ coef).reshape(values.shape)
    rel = values / fit
    sym = (rel + rel[::-1] + rel[:, ::-1] + rel[::-1, ::-1]) / 4
    return coef, float(np.abs(sym - 1).max())


def node_coords() -> tuple[np.ndarray, np.ndarray]:
    """Full-resolution x and y of the table's node columns and rows (corner to corner)."""
    return np.linspace(0, W - 1, GRID[0]), np.linspace(0, H - 1, GRID[1])


def evaluate(coef: np.ndarray, order: int, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """exp(fit) on the grid of full-resolution coordinates x (columns) by y (rows)."""
    u, v = frame_coords(*np.meshgrid(x, y))
    return np.exp(even_terms(u, v, order) @ coef).reshape(len(y), len(x))


def fit_capture(path: pathlib.Path) -> dict[str, np.ndarray]:
    """Fit one flat field; return the log coefficients of green, red/green and blue/green."""
    p = load_planes(path)
    green = block_means((p["gr"] + p["gb"]) / 2)
    red, blue = block_means(p["r"]), block_means(p["b"])
    # Green planes sit at (0, 0) and (1, 1); their average is centred at (0.5, 0.5). Red and blue ratios
    # are taken against that green, a half-pixel apart: far below the shading's scale.
    u, v = block_centres(0.5, 0.5, green.shape)
    out, residual = {}, {}
    out["luma"], residual["luma"] = fit_log(green, u, v, LUMA_ORDER)
    out["red"], residual["red"] = fit_log(red / green, u, v, COLOUR_ORDER)
    out["blue"], residual["blue"] = fit_log(blue / green, u, v, COLOUR_ORDER)
    print(f"{path.name}: green mean {green.mean():.1f}, symmetric residual "
          + ", ".join(f"{k} {r:.4f}" for k, r in residual.items()), file=sys.stderr)
    return out


def gain_tables(coefs: dict[str, np.ndarray], x: np.ndarray, y: np.ndarray) -> dict[str, np.ndarray]:
    """Correction gains on the x by y grid, each 1 at the frame centre."""
    centre = (np.array([(W - 1) / 2]), np.array([(H - 1) / 2]))
    tables = {}
    for name, order in (("luma", LUMA_ORDER), ("red", COLOUR_ORDER), ("blue", COLOUR_ORDER)):
        tables[name] = evaluate(coefs[name], order, *centre)[0, 0] / evaluate(coefs[name], order, x, y)
    return tables


def bilinear(table: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """Interpolate a node table at full-resolution columns x and rows y, as gc2607_isp.c does."""
    nx, ny = node_coords()
    across = np.array([np.interp(x, nx, row) for row in table])          # (LSC_NY, len(x))
    return np.array([np.interp(y, ny, col) for col in across.T]).T       # (len(y), len(x))


def format_table(name: str, table: np.ndarray, comment: str) -> str:
    """One C array of the table, four decimals."""
    rows = ",\n".join("    { " + ", ".join(f"{v:.4f}f" for v in row) + " }" for row in table)
    return f"/* {comment} */\nstatic const float {name}[LSC_NY][LSC_NX] = {{\n{rows}\n}};\n"


def write_header(path: pathlib.Path, tables: dict[str, np.ndarray], sources: list[pathlib.Path]) -> None:
    """Write gc2607_lsc_table.h; refuse gains the ISP's 16-bit Q12 storage (LSC_SHIFT) cannot hold."""
    largest = float((tables["luma"] * np.maximum(1.0, np.maximum(tables["red"], tables["blue"]))).max())
    if largest >= Q12_LIMIT:
        sys.exit(f"largest gain {largest:.2f} does not fit the ISP's Q12 gains (< {Q12_LIMIT:.2f})")
    names = " ".join(s.name for s in sources)
    text = (f"/*\n * Lens-shading correction for the GC2607 module, generated by tools/lsc_calibrate.py\n"
            f" * from {names}.\n * Do not edit: re-run the tool. Nodes span the frame corner to corner.\n */\n"
            f"#ifndef GC2607_LSC_TABLE_H\n#define GC2607_LSC_TABLE_H\n\n#define LSC_NX {GRID[0]}\n#define LSC_NY {GRID[1]}\n\n"
            + format_table("lsc_luma", tables["luma"], "luminance gain: centre green / green here")
            + "\n" + format_table("lsc_red", tables["red"], "red colour gain: (R/G at the centre) / (R/G here)")
            + "\n" + format_table("lsc_blue", tables["blue"], "blue colour gain: (B/G at the centre) / (B/G here)")
            + "\n#endif\n")
    path.write_text(text)


def read_header(path: pathlib.Path) -> dict[str, np.ndarray]:
    """Parse the three tables back out of gc2607_lsc_table.h."""
    text = path.read_text()
    tables = {}
    for name in ("luma", "red", "blue"):
        body = re.search(rf"lsc_{name}\[LSC_NY\]\[LSC_NX\] = \{{(.*?)\n\}};", text, re.DOTALL).group(1)
        tables[name] = np.array([float(v) for v in re.findall(r"([\d.]+)f", body)]).reshape(GRID[1], GRID[0])
    return tables


def correct(path: pathlib.Path, tables: dict[str, np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
    """Return the capture's last frame and that frame corrected at full strength, as full mosaics."""
    frames = path.stat().st_size // (W * H * 2)
    raw = np.fromfile(path, np.uint16, count=W * H, offset=(frames - 1) * W * H * 2).reshape(H, W).astype(np.float64)
    gain = {"gr": tables["luma"], "gb": tables["luma"], "r": tables["luma"] * tables["red"], "b": tables["luma"] * tables["blue"]}
    out = raw.copy()
    for k, (dy, dx) in SITES.items():
        g = bilinear(gain[k], np.arange(dx, W, 2), np.arange(dy, H, 2))
        out[dy::2, dx::2] = BLACK + (raw[dy::2, dx::2] - BLACK) * g
    return raw, out


def main() -> None:
    """Fit and write the table, or verify the written one."""
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("raws", nargs="+", type=pathlib.Path)
    ap.add_argument("--out", type=pathlib.Path, help="header to write (gc2607_lsc_table.h)")
    ap.add_argument("--verify", action="store_true", help="corner/centre before and after the current table")
    ap.add_argument("--grid", type=int, nargs=2, default=GRID, metavar=("NX", "NY"), help="nodes across and down")
    args = ap.parse_args()
    GRID[:] = args.grid

    if args.verify:
        tables = read_header(TABLE)
        for path in args.raws:
            before, after = (raw_metrics(m)["corner_centre"] for m in correct(path, tables))
            print(f"{path.name}: before {before}  after {after}")
        return

    fits = [fit_capture(p) for p in args.raws]
    coefs = {k: np.mean([f[k] for f in fits], axis=0) for k in fits[0]}   # geometric mean of the fits
    x, y = node_coords()
    tables = gain_tables(coefs, x, y)
    # Consistency: each capture's own table against the average one.
    for path, f in zip(args.raws, fits):
        own = gain_tables(f, x, y)
        print(f"{path.name}: max table deviation from the mean "
              + ", ".join(f"{k} {np.abs(own[k] / tables[k] - 1).max():.3f}" for k in own), file=sys.stderr)
    # Interpolation: the bilinear table against the fitted surface at every 4th full-resolution pixel.
    fx, fy = np.arange(0, W, 4), np.arange(0, H, 4)
    dense = gain_tables(coefs, fx, fy)
    for k in tables:
        err = np.abs(bilinear(tables[k], fx, fy) / dense[k] - 1)
        print(f"{k}: corner gain {tables[k][0, 0]:.3f}, bilinear error max {err.max():.4f} mean {err.mean():.4f}", file=sys.stderr)
    if args.out:
        write_header(args.out, tables, args.raws)


if __name__ == "__main__":
    main()
