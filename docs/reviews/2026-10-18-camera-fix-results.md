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

## R2 Kernel-update runbook (2026-10-18)

`docs/operations-runbook.md` "After a kernel update" now says: check `dkms status` for both modules, `dkms
autoinstall -k` if one is missing, install driver changes with `gc2607-driver-install.sh`; never hand-copy into
extra/. The old hand-build lines are gone from that section (grep count 0). `dkms status` on 7.2.11 shows
`gc2607/1.0` and `ipu-bridge-gc2607/1.0` installed. README's upstream `init_camera.sh` path is marked historical;
`gc2607-install.sh` now refuses to run (exit 1, pointing to DKMS) unless `GC2607_HISTORICAL_INSTALL=1`.

## R3 Failed probe powers the sensor off (2026-10-18)

`gc2607_power_off()` is now the first statement under `err_power:`. `make modules`: no warnings (only the usual
pahole/BTF notes). `sudo -n ./gc2607-driver-install.sh`: DKMS built and installed for 7.2.9, 7.2.10 and 7.2.11,
`OK` (5 min 22 s, all DKMS); `dmesg` shows `GC2607 probe successful` after the reload. The new path runs only when
chip detection fails, which cannot be provoked on working hardware. Still owed [OWNER]: a 5-second stream, then one
suspend/resume and a stream again.

## R4 Install rollback waits for the ISP (2026-10-18)

Reproduced first, and it was worse than the handover's "prints OK": with a binary that exits 1, `systemctl restart`
itself failed (the process died during ExecStartPost), `set -e` ended `gc2607-install-isp.sh` before its rollback,
and the bad binary stayed in /opt with the unit restarting (exit 1, no rollback, `cmp` against a saved copy: BAD).
`gc2607-driver-install.sh` had the same `set -e` exit on its `systemctl start`. Fix: both scripts tolerate a failed
start job and call the new `gc2607-wait-ready.sh` (up to 15 s: unit active AND the current invocation, `journalctl
-I`, has logged `[gc2607_isp] Idle, waiting for consumers`). Same bad binary after the fix: `FAILED — rolling back`,
exit 1 after 29 s, unit active on the good binary, idle line present. Good binary (`make -B isp`, same source as
09-23 rebuilt by gcc 16.2.1 instead of 16.1.1): `OK` in 6.9 s.
Driver path: the R3 install above went through the new wait and printed `OK`; its rollback path is the same
tolerant start plus wait, not provoked separately.

## Q2 Contrast on display values (2026-10-18)

`build_luts()` now encodes with the sRGB curve and then mixes 0.25 of a smoothstep into the encoded value.
`make build/test_lut && ./build/test_lut`: ok (black 0, white 255, 18% grey 116, 5% 57, never decreasing). The same
test built against the previous `gc2607_isp.c` (from `git show HEAD:`) FAILS with 18% grey 84 and 5% 27.
Corpus (`tools/isp_metrics.py` into `/home/ff235/cache/gc2607/replay/q2`, then `python3 tools/compare_metrics.py
tools/baseline_metrics.json /home/ff235/cache/gc2607/replay/q2_metrics.json`), same steady-state controls:

| Capture | dark_quarter | clipped | y_mean |
|---|---|---|---|
| normal_e600_g4 | 0.047 -> 0.117 | 0.0009 -> 0.0009 | 0.238 -> 0.344 |
| normal_e1200_g0 | 0.051 -> 0.124 | 0.0004 -> 0.0004 | 0.242 -> 0.348 |
| backlit2_e600_g4 (real backlight) | 0.019 -> 0.059 | 0.0069 -> 0.0068 | 0.106 -> 0.200 |
| backlit_e600_g4 (front-lit) | 0.273 -> 0.402 | 0.0186 -> 0.0153 | 0.463 -> 0.559 |
| texture_e600_g4 | 0.292 -> 0.419 | 0.0142 -> 0.0099 | 0.544 -> 0.619 |

The darkest quarter rises on every capture and clipping never rises (the bar was at most +1 point).
