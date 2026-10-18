#!/usr/bin/env python3
"""Summarise gc2607_isp status lines from the journal.

Evidence tool for docs/reviews/2026-10-18-camera-fix-handover.md (section 2): how often exposure and
gain move, how often the highlight cap rules, and how the pre-fix tone curve renders the logged means.
Lines from the exposure controller (handover Q1, from 2026-10-18) are summarised separately: frame rate,
frame length, digital gain and the metering it logs.

Usage:
    journalctl -u gc2607-camera.service --since "-60 days" -o short-unix --no-pager \
        | python3 tools/isp_log_stats.py
"""
import collections
import re
import statistics as st
import sys

PAT = re.compile(
    r"^(\d+)\.\d+ .*\[(\d+)\]: \[gc2607_isp\] (\d+) frames \| WB: R=([\d.]+) B=([\d.]+) \| "
    r"bright=([\d.]+) \| exp=(\d+) gain=(\d+) \| means: R=[\d.]+ G=([\d.]+) Gdark=([\d.]+) "
    r"B=[\d.]+ \| AE: mean=>([\d.]+) cap=>([\d.]+)"
)
# The exposure controller's line (gc2607_isp.c, streaming_loop).
CONTROLLER = re.compile(
    r"^(\d+)\.\d+ .*\[(\d+)\]: \[gc2607_isp\] (\d+) frames \| ([\d.]+) fps \| WB: R=[\d.]+ G=[\d.]+ B=[\d.]+ \| "
    r"exp=(\d+) gain=(\d+) fll=(\d+) d=([\d.]+) \| Y=([\d.]+) P98=([\d.]+) clip=([\d.]+)% m=([\d.]+) \| ctrl_fail=(\d+)"
)
FRAMES_PER_LINE = 150
EXPOSURE_MAX = 2002
EXPOSURE_30FPS = 1002  # the controller adds gain only once the exposure reaches this
CLIP_CAP_PCT = 2.0  # AE_CLIP_FRACTION: at or above it the controller's clipping cap applies
CAP_FLOOR = 0.88  # cap computed from the top histogram bin, i.e. >= 2% of samples clipped
MAX_SIGNAL = 959.0
DEEP_DIP = 0.9  # software brightness below this gives a visibly pink clip (handover Q5)


def display_level(linear: float, curve: bool) -> float:
    """Return the 0-255 output for a linear value: today's LUT (curve=True) or a plain 2.2 gamma."""
    x = max(0.0, min(1.0, linear))
    if curve:
        x = x * x * (3 - 2 * x)
    return 255 * x ** (1 / 2.2)


def pct(rows: list[dict], cond) -> str:
    """Share of rows meeting cond, as a percentage string."""
    return f"{100 * sum(1 for r in rows if cond(r)) / len(rows):.0f}%"


def summarise_runs(rows: list[dict], gain_free_below: int) -> list[tuple[dict, dict]]:
    """Print what both line formats share; return consecutive same-run line pairs."""
    runs = collections.defaultdict(list)
    for r in rows:
        runs[r["pid"]].append(r["ex"])
    lowered = sum(any(b < a for a, b in zip(e, e[1:])) for e in runs.values())
    print(f"{len(rows)} status lines ({FRAMES_PER_LINE} frames each); {len(runs)} runs; {lowered} ever lowered exposure")
    print("exposure values:", collections.Counter(r["ex"] for r in rows).most_common(6))
    print("gain index histogram:", sorted(collections.Counter(r["ga"] for r in rows).items()))
    print(f"gain > 0 while exposure < {gain_free_below}:", pct(rows, lambda r: r["ga"] > 0 and r["ex"] < gain_free_below))
    pairs = [(a, b) for a, b in zip(rows, rows[1:]) if a["pid"] == b["pid"] and b["fr"] == a["fr"] + FRAMES_PER_LINE]
    changed = sum((a["ex"], a["ga"]) != (b["ex"], b["ga"]) for a, b in pairs)
    print(f"hardware changed in {100 * changed / max(len(pairs), 1):.0f}% of consecutive intervals")
    return pairs


def summarise_prefix(rows: list[dict]) -> None:
    """Lines from before the exposure controller."""
    print("== pre-fix ISP")
    pairs = summarise_runs(rows, EXPOSURE_MAX)
    reached = sum(EXPOSURE_MAX in {r["ex"] for r in rows if r["pid"] == pid} for pid in {r["pid"] for r in rows})
    print(f"runs that reached {EXPOSURE_MAX}: {reached}")
    print("cap more restrictive than mean:", pct(rows, lambda r: r["ac"] < r["am"]))
    print("cap at floor (>= 2% clipped):", pct(rows, lambda r: r["ac"] <= CAP_FLOOR))
    print("brightness < 1.0:", pct(rows, lambda r: r["br"] < 1.0), f"| < {DEEP_DIP}:", pct(rows, lambda r: r["br"] < DEEP_DIP))
    # Journal timestamps have 1 s resolution, so this is approximate.
    fps = [FRAMES_PER_LINE / (b["t"] - a["t"]) for a, b in pairs if b["t"] > a["t"]]
    print(f"fps median {st.median(fps):.1f} (approximate)" if fps else "fps: n/a")
    for name, key in (("darkest-quarter zones", "gd"), ("frame mean", "g")):
        lin = [r[key] * r["br"] / MAX_SIGNAL for r in rows]
        print(f"{name} rendered: median {st.median(display_level(x, True) for x in lin):.0f}/255 "
              f"(plain gamma {st.median(display_level(x, False) for x in lin):.0f})")


def summarise_controller(rows: list[dict]) -> None:
    """Lines from the exposure controller."""
    print("== exposure controller")
    summarise_runs(rows, EXPOSURE_30FPS)
    print(f"fps median {st.median(r['fps'] for r in rows):.1f}; frame length values:",
          collections.Counter(r["fll"] for r in rows).most_common(4))
    print("digital gain < 1.0:", pct(rows, lambda r: r["d"] < 1.0), "| median", f"{st.median(r['d'] for r in rows):.2f}")
    print(f"Y median {st.median(r['y'] for r in rows):.3f}; P98 median {st.median(r['p98'] for r in rows):.2f}; "
          f"clipped >= {CLIP_CAP_PCT:g}%: {pct(rows, lambda r: r['clip'] >= CLIP_CAP_PCT)}; "
          f"control write failures: {max(r['fail'] for r in rows)}")


def main() -> None:
    """Parse status lines from stdin and print a summary per line format."""
    prefix, controller = [], []
    for line in sys.stdin:
        if m := PAT.match(line):
            t, pid, fr, _wr, _wb, br, ex, ga, g, gd, am, ac = m.groups()
            prefix.append(dict(t=int(t), pid=pid, fr=int(fr), br=float(br), ex=int(ex), ga=int(ga),
                               g=float(g), gd=float(gd), am=float(am), ac=float(ac)))
        elif m := CONTROLLER.match(line):
            t, pid, fr, fps, ex, ga, fll, d, y, p98, clip, _m, fail = m.groups()
            controller.append(dict(t=int(t), pid=pid, fr=int(fr), fps=float(fps), ex=int(ex), ga=int(ga), fll=int(fll),
                                   d=float(d), y=float(y), p98=float(p98), clip=float(clip), fail=int(fail)))
    if not prefix and not controller:
        sys.exit("no status lines")
    if prefix:
        summarise_prefix(prefix)
    if controller:
        summarise_controller(controller)


if __name__ == "__main__":
    main()
