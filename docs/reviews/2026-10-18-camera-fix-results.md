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

## T0.2-T0.4 Capture script, corpus, sensor latency (2026-10-18)

Corpus: `/home/ff235/cache/gc2607/raw/2026-10-18/`, 18 captures x 5 frames (~360 MB): normal 600/4 and 1200/0
(evening, ceiling spots on), backlit 600/4 and 300/0 (front-lit daylight, NOT backlit), backlit2 600/4, 300/0,
150/0 (desk lamp in frame, dark room: the real backlit case), dim 2000/8 and 2000/4, texture 600/4 (grey fabric),
flat 600/4 and 450/4 (printed page, ~12 counts of signal: not a flat field), wall 450/4 and 644/4 (white paper in a
near-dark room, ~9 counts: not usable for banding or shading), dark 600/4 and 2000/16 (finger: leaks red light at
2000/16), dark2 600/4 and 2000/16 (opaque cover).
Still missing: a bright, even flat field (lens shading, Q8) and a plain surface under the room's LED lights
(flicker banding, Q7). Neither blocks Phases 1-3.

Black level (dark2, opaque cover): 64.0-64.3 on all four channels at both 600/4 and 2000/16; dark 600/4 64.4-64.8.
The ISP's BLACK_LEVEL 64 is right and does not drift with gain or exposure.

Latency (`--latency`, from the owner's terminal): exposure 500 -> 1000 lines and gain index 4 -> 8 both first show
on frame 22 after a write following frame 20, i.e. **K_exp = K_gain = 1**; 0 dropped frames. The tool's own summary
said "no change" because it compared raw means including the black level (scene at 73.4 raw = 9.4 above black);
fixed to compare signal above black.

## T0.5 Replay and baseline (2026-10-18)

`python3 tools/isp_metrics.py /home/ff235/cache/gc2607/raw/2026-10-18 /home/ff235/cache/gc2607/replay/baseline
> tools/baseline_metrics.json` (today's ISP, steady-state WB and software brightness at the captured hardware
settings). Selected (display values 0..1):

| Capture | brightness (rule) | y_mean | darkest quarter | clipped | hl_neutral |
|---|---|---|---|---|---|
| normal_e600_g4 | 3.50 (max) | 0.238 | 0.047 | 0.0009 | 0.52 |
| backlit2_e600_g4 | 3.50 (max) | 0.106 | 0.019 | 0.0069 | 0.37 |
| dim_e2000_g8 | 3.50 (max) | 0.178 | 0.067 | 0 | - |
| texture_e600_g4 | 2.40 (cap) | 0.544 | 0.292 | 0.0142 | 3.32 |
| backlit_e600_g4 (front-lit) | 2.30 (cap) | 0.463 | 0.273 | 0.0186 | 2.44 |

In the evening scenes today's pipeline is at its software-brightness ceiling and the face still renders dark
(viewed: `replay/baseline/png/`).

## R1 Setup script aborts (2026-10-18)

Deleted the leftover `[Unit]` ... `SVCEOF` block after the unit `install` line. `grep -c -E '^\[Unit\]$|^SVCEOF$'` = 0;
`bash -n` passes; the line after `install` is `systemctl daemon-reload`. Owner-approved full run:
`sudo -n ./gc2607-setup-service.sh` exited 0; unit active and enabled. The /opt copies it rewrote were confirmed
identical to the repo beforehand (scripts, ISP binary, unit, WirePlumber 50-hide-ipu6-raw.conf).
