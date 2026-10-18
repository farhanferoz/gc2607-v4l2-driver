#!/usr/bin/env python3
"""Summarise gc2607_isp status lines from the journal.

Evidence tool for docs/reviews/2026-10-18-camera-fix-handover.md (section 2): how often exposure and
gain move, how often the highlight cap rules, and how today's tone curve renders the logged means.

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
FRAMES_PER_LINE = 150
EXPOSURE_MAX = 2002
CAP_FLOOR = 0.88  # cap computed from the top histogram bin, i.e. >= 2% of samples clipped
MAX_SIGNAL = 959.0
DEEP_DIP = 0.9  # software brightness below this gives a visibly pink clip (handover Q5)


def display_level(linear: float, curve: bool) -> float:
    """Return the 0-255 output for a linear value: today's LUT (curve=True) or a plain 2.2 gamma."""
    x = max(0.0, min(1.0, linear))
    if curve:
        x = x * x * (3 - 2 * x)
    return 255 * x ** (1 / 2.2)


def main() -> None:
    """Parse status lines from stdin and print the summary."""
    rows = []
    for line in sys.stdin:
        m = PAT.match(line)
        if m:
            t, pid, fr, _wr, _wb, br, ex, ga, g, gd, am, ac = m.groups()
            rows.append(dict(t=int(t), pid=pid, fr=int(fr), br=float(br), ex=int(ex), ga=int(ga),
                             g=float(g), gd=float(gd), am=float(am), ac=float(ac)))
    n = len(rows)
    if not n:
        sys.exit("no status lines")

    def pct(cond) -> str:
        return f"{100 * sum(1 for r in rows if cond(r)) / n:.0f}%"

    print(f"{n} status lines ({FRAMES_PER_LINE} frames each)")
    runs = collections.defaultdict(list)
    for r in rows:
        runs[r["pid"]].append(r["ex"])
    lowered = sum(any(b < a for a, b in zip(e, e[1:])) for e in runs.values())
    reached = sum(EXPOSURE_MAX in e for e in runs.values())
    print(f"{len(runs)} runs; {lowered} ever lowered exposure; {reached} reached {EXPOSURE_MAX}")
    print("exposure values:", collections.Counter(r["ex"] for r in rows).most_common(6))
    print("gain index histogram:", sorted(collections.Counter(r["ga"] for r in rows).items()))
    print(f"gain > 0 while exposure < {EXPOSURE_MAX}:", pct(lambda r: r["ga"] > 0 and r["ex"] < EXPOSURE_MAX))
    print("cap more restrictive than mean:", pct(lambda r: r["ac"] < r["am"]))
    print("cap at floor (>= 2% clipped):", pct(lambda r: r["ac"] <= CAP_FLOOR))
    print("brightness < 1.0:", pct(lambda r: r["br"] < 1.0), f"| < {DEEP_DIP}:", pct(lambda r: r["br"] < DEEP_DIP))

    pairs = [(a, b) for a, b in zip(rows, rows[1:]) if a["pid"] == b["pid"] and b["fr"] == a["fr"] + FRAMES_PER_LINE]
    changed = sum((a["ex"], a["ga"]) != (b["ex"], b["ga"]) for a, b in pairs)
    print(f"hardware changed in {100 * changed / max(len(pairs), 1):.0f}% of consecutive intervals")
    # Journal timestamps have 1 s resolution, so this is approximate.
    fps = [FRAMES_PER_LINE / (b["t"] - a["t"]) for a, b in pairs if b["t"] > a["t"]]
    print(f"fps median {st.median(fps):.1f} (approximate)" if fps else "fps: n/a")

    for name, key in (("darkest-quarter zones", "gd"), ("frame mean", "g")):
        lin = [r[key] * r["br"] / MAX_SIGNAL for r in rows]
        print(f"{name} rendered: median {st.median(display_level(x, True) for x in lin):.0f}/255 "
              f"(plain gamma {st.median(display_level(x, False) for x in lin):.0f})")


if __name__ == "__main__":
    main()
