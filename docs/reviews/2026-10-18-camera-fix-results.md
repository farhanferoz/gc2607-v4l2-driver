# GC2607 camera fixes: validation results

One entry per task of `docs/reviews/2026-10-18-camera-fix-handover.md`: what was run and what it showed.
Branch `camera-quality` on the laptop.

## T0.1 Evidence tools (2026-10-18)

`make bench` (synthetic 1920x1080 frame, median of 200, today's ISP):

| Core | process_frame (960x540) | chroma_median_filter |
|---|---|---|
| cpu 0 (performance) | 8.72 ms | 5.99 ms |
| cpu 12 (efficiency) | 14.18 ms | 9.30 ms |
| cpu 20 (low-power) | 23.05 ms | 15.24 ms |

`journalctl -u gc2607-camera.service --since "-60 days" -o short-unix --no-pager | python3 tools/isp_log_stats.py`:
4,517 status lines; 15 runs, 0 ever lowered exposure, 2 reached 2002; exposure 600 in 3,317 lines; gain index
histogram 4: 3,719, 6: 445, 8: 353; gain > 0 while exposure < 2002: 81%; cap more restrictive than mean: 100%;
cap at floor: 20%; brightness < 1.0: 26% (< 0.9: 20%); hardware changed in 0% of intervals; fps ~16.7;
darkest-quarter zones rendered 57/255 (plain gamma 95); frame mean 125 (146). Matches the handover's section 2.

`make modules` still builds with the new Makefile targets (Kbuild reads the same Makefile).
