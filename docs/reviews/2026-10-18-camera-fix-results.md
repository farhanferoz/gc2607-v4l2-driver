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

## Q3a Chroma from both pixels of a pair (2026-10-18)

`rgb_to_yuyv()` takes U and V from the pair's summed colour (`>> 9`, rounded). New `tests/test_output.c`: the pair
(255,0,0), (0,0,255) gives U 174 and V 186, the chroma of (127.5, 0, 127.5) with this ISP's 1.25x chroma gain
(174.1 and 186.5), within 1. The same test against the Q2 commit's `gc2607_isp.c` FAILS with U 81 and V 240 (the red
pixel's chroma alone).

## Q3b Full 1920x1080 output (2026-10-18)

New `demosaic_full()`: bilinear GRBG demosaic written rotated straight into a 1920x1080 YUYV frame, reading three
padded line buffers (rows and columns reflect by two at the borders, so edge pixels keep the right colour). The
statistics moved into `collect_stats()`, with the same half-resolution sampling as before; the binning path is
`bin_half()` behind `GC2607_ISP_HALF_RES=1` (also honoured by `tools/isp_replay.c`). `CPUAffinity=0-19` in the unit.

- Fallback identity: `GC2607_ISP_HALF_RES=1 build/isp_replay` vs the Q3a commit's replay on all 18 corpus frames:
  18 identical `.yuyv` and `.json` files, 0 different (so the statistics refactor changed nothing).
- `make test`: test_lut ok, test_output ok (uniform frame: all 1,036,800 pairs identical; grey step at column 960:
  colour only in output pairs 479-480; rotation). Mutations: clamping the padded columns instead of reflecting fails
  the uniform check (1080 pairs); widening one interpolation tap fails both (540 pairs each).
- `make bench` (median of 200): full 10.42 ms on cpu 0 (bar 13), 20.44 ms on cpu 12 (bar 22), 33.67 ms on cpu 20
  (over 33 ms, hence the affinity); binned 8.74 / 14.54 / 24.69 ms.
- Corpus, mean chroma magnitude in the centre half (`false_colour`), baseline -> Q3b: texture 7.12 -> 6.19 (bar <=
  1.2x baseline: met). Against Q2 at half resolution, full resolution raises it 1.1-1.4x in room light (normal
  3.86 -> 5.24) and 2-6x in the darkest captures, with luma noise unchanged: chroma noise that binning and the
  median used to average away. A side-by-side crop of normal_e600_g4 shows a visibly sharper face with faint colour
  speckle on skin. Those frames were taken at 2x gain; Q1 should bring room-light gain to 1x, so re-measure after Q1
  before adding a chroma filter.

## Owner review of the display curve (2026-10-18)

The owner sent a photo from the installed (pre-fix) pipeline: soft, grainy, washed out. Its status lines: 960x540,
exposure 900 lines, gain index 4 (2x) in daylight, software brightness 1.55 set by the highlight cap. Raw captures of
the same room (`room-day_e900_g4`, `_e1800_g0`, `_e1002_g4` in the corpus): wall temporal SNR 38.4 at 900/4, 50.6 at
1800/0 (same light, ~30% less noise at 1x gain but needs ~56 ms, i.e. 15 fps). Four curves rendered from
`room-day_e900_g4` and `normal_e600_g4`, all metered to display mean 0.45 (`/home/ff235/cache/gc2607/tone-variants-
room.png`, `-evening.png`): A installed curve, B Q2 as specified, C B with contrast 0.6 and a 1.5% black point, D C
with 1.6x colour. **The owner chose B**, so Q2 stays as specified. Frame-rate policy left at the handover's default
(30 fps first, gain before a longer frame).

## Metric fix: highlight neutrality on raw-saturated pixels (2026-10-18)

`tools/isp_metrics.py` scored `hl_neutral` over pixels that are bright on screen (Y >= 0.98); the handover defines it
over pixels whose raw channels are all >= 1008, which must render white. Brighter rendering (Q2, Q1) puts unsaturated,
genuinely coloured surfaces above Y 0.98, so the old definition read as a regression that was not one. Now: 2x2 Bayer
blocks saturated at all four sites, rotated as the ISP rotates. `tools/baseline_metrics.json` is re-scored with the
pre-fix ISP (sources from 6a3a198) and now also holds the three `room-day` captures: every other field is identical
to the previous file (checked field by field); `hl_neutral` is 0.0 wherever a capture has saturated blocks.

## D1 30 fps timing, writable VBLANK (2026-10-18)

Driver: HTS 1959 and frame length 1116 in both register pairs (0x0340/41, 0x0220/21); VBLANK writable 36..1152, writing
both pairs and re-ranging EXPOSURE to [4, frame length - 8]; PIXEL_RATE 65,368,695 Hz (1959 x 1116 x 29.90); HBLANK
39 read-only; defaults exposure 1000, gain index 0. `make modules`: no warnings. `sudo -n ./gc2607-driver-install.sh`:
DKMS for 7.2.9/7.2.10/7.2.11, `OK`; probe line `Format: SGRBG10 1920x1080@30fps`.

- `v4l2-ctl --list-ctrls` on the sensor subdev: exposure 4..1108 default 1000, vertical_blanking 36..1152 (writable),
  horizontal_blanking 39 (read-only), analogue_gain default 0, pixel_rate 65368695.
- Sensor off, controls only: VBLANK 1152 -> exposure max 2224; VBLANK back to 36 with exposure 2224 -> clamped to
  1108; exposure 2002 requested at VBLANK 36 -> 1108, no error (so the pre-Q1 ISP still runs on this driver).
- Camera on, new `gc2607-raw-capture.sh --fps 36 1152` (300 frames each, nothing saved): **29.90 fps** at VBLANK 36
  and **15.16 fps** at 1152 (the timing predicts 14.95; the 1.4% gap is unexplained), exposure maximum 1108 and 2224.
  Kernel log for both windows: only stream on/off lines; no line mentioning ipu/isys/csi with err or fail this boot.

## Q1 + Q5 Exposure controller, anti-flicker, neutral highlights (2026-10-18, offline part)

One controller (`ae_meter_frame`, `ae_step`, `ae_allocate` in `gc2607_isp.c`) replaces the software brightness loop
and the separate hardware loop, as specified, with these measured choices:
- Per-update step capped at 1.10x (linear) on top of the 0.3 damping: with damping alone the simulated sensor's
  display luma moved up to 21% in one frame while converging (the bar is 12%); the contrast term makes display luma
  move ~1.15x as fast as linear in deep shadow, so 1.12 still gave 13.9%. Cost: a 40x light change takes ~2.5 s.
- Real gains from the vendor table (`gain_x64`), cross-checked on today's raw: wall level at 900 lines / index 4 vs
  1800 lines / index 0 implies 1.98x for index 4 (table: 2.03x).
- White balance is normalised so no gain is below 1 and d never goes below 1 (Q5); P98 uses the green gain and d.
- Flicker: `GC2607_ISP_FLICKER_HZ` (50 default, 60, 0); 334 or 278 lines per period. Status line: measured fps,
  WB, exposure, gain, frame length, d, Y, P98, clipped %, m, failed control writes; `tools/isp_log_stats.py` reads it.
- Statistics: `struct frame_stats` replaces the out-parameters and the 16x16 zone arrays (zones were only for the
  removed dark-zone target); the stats pass now also returns the display luma of the sampled pixels.

`make test`: test_ae, test_lut, test_output ok. `tests/test_ae.c` (simulated sensor, latency AE_LATENCY_FRAMES):
(1) Y within 10% of 0.45 by frame 60 from E=4 and from E=2004/16x/d=2; (2) settled in light/20 with gain, then 8x
brighter: gain 0 and exposure lower within 90 frames; (3) light/40: gain only at 30 ms, frame length only at gain
3.95x, more gain only at 60 ms, ends at gain > 3.95x with Y on target; (4) a 2.2% window at 50x: Y >= 0.30;
(5) after frame 12, no frame-to-frame Y step over 12%, and under 3% once settled; (6) allocation over the whole
range at 50 Hz: product within 1%, gain 0 up to 1002 lines, exposure in whole 10 ms once >= 334 lines, frame length
1116 unless exposure > 1108, d in [1, 2]. Mutations, each caught: no backlight floor (once the window clips),
gain before exposure, never lowering, no damping, no flicker rounding (test_ae); no WB normalisation (test_lut).

Corpus (`isp_replay` now iterates the controller's metering on a virtual digital gain until it stops asking for a
change): every capture with signal settles at Y 0.45-0.48 (baseline 0.02-0.54); the darkest quarter rises on all
(e.g. normal_e600_g4 0.047 -> 0.159, backlit2_e600_g4 0.019 -> 0.169); clipped <= 0.3% except the backlit and dark
captures (<= 2.3%); raw-saturated highlights render neutral (hl_neutral 0.0). Covered-lens and dark captures show high
chroma noise because the replay boosts them digitally without limit; live, the controller lengthens the exposure.
`make bench`: 10.33 ms cpu 0, 20.53 ms cpu 12 (unchanged by the controller).

## Live: Q3b, Q1 and R3 in room light (2026-10-18 15:08, camera on, owner away with permission)

Deployed with `sudo -n ./gc2607-setup-service.sh unit` (CPUAffinity) and `make isp && sudo -n ./gc2607-install-isp.sh`
(`OK`); the ISP starts at 1920x1080 and `taskset -cp` shows 0-19. A 65 s `ffmpeg -f v4l2 -i /dev/video50 -f null -`:
- `v4l2-ctl -d /dev/video50 --get-fmt-video`: 1920/1080 YUYV. ffmpeg: 1931 frames, 30 fps, speed 1x.
- ISP CPU over 60 s of streaming (utime+stime from /proc): **43% of one core** (bar 75%).
- Status lines: 29.9 fps; exposure lowered from the 1002-line start to 668 (two 10 ms periods) at gain 0; d 1.11-1.33,
  never below 1; Y 0.40-0.42 with P98 0.90-0.93 and 1.9% of samples in the top bin (the room's bright window holds
  Y just under the 0.45 target through the highlight cap); 0 failed control writes.
- R3: streams normally on the driver with the new error path. Its suspend/resume check is still owed.
Light-change checks (lights off/on, backlit), the flicker capture and a few days of logs remain for the owner.

## E1 Reader detection by v4l2loopback's client-usage event (2026-10-18)

Verified in the installed v4l2loopback 0.15.4 source (`/usr/src/akmods/v4l2loopback-kmod-0.15.4-1.fc44.src.rpm`):
event type `V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1`, payload `{__u32 count}` = 1 while a reader holds the capture
stream (`client_usage_queue_event`, ~line 2147), queued on capture STREAMON and STREAMOFF and on close via REQBUFS(0);
`v4l2_loopback_poll` reports a pending event as POLLPRI to every opener. inotify and the /proc walk are gone; the idle
loop polls the output fd for POLLPRI with the 2 s standby timeout, the streaming loop polls it beside the capture fd
and stops 3 s after the count drops to 0. The standby frame is re-blacked after every session (the last camera frame
used to stay on the device for the next app). Unit and replay tests unchanged and passing (I/O only, no new test).

Live (`make isp && sudo -n ./gc2607-install-isp.sh`, `OK`): a 10 s ffmpeg read started streaming **0.15 s** after
ffmpeg opened the device and stopped **3.0 s** after it ended (bars 1 s and 5 s); `kill -9` of a streaming ffmpeg
stopped it **3.0 s** later; `systemctl --user restart wireplumber` with no app open started **no** stream in 10 s.
ffmpeg reported 5-6 "non monotonically increasing dts" warnings per 10 s run (repeated frames from the loopback);
not investigated. Idle CPU: `CPUUsageNSec` 8,103,450,000 at unix 1792332618; second reading owed (bar <= 0.6 s per
10 minutes).
