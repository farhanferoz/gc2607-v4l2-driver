#!/usr/bin/env python3
"""Compare two isp_metrics.py outputs, one row per capture (fix handover: "corpus vs baseline").

    python3 tools/compare_metrics.py tools/baseline_metrics.json NEW.json [METRIC ...]

METRIC defaults to y_mean dark_quarter clipped hl_neutral false_colour; each prints as old -> new.
"""
import json
import sys

DEFAULT = ("y_mean", "dark_quarter", "clipped", "hl_neutral", "false_colour")
MIN_ARGV = 3  # program, old file, new file


def main() -> None:
    """Print a fixed-width table of the chosen metrics for every capture in both files."""
    if len(sys.argv) < MIN_ARGV:
        sys.exit(__doc__)
    old_path, new_path, *chosen = sys.argv[1:]
    old, new = (json.load(open(p)) for p in (old_path, new_path))
    metrics = chosen or DEFAULT
    print(f"{'capture':<20}" + "".join(f"{m:>22}" for m in metrics))
    for name in sorted(old.keys() & new.keys()):
        cells = []
        for m in metrics:
            a, b = old[name].get(m), new[name].get(m)
            cells.append(f"{'-' if a is None else a:>10} -> {'-' if b is None else b:<8}")
        print(f"{name:<20}" + "".join(f"{c:>22}" for c in cells))


if __name__ == "__main__":
    main()
