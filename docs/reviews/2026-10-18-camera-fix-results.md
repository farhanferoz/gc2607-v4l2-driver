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
not investigated. Idle CPU (`systemctl show -p CPUUsageNSec`, same invocation, no stream started in between):
8,103,450,000 ns at unix 1792332618, 8,370,610,000 at 1792333224, i.e. **0.27 s in 606 s, 0.26 s per 10 minutes**
(bar 0.6 s; ~19 s before).

## E2 v4l2loopback loaded once; WirePlumber restarted only when it misses the camera (2026-10-18)

New `gc2607-setup-service.sh loopback` writes `/etc/modprobe.d/gc2607-v4l2loopback.conf` (the options the service
used to pass) and `/etc/modules-load.d/gc2607-v4l2loopback.conf`; `modprobe --showconfig` shows ours as the only
v4l2loopback options line (the OBS and v4l2-relayd package files are masked to /dev/null in /etc since May).
`gc2607-service.sh` keeps a loaded module and refuses to start unless `/dev/video50` is named "GC2607 Camera". New
`scripts` sub-command installs the service scripts to /opt without the full setup.

Test without the WirePlumber restart (ExecStartPost removed, `pw-dump` node id, `wpctl status` sources, a 30-frame
ffmpeg read of /dev/video50):
- 3 service restarts: node 60 (serial 9131) kept every time, listed, 30 frames, WirePlumber not restarted. PASS.
- Boot order (measured this boot: WirePlumber 09:06:39, camera service 09:06:54), simulated by restarting WirePlumber
  while the service was stopped (`/dev/video50` then announces only Video Output): **no node, not listed, still
  none 2 minutes after the ISP was back**; ffmpeg on the device worked. PipeWire decides once whether a device is
  a camera and is not told when v4l2loopback's capabilities change. FAIL.

So the restart stays, conditionally: `gc2607-restart-wireplumber.sh` waits up to 15 s for the device to announce
capture, then restarts WirePlumber only if `pw-cli ls Node` lacks the camera's node, logging which it did (also
when there is no user session yet). With it installed: 3 restarts logged "already lists the camera; not
restarting it" (node 114 kept, WirePlumber start time unchanged); the boot simulation logged "did not list the
camera; restarted it" and the camera was listed and read 30 frames. The full setup no longer restarts WirePlumber
itself. Still owed [OWNER]: one suspend/resume (with R3's) and a browser camera test.

**A test-pipeline failure, not a camera fault (corrected the same day).** `gst-launch-1.0 pipewiresrc ! fakesink` got no
frames (auto-linked: "target not found"; linked by hand: PipeWire logged `error alloc buffers: Operation not supported
(-95)`, with the camera node's buffer parameters naming DmaBuf only, dataType mask 8). GNOME Snapshot 50.0, which opens the
camera through the portal (`org.freedesktop.portal.Camera.OpenPipeWireRemote` in its log) and so through PipeWire,
showed a picture at 16:21 with no PipeWire error: the failure belongs to that test pipeline's buffer negotiation.
A PipeWire stream check needs a real client (Snapshot), not `fakesink`.

## S1 Pipeline discovery by the graph's links (2026-10-18)

New `gc2607-media.sh`, sourced by `gc2607-service.sh` and `gc2607-raw-capture.sh` (installed to /opt by the setup's
`scripts` step): finds the media device holding an entity named `gc2607 *`, follows the sensor's pad-0 link to its
CSI2 receiver and the receiver's pad-1 link to the capture entity, and resolves the capture node and sensor subdev with
`media-ctl -e`, retrying every 0.5 s (service: up to 20 s) instead of the fixed 1 s + 2 s sleeps. One
`media_configure` sets the formats and link for both scripts. The service's `insmod` fallback from /opt (no .ko is ever
installed there) became a plain `modprobe gc2607`. Antonbiluta's `gc2607-isp-start.sh` (the handover's model) takes the
first CSI2 and capture entity by name pattern; following the links names the ones the sensor is wired to.

- Discovery on the laptop: `gc2607 5-0037` on /dev/media0 -> `Intel IPU6 CSI2 0` -> `Intel IPU6 ISYS Capture 0`,
  /dev/video0, sensor /dev/v4l-subdev6 (the values the hard-coded names gave). The receiver's pad 2 resolves to
  Capture 1, an unknown entity to nothing, and with the link parser stubbed out `media_discover 2` returns 1 after 2 s.
- Service restart: "Loading kernel modules" to the ISP's idle line in **0.09 s** (was 3.1 s); the stream starts and
  ffmpeg reads 30 frames; WirePlumber not restarted. `gc2607-raw-capture.sh --fps 36`: 29.90 fps, 0 new CSI error
  lines, service back and listed.
- Still owed [OWNER]: the stream starting first time on 3 boots/resumes.

## D2 Driver hygiene (2026-10-18)

Reset GPIO requested asserted (`GPIOD_OUT_HIGH`), so the sensor stays in reset from probe until `gc2607_power_on()`
releases it; a short I2C transfer is an error (-EIO): read when `i2c_transfer()` moves fewer than 2 messages, write
when `i2c_master_send()` sends fewer than 3 bytes (it returns bytes written, `include/linux/i2c.h` on 7.2.11, so the
handover's "`ret != 1` on write" would have failed every write); routine probe, power and stream lines to `dev_dbg`
("GC2607 probe successful" and the format line stay, `gc2607-reload.sh` greps the first); `MODULE_AUTHOR` names the
two authors in the file's git history in place of the "Your Name" placeholder.

`make modules`: only the usual pahole/BTF notes. `sudo -n ./gc2607-driver-install.sh`: DKMS for 7.2.9/7.2.10/7.2.11,
`OK` in 319 s; `/usr/src/gc2607-1.0/gc2607.c` = the working tree (md5 1538e25c). Kernel log after the reload: only
"GC2607 probe successful" and the format line per probe. A 5 s ffmpeg read: 126 frames; 0 "Failed to read/write reg"
lines; the camera node in PipeWire survived the driver reload. Still owed [OWNER]: one suspend/resume, then a stream.

## C1 Dead weight (2026-10-18)

Removed: `hal-config/` (HAL tuning and sensor config, dead per `docs/native_hal_investigation.md`; both HAL docs now say
how to restore it from git history), `ipu-bridge-oot/7.0.12/` (a June hand build for a kernel no longer booted; DKMS's
`ipu-bridge-gc2607` replaces it; no link or config on the laptop points into it), the disabled local tone mapping
(204 lines of `gc2607_isp.c`), the stale "zero CPU" comment, and the untested Python fallback (`gc2607_virtualcam.py`,
the service's fallback branch, the setup's Python search and `.python-path`; the setup's `scripts` step deletes the
copies in /opt). The full setup now refuses to run unless the ISP is built, instead of compiling it as root inside the
synced tree. `__pycache__/` is ignored. The "centre-weighted" comment had already gone with Q1.

Why the tone mapping stayed off, from its removed comment: with the knee at Y 120 or 200 alike, skin crossing the
knee moved the coarse grid's factor boundary and showed as patches that followed the face; a hard threshold on a
coarse grid cannot avoid that on textured skin.

`make isp` and `make modules`: no warnings (pahole/BTF notes only). `make test`: 3 ok. `make bench`: 10.44 ms cpu 0,
20.65 ms cpu 12 (unchanged). Deployed (`scripts` + `gc2607-install-isp.sh`, `OK`): the service starts, the camera is
listed and reads 30 frames.

Left for the owner: the two May copies of the service script in /opt/gc2607 (`gc2607-service.sh.bak-modload`,
`.pre-libcamera-bridge.bak`; `gc2607_isp.bak` is the ISP installer's rollback copy, rewritten on each install);
`gc2607-finalize.sh`, a June 7.0.12 migration script that pointed at `ipu-bridge-oot/` (a power script, outside this
work); and ~39 early experiment files in the repo root (`test_*.sh`, `view_raw*.py`, `QUICK_TEST.sh`,
`start_camera_service.sh`, `reload_for_chrome.sh`, ...), outside the handover's list.

## Q9 White balance robustness (2026-10-18)

Grey-world gains relative to green are held to red 1.27-2.94 and blue 1.24-2.62: the range in 60 days of logs (red
1.53-2.45, blue 1.49-2.18 over 4,520 status lines, re-measured from the journal) widened by 20% each way. The statistics
skip samples whose brightest channel is within 4 counts of black, and a frame with under 1% usable samples keeps the
previous balance.

The near-black threshold was measured, not taken from the handover: replaying the corpus with 0, 4, 8 and 16 counts,
the low-signal neutral captures (`flat_*`, `wall_e644`, ~9-12 counts of signal) came out no more neutral at any
threshold and less neutral at 16 (centre chroma flat_e450 9.25 -> 9.79, wall_e644 9.39 -> 10.22); 4 changed them by
at most 0.04. The black level is accurate (T0.2-T0.4), so the exclusion only guards against a future offset.

`make test`: 3 ok. New checks in `tests/test_lut.c`: half the frame 3/1/1 counts above black leaves the balance at the
grey card's (R/G 2.000, B/G 1.765, within 0.01); a blue wall over 85% of the frame keeps the gains inside the limits
and the grey card's worst channel error under 45% (42.5%; unlimited grey world: R/G 2.85, B/G 0.63, 64%, the
handover's "less cast in a grey ROI than the baseline"). Mutations, each caught: the old 0.25-4 bounds fail both
blue-wall checks; dropping the near-black test moves the balance to R/G 1.967.

Corpus (`isp_replay` against C1, `/home/ff235/cache/gc2607/replay/{c1,q9}_metrics.json`): every neutral capture within
0.04 of centre chroma. The colour-dominated captures are now held: the finger over the lens (red light, dark_e2000_g16)
kept red gain 1.27 where grey world asked 0.70, so it renders red instead of grey (chroma 31.9 -> 43.4), and the opaque
cover's noise no longer sets the gains. The corpus has no grey patch inside a one-colour scene, so the cast reduction
itself is shown by the unit test only. Live after `gc2607-install-isp.sh`: WB R 2.16, B 1.90, Y 0.456, 29.2 fps.

## Q1 live: light changes, backlight, flicker (2026-10-18 16:15-16:27, owner at the laptop)

Light changes (180 s ffmpeg read, a frame saved every 5 s to `/home/ff235/cache/gc2607/q1-live/`): room light 30 ms,
gain index 3, 29.9 fps; lights off 60 ms, index 15, frame length 2012 (16.8 fps); lights on (a warmer light than at the
start) back to 30 ms within one status line (~5-7 s), index 15 -> 8 -> 7; back to the starting light: index 1, 29.9 fps.
Exposure lowered twice, so no ratchet; Y 0.44-0.46 in every phase; d 1.01-1.28, never below 1; 0 failed control writes.
One saved frame (the second the lights came on) is washed out; the next, 5 s later, is normal. The handover's "gain index
back to 0" does not apply as written: this room in the evening needs index 1-3 at 30 ms.

Backlight (desk lamp in frame behind the owner, 32 s): Y 0.409-0.416 (floor 0.30), 1.7% of samples clipped (the lamp),
P98 0.89-0.94, 60 ms at index 13 in a dim room; the face is clearly visible in all six saved frames.

Flicker (`gc2607-raw-capture.sh flicker 450:8:36 668:6:36`, a light wall under the ceiling LEDs, ~60 counts of green
signal): the handover's metric (cubic-detrended row means, one frame) reads 14.0% and 13.7%, the wall's own shading, so
it cannot answer the question on a real surface. Dividing each frame's green row profile by the 5-frame mean cancels the
static scene and keeps the banding that moves (a frame is 33.45 ms, the light's period 10 ms): at 450 lines (13.5 ms)
the 10 ms component is 1.09-1.48% per frame, ~30x the rest of the spectrum (0.04%); at 668 lines (20.0 ms, two whole
periods) 0.11-0.28%. **The room lights flicker at 100 Hz and whole-period exposures cut the banding ~6x.**

## Q8 measurement: lens shading (2026-10-18 ~16:30, owner at the laptop)

White printer paper flat over the lens. Facing a desk lamp 1-2 m away (`flatfield_e{40,120,360,1000}_g0_vb36`): only
18 counts of green at 33 ms, too dim to trust, and a lamp seen through paper could make a centred hot spot with the
same shape. Facing daylight through a window (`dayflat_e400_g0`, `_e1100_g0`, `_g2`, `_g4`, all `_vb36`, 42-233 counts
mean, 0% clipped; a first set at gain index 10-16 clipped 12-73% and was deleted): corner/centre (`raw_metrics`, corner
windows 1/20 of each side) 0.21-0.24 on every channel at every setting (gr 0.213-0.227, r 0.227-0.241, b 0.215-0.227).
Green over a 5x5 grid, relative to the centre cell, at 1100 lines index 2:

    0.30 0.51 0.66 0.53 0.30
    0.36 0.67 0.90 0.68 0.37
    0.40 0.78 1.00 0.77 0.40
    0.40 0.73 0.91 0.72 0.39
    0.36 0.60 0.71 0.59 0.33

The lamp capture gave the same ring within a few hundredths, so the falloff belongs to the lens, not the light. It is
mostly luminance (the channels within ~0.03 of each other); the bottom row is ~0.05 brighter than the top, likely the
window's own gradient. Every channel is far below the handover's 0.8 trigger: Q8's correction is warranted.

## Q8 correction: lens shading (2026-10-18 evening)

**Table.** `tools/lsc_calibrate.py` fits each `dayflat_*` capture (frames averaged, 10x10-pixel blocks of each Bayer
plane) in the log domain with a polynomial in even powers of the offset from the frame centre on each axis, so the
fit is symmetric left-right and top-bottom, and writes `gc2607_lsc_table.h`: luminance gain (centre green / green)
and red and blue colour gains at 32 x 18 nodes spanning the frame corner to corner.
- Symmetry is measured, not assumed: the falloff's peak sits within ~1 block (2% of the width) of the centre in all
  eight flat fields, and what the symmetric fit leaves over (rms 1.9-5.5%) follows the light, not the lens: the four
  daylight captures correlate with one another at +0.73..+0.91, the two lamp captures with them at -0.54..+0.26 and
  with each other at -0.79.
- Fit: luminance to the 8th power (u^2i v^2j, i+j <= 4; symmetric residual max 1.4-2.6%), colour ratios to the 4th
  (0.8-2.3%). The four captures' own tables agree with their mean within 2.0-4.7% (luminance) and 0.2-1.4% (colour).
- Colour shading is real: red/green rises to 1.057-1.069 of the centre at the corners in all four daylight captures
  (lamp 1.045); blue/green moves 1-2%. Hence per-channel gains (corner: luminance 5.51, red 0.936, blue 1.009).
- Grid: bilinear interpolation against the fitted surface, max/mean error 3.8/1.25% at 16 x 9 (the handover's
  example), 1.9/0.50% at 24 x 14, **1.2/0.29% at 32 x 18**, 0.8/0.18% at 40 x 23. 32 x 18 sits below the fit's own
  uncertainty.

**ISP.** `lsc_row()` corrects each raw row as it is read, for all three readers (`collect_stats`, `load_padded_row`
for the 1080p demosaic, `bin_half`): `64 + (raw - 64) * gain`, Q12 gains, clamped to 10 bits; a value clipped at the
sensor (1023, where the corpus's highlights pile up) stays clipped. Strength follows libcamera's ALSC
(`src/ipa/rpi/controller/rpi/alsc.cpp`, `addLuminanceRb`/`addLuminanceG`: `lambda * ((lut - 1) * strength + 1)`):
only the luminance part is scaled, the colour part is always whole. `GC2607_ISP_LSC` = 0..1 or `off`; **default
0.7** (libcamera's tuning example uses 0.7, its run-time default is 1.0). The start-up log line names the strength.

**Validation.**
- `--verify` (raw corner/centre per channel, `raw_metrics`), full strength: dayflat 0.964-1.070 on every channel
  (before 0.206-0.241); lamp `flatfield_e1000` (not used in the fit) 0.964-1.054 (before 0.210-0.224). The dimmest
  lamp capture, `flatfield_e360` (6.8 counts mean, ~2 counts above black in the corners, where the black level is
  known to ~0.3 counts), gives 0.86-0.98: below the noise floor, not counted.
- `GC2607_ISP_LSC=off` reproduces the shipped ISP (13e8bca) byte for byte on all 18 corpus frames at both output
  sizes (36 replays).
- `tests/test_lsc.c`: a frame shaded exactly as the table says comes out flat (within 4 counts, the rounding of the
  shaded input times the gain) through `lsc_row`, through the statistics (green mean within 2%) and at the corners of
  both output sizes (within 2 levels; without correction > 40, so the check can see shading); half strength scales
  only the luminance part; a clipped red stays clipped where its colour gain is below 1; `GC2607_ISP_LSC` parsing.
  Each guard was broken once and went red (9 mutations: no gain, no vertical interpolation, statistics or binned path
  uncorrected, no clip guard, strength applied to colour too, two parser relaxations, colour sites swapped).
- `make bench` (laptop, median of 200, correction at 0.7): 1080p **10.04 ms on cpu 0** (bar 13; off 9.18),
  **21.20 ms on cpu 12** (bar 22; off 18.72), 37.03 ms on cpu 20 (off 32.04; the unit's `CPUAffinity=0-19` keeps the
  service off cpus 20-21). The first version cost 13.49 / 28.66 ms: GCC refused to vectorise the row loops at -O2
  ("would need a runtime alias check", `-fopt-info-vec-missed`); `restrict` on the row pointers vectorises both
  (32-byte vectors) and also sped up the off path (10.54 -> 9.18 ms on cpu 0). Output unchanged (off: the 36
  byte-identical replays; 0.7: identical to the pre-`restrict` renders).
- `make test` on the laptop: test_ae, test_lut, test_output, test_lsc ok.
- Corpus replays at strength off / 0.5 / 0.7 / 1 (display luma, corners = outer tenth of each side, temporal noise =
  std of the difference of frames 3 and 4 over sqrt 2, 0-255):

| Capture | corner/centre Y | corner noise | frame mean Y |
|---|---|---|---|
| room-day_e1002_g4 | 0.52 / 0.82 / 0.91 / 1.03 | 1.60 / 2.01 / 2.09 / 2.11 | 116 / 116 / 116 / 114 |
| dim_e2000_g8 | 0.67 / 1.08 / 1.21 / 1.38 | 7.22 / 9.17 / 9.69 / 10.04 | 117 / 116 / 117 / 116 |
| backlit2_e600_g4 | 0.68 / 1.07 / 1.19 / 1.34 | 8.30 / 10.70 / 11.08 / 11.53 | 116 / 118 / 117 / 116 |
| normal_e600_g4 (evening) | 1.80 / 2.95 / 3.33 / 3.88 | 3.93 / 4.13 / 4.20 / 4.19 | **115 / 97 / 95 / 90** |

  Corner noise rises ~25-40% with any correction and only ~4% between 0.7 and 1. Viewed at 1:1 (dim and backlit
  corners): visible but modest at 0.7.
- **Known cost: evening scenes with bright edges render darker.** In `normal_e600_g4` the ceiling lights and the
  walls by the top corners, which the lens had dimmed, now reach the highlight cap (replay: P98 = 0.920, the cap),
  so exposure comes down and the frame mean falls from 0.445 to 0.368 at 0.7 (the face visibly darker); the other
  scenes keep their brightness. The cap is this ISP's own design (Q1: P98 <= 0.92 always); libcamera's default
  "normal" constraint mode has no upper bound on highlights (only "highlight" mode does; imx219.json). In today's
  status lines the cap already bound in 25 of 69 (P98 >= 0.89 or >= 2% clipped). Not changed here: weighting the
  metering towards the centre (or relaxing the cap) is a separate exposure decision. `GC2607_ISP_LSC=off` restores
  the old rendering.

## Chroma filter for the full-resolution output (2026-10-18 evening)

Trigger: the owner's 18:01 frame (exposure 2004, gain index 16, d 2.00, 16.5 fps, Y 0.40: every limit reached in a
room giving ~1/10 of the 16:52 light) showed coloured speckle. Q3b had measured that cost and parked it ("re-measure
after Q1 before adding a chroma filter"); the re-measure had not been done. Temporal noise (std of frames 4 - 3 over
sqrt 2, centre half, 0-255), full resolution vs the binned path: chroma 8.63 vs 3.62 (dim_e2000_g8) and 4.31 vs 1.87
(normal_e600_g4), luma 5.33 vs 5.75 and 3.63 vs 3.83. So 2.3-2.6x the colour noise in room light too, not only in
the dark; brightness grain is the sensor's and the same either way.

- Change: `chroma_box_row()`, the mean of U and V over 3 pairs x 5 rows (6 x 5 pixels), Y untouched, run inside the
  demosaic loop two rows behind the writer. Size from a prototype on the replays: 3x3 pairs x rows 4.76 / 2.37,
  3x5 3.92 / 1.96, 5x5 3.16 / 1.59 (dim / normal); 3x5 is the smallest that matches the binned path. The binned
  path's 3x3 median would cost ~24 ms at this size.
- Cost (`make bench`, lens shading on): cpu 0 10.0 -> 11.4 ms, cpu 12 21.2 -> 24.2 ms. Two slower versions first:
  a separate pass reading U and V out of the interleaved bytes (+3.5 / +5.6 ms; filter alone 2.8 / 6.2 ms) and the
  same inside the demosaic loop (no gain: the cost was arithmetic, not memory). The kept version works on the
  16-bit words (U and V are the high bytes of alternate words), so every loop is contiguous and vectorises, and
  divides by 15 as `(s + 7) * 4370 >> 16` (exact for every sum up to 15 x 255, checked exhaustively). Its output
  is byte-identical to the first version on all six replayed frames.
- Live, dark room (exposure 2004, gain 16, 16.5-17 fps), ISP CPU over 10 s of streaming: 39% of a core before,
  35% after: no measurable change at this frame rate (run-to-run variation is larger than the cost).
- `GC2607_ISP_HALF_RES=1`: byte-identical to before on all six frames.
- Corpus (31 captures, HEAD vs this): y_mean, clipped and luma noise identical everywhere; `false_colour` (mean
  chroma magnitude, centre half, includes real colour) halves on flat and dark captures (flat_e600_g4 6.95 ->
  3.48, dark2_e600_g4 73.1 -> 32.6) and falls 9-10% on coloured real scenes (room-day_e900_g4 5.87 -> 5.30,
  texture_e600_g4 5.05 -> 4.60), so real colour stays.
- Tests (`tests/test_output.c`): an impulse of U +30 must become +2 over exactly 3 pairs x 5 rows with Y and V
  untouched; the step edge may now colour one pair further each side and must do so (proves the filter runs on
  the output). Mutations: filter call removed -> the step check fails; the outer two rows dropped -> the impulse
  check fails (3 of 15).
- Installed 18:30 (sha256 7b1e2274...e388 in /opt and the build); `make test` ok.
