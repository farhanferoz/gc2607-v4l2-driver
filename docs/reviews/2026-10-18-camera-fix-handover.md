# GC2607 camera: findings and fix handover (2026-10-18)

For an implementing agent. Every task has: the **evidence** that it is broken today (reproducible), the
**change**, and the **validation** that proves it works afterwards. Read section 0 before touching anything.
Background: `docs/reviews/2026-10-18-camera-stack-review.md` (robustness review) and
`docs/reviews/2026-10-18-community-comparison.md` (five community projects).

## 0. Rules

- Work on the laptop (`fedora`) in `/home/ff235/dev/gc2607-v4l2-driver`. It is on branch
  `hibernate-resume-off` at `98c64a1`. Create your branch in place with `git switch -c camera-quality`
  (same commit, no file changes). **Never check out another branch or commit**: this working tree's power
  scripts are run as root at boot and suspend.
- Password-free root exists only for `/home/ff235/dev/gc2607-v4l2-driver/gc2607-*.sh`, `modprobe`,
  `rmmod`, `insmod`, `depmod`, `media-ctl`, `v4l2-ctl` and `dmesg` (`sudo -n -l`). Anything else needing
  root (systemctl, files in /etc or /opt) goes into a `gc2607-*.sh` script run with `sudo -n`, or ask the owner.
- Deploy the ISP with `make isp && sudo -n ./gc2607-install-isp.sh` and the driver with
  `sudo -n ./gc2607-driver-install.sh` (DKMS; both restart the service and roll back on failure).
- **Steps marked [OWNER] turn the camera on (privacy light) or need the owner's hands.** Ask before each
  one. Never stream the camera at any other time.
- Raw captures go to `/home/ff235/cache/gc2607/`, never under `~/dev` (synced to other machines).
- One commit per task, including its tests. Do not push or merge; the owner decides.
- Out of scope: the non-camera power scripts (hibernate, suspend, NVMe, boot-incident, crash-triage),
  the libcamera and Intel-HAL routes, and the workspace-sync repo (its camera gate check is done there).
- Record each task's validation commands and numbers in `docs/reviews/2026-10-18-camera-fix-results.md`.
- Order: Phase 0 first (it builds the tools every later check uses). Phase 1 tasks are independent.
  Phase 2 before Phase 3. Q5 lands with Q1. E2 only after E1.

## 1. Objectives and what was found

| Outcome | How it was measured | Today | Task |
|---|---|---|---|
| Resolution apps receive | ISP code (`OUT_W`, `process_frame`) | 960x540, a quarter of the sensor's 1920x1080 | Q3b |
| Exposure follows the light, both ways | 60 days of ISP status lines (Appendix A) + code | Broken: never lowered in 15 runs | Q1 |
| Mid-tones and shadows rendered correctly | LUT maths + logs | Mid-grey 83/255 instead of ~117 | Q2 |
| Noise (gain policy) | Logs | Gain never below 2x | Q1 |
| Neutral highlights | LUT maths + logs | Faint pink when software gain < 1 (26% of time) | Q5 |
| Edge colour | Code | Colour from one pixel of each pair | Q3a |
| Motion | Logs, code | 16 fps, exposures up to 62 ms | D1, Q1 |
| No mains flicker banding | Code | No anti-flicker; banding not measured | Q1 (Q7) |
| Colour accuracy | Code | No colour matrix; flat 1.25x saturation stand-in | Q4 |
| Even brightness to the corners | Code | No lens-shading correction; not measured | Q8 |
| CPU while idle | systemd CPU accounting | ~3% of a core | E1 |
| CPU while streaming | Per-frame timing on the laptop (Appendix B) | 8.6 ms/frame on a performance core | Q3b |
| Install, update, robustness | First review | 4 defects | R1-R4, E2, S1, D2, C1 |

## 2. Evidence register (reproduce these first)

**ISP logs, 2026-08-19 to 2026-10-18** (Appendix A; 4,517 status lines of 150 frames each):
- 15 service runs; exposure was **never lowered** in any of them; 2 runs reached the maximum (2002 lines).
- 73% of streaming time at exposure 600 lines (~18.6 ms), the ISP's start-up value; 19% at 2002 (~62 ms).
- Gain index histogram: 4 (2.0x) 3,719 lines, 6 (2.9x) 445, 8 (4.0x) 353. **Never below index 4.**
- Gain > 0 while exposure < max: 81% (exposure could have risen and gain fallen instead).
- Hardware exposure/gain changed in **0%** of 9-second intervals within a run.
- Highlight cap more restrictive than the mean target: **100%**. Cap at its floor (>= 2% of samples
  clipped at the sensor): 20%. Software brightness < 1.0: 26% (< 0.9: 20%).
- Rendered levels (curve maths applied to logged means): darkest quarter of zones median **57/255**
  (95 with a plain 2.2 gamma); frame mean 125 (146).
- Frame rate: 150 frames per ~9.3 s = **16.1 fps**.

**Per-frame CPU** (Appendix B, laptop, `-O2 -march=native`, synthetic 1920x1080 frame, median of 200):

| Core (`taskset`) | Today's ISP, 960x540 | of which 3x3 chroma median | antonbiluta full 1080p (bilinear + rotate) |
|---|---|---|---|
| cpu 0 (performance, 2.3 GHz max) | 8.67 ms | 5.95 ms | 12.13 ms |
| cpu 12 (efficiency, 1.8 GHz) | 13.56 ms | 9.33 ms | 23.68 ms |
| cpu 20 (low-power, 1.0 GHz) | 23.77 ms | - | 39.70 ms (over the 33 ms a 30 fps frame allows) |

`lscpu -e`: cpus 0-11 performance (2300 MHz max), 12-19 efficiency (1800), 20-21 low-power (1000).

**Idle CPU:** 369 CPU-s in ~3 h 15 min with no consumer (~3%), i.e. ~19 s per 10 minutes:
`systemctl show -p CPUUsageNSec gc2607-camera.service`, read twice 10 minutes apart.

## 3. Phase 0: tools and baseline (before any fix)

**T0.1 Evidence tools.** Commit Appendix A as `tools/isp_log_stats.py` and Appendix B as
`tools/bench_isp.c` + `tools/bench_common.h` with a `make bench` target. Run both. Done when the output has
the same shape as section 2 (log numbers drift as the journal window moves; timings within ~15%).

**T0.2 Raw capture script** `gc2607-raw-capture.sh SCENE EXPOSURE GAIN_IDX [FRAMES=5]` (root via the
sudo rule). Steps: refuse if a consumer is streaming; `systemctl stop gc2607-camera.service`; find the media
device and capture node and set formats/links exactly as `gc2607-service.sh` does; find the sensor subdev
(the `/dev/v4l-subdev*` whose `v4l2-ctl --list-ctrls` shows `exposure`); set `exposure` and
`analogue_gain`; capture with `v4l2-ctl -d $CAP --set-fmt-video=width=1920,height=1080,pixelformat=BA10
--stream-mmap=4 --stream-skip=10 --stream-count=$FRAMES --stream-to=$OUT.raw` (frames are 1920x1080
little-endian uint16, 3840 bytes per row); write `$OUT.json` (scene, exposure, gain index, time, frames);
`chown ff235`; restart the service in a `trap` so it restarts on any exit. Output under
`/home/ff235/cache/gc2607/raw/<YYYY-MM-DD>/`.

**T0.3 [OWNER] Corpus capture** (~10 minutes, ~230 MB). Scene: settings (exposure lines / gain index):
- `normal` (owner at the desk, room lights): 600/4 and 1200/0
- `backlit` (window or bright lamp behind the owner): 600/4 and 300/0
- `dim` (lights low or off): 2000/8 and 2000/4
- `texture` (fine-patterned neutral fabric or small print ~30 cm away): 600/4
- `flat` (white paper ~3 cm from the lens, evenly lit, room LED lights on): 600/4 and 450/4
- `dark` (lens covered): 600/4 and 2000/16

**T0.4 [OWNER, ~5 s camera] Sensor latency** `tools/ae_latency.c`: stream the capture node, at frame 20
double the exposure through the subdev, print the mean green of frames 15-30; repeat with gain index +4
(~2x). K_exp and K_gain = (first frame whose mean moved > 30%) - 20. Record both; Q1 needs them.

**T0.5 Replay and metrics.** `tools/isp_replay.c` includes `gc2607_isp.c` with `main` renamed (as
Appendix B does), runs `process_frame` on corpus frames with WB gains and brightness from arguments, and
writes PPM files. `tools/isp_metrics.py` (numpy) computes: display mean; darkest-quarter-zone mean (16x16
zones); clipped fraction (Y >= 250); highlight neutrality (mean |R-G| and |B-G| where all three raw channels
>= 1008); false colour (mean chroma magnitude in a given neutral ROI); flat-field corner/centre ratio per
raw channel; row banding (std of detrended row means / mean, `flat` scene). Run it on the corpus with today's
code and save `tools/baseline_metrics.json`. Every later image check compares against this file.

## 4. Phase 1: small fixes (independent)

**R1 Full setup script aborts.**
- Evidence: in `gc2607-setup-service.sh`, the line `install -m 0644 "${SCRIPT_DIR}/gc2607-camera.service"
  /etc/systemd/system/gc2607-camera.service` is followed by a leftover block from `[Unit]` to `SVCEOF` (old
  heredoc body; its opener was removed in 0030017). Under `set -e`, `[Unit]` runs as a command, exit 127,
  before `daemon-reload`, `enable` and `start`. `bash -n` passes. Shown by
  `grep -n -E '^\[Unit\]$|^SVCEOF$' gc2607-setup-service.sh` (two hits).
- Change: delete that block, `[Unit]` through `SVCEOF` inclusive.
- Validation: the grep returns nothing; `bash -n` passes; the next non-blank line after the `install` line
  is `systemctl daemon-reload`. A full run only with the owner's OK (it rewrites WirePlumber config):
  `sudo -n ./gc2607-setup-service.sh` exits 0 and the unit is active.

**R2 Kernel-update runbook is the dangerous old method.**
- Evidence: `docs/operations-runbook.md`, section "After a kernel update", says to hand-build and copy
  `gc2607.ko` and a pinned `ipu-bridge-oot/7.0.12` build: the method that silently put the January driver
  back on 7.2.5-7.2.7 (header of `gc2607-driver-install.sh`). DKMS now rebuilds both: `dkms status` shows
  `gc2607/1.0` and `ipu-bridge-gc2607/1.0` installed for 7.2.9, 7.2.10 and 7.2.11. `README.md` (~lines 90,
  144) still points at upstream `init_camera.sh`; `gc2607-install.sh` (~lines 78, 140) hard-codes
  `kernel/v6.x` URLs.
- Change: replace camera steps 1-2 of that section with: `dkms status | grep -E 'gc2607|ipu-bridge-gc2607'`
  must show `installed` for the new kernel, otherwise `sudo dkms autoinstall -k <kver>`; a changed driver is
  installed with `sudo ./gc2607-driver-install.sh`; reboot; `bash gc2607-health.sh`. Keep step 3 (boot
  flags). Mark `gc2607-install.sh` and the `init_camera.sh` references historical, pointing to DKMS.
- Validation: no `ipu-bridge-oot/7.0.12` or `make -C /lib/modules` left in that section; the `dkms status`
  command runs as written (paste its output into the results file).

**R3 Failed probe leaves the sensor powered** (review #7).
- Evidence: `gc2607_probe()` powers the sensor with `pm_runtime_resume_and_get()`. If `gc2607_detect()`
  fails it jumps to `err_power:`, which does `pm_runtime_put_noidle()`, then `pm_runtime_disable()` and
  `pm_runtime_set_suspended()`. The suspend callback never runs, so regulators, clock and GPIOs stay on.
- Change: make `gc2607_power_off(gc2607);` the first statement under `err_power:`.
- Validation: `make modules` with no new warnings; install; `sudo -n dmesg | grep 'GC2607 probe successful'`
  after the reload; [OWNER] a 5-second stream works; one suspend/resume, then it streams again.

**R4 Rollback checks run before the ISP has started** (review #6).
- Evidence: `gc2607-install-isp.sh` and `gc2607-driver-install.sh` test `systemctl is-active` 2 s after the
  restart, but `gc2607-service.sh` reaches `exec gc2607_isp` only after ~3.5 s. Reproduce: build a binary
  that exits 1 (`printf 'int main(void){return 1;}' | gcc -x c -o gc2607_isp -`), run
  `sudo -n ./gc2607-install-isp.sh`: it prints OK. Restore at once with `make isp` and the install script.
- Change: replace the fixed sleep with a loop of up to 15 s that passes only when the journal since the
  restart contains `[gc2607_isp] Idle, waiting for consumers` and the unit is active; otherwise roll back.
  Same in `gc2607-driver-install.sh`.
- Validation: the bad-binary test prints FAILED and rolls back, and the unit is active again with the good
  binary; a good install prints OK within 15 s.

## 5. Phase 2: image pipeline (validated offline against the baseline)

**Q2 Contrast curve applied to linear values (dark mid-tones and shadows).**
- Evidence: `build_luts()` applies smoothstep to linear values and then `powf(v, 1/2.2)`. 18% grey comes out
  at 83/255 (about 117 with standard encoding); 5% at 27 (63). Logs: darkest quarter median 57 vs 95. The
  exposure logic compensates with a dark-zone target (100/255 linear) it never reaches.
- Change, per channel: `v = clamp(linear * wb_gain * digital, 0, 1)`; `e` = sRGB encoding
  (`12.92*v` if `v <= 0.0031308`, else `1.055*pow(v, 1/2.4) - 0.055`); `s = e + 0.25*(smoothstep(e) - e)`;
  `LUT = round(255*s)`. The contrast now acts on display values and is mild.
- Validation: unit test `tests/test_lut.c` (gains 1, digital 1): raw 64 -> 0; raw 1023 -> 255;
  raw 64+0.18*959 -> 116 +/- 2; raw 64+0.05*959 -> 57 +/- 3; LUT never decreases. Corpus vs baseline:
  darkest-quarter mean on `normal` and `backlit` rises; clipped fraction rises by at most 1 point.

**Q5 Faint pink highlights** (land together with Q1).
- Evidence: a raw-saturated green maps to `digital` (< 1.0 gives < 255) while red and blue, with white-balance
  gains near 2, still reach 255. Digital < 1 in 26% of logged time; at the usual floor 0.87 whites are
  (255, 250, 255), and dips toward 0.5 give about (255, 186, 255).
- Change: (a) divide all three WB gains by the smallest, so every gain is >= 1.0; (b) digital gain never
  below 1.0 (Q1 does reductions in hardware instead).
- Validation: unit test: raw (1023, 1023, 1023) with gains (2.2, 1.0, 1.65), digital 1.0 -> (255, 255, 255);
  gains (0.9, 1.0, 1.4) after normalisation -> (255, 255, 255). Corpus `backlit`: highlight neutrality <= 2.

**Q3a Colour taken from one pixel of each pair.**
- Evidence: `rgb_to_yuyv()` computes U and V from the first pixel of the pair only.
- Change: compute U and V from the average of the two pixels.
- Validation: unit test: the pair (255,0,0), (0,0,255) gives the U and V of (127.5, 0, 127.5), +/- 1.

**Q3b 960x540 output.**
- Evidence: `OUT_W = SENSOR_W/2` and 2x2 binning in `process_frame()`; `v4l2-ctl -d /dev/video50
  --get-fmt-video` shows 960x540 YUYV.
- Change: full-resolution bilinear demosaic to 1920x1080 YUYV, with the 180-degree rotation written
  straight into the output (no second pass) and statistics as today. Reference: `demosaic_full()` in
  github.com/antonbiluta/gc2607-driver at `fd3ea57acaac`, `gc2607_isp.c` lines 186-252 (MIT licence: keep
  its notice if you copy code). Leave the 3x3 chroma median out of this path: it is 5.95 of today's 8.64 ms
  at 960x540 and would cost ~24 ms at 1080p. Keep the binning path behind `GC2607_ISP_HALF_RES=1` as a
  fallback. Resize `yuyv_buf`, `open_output()` and the standby frame. Add `CPUAffinity=0-19` to
  `gc2607-camera.service` (keeps it off the low-power cores 20-21).
- Validation: `make bench`: the new path's median is <= 13 ms on cpu 0 and <= 22 ms on cpu 12. Unit tests:
  a uniform Bayer frame (R sites 500, G 300, B 200) gives identical Y/U/V everywhere; a vertical step edge
  produces colour only in the 2 columns beside it. Corpus `texture`: false colour <= 1.2x baseline (if not,
  add a cheaper chroma filter and re-measure). Live [OWNER]: `--get-fmt-video` shows 1920x1080;
  `ffmpeg -f v4l2 -i /dev/video50 -t 20 -f null -` runs at the sensor rate; the ISP's CPU over 60 s of
  streaming (utime+stime from `/proc/<pid>/stat`) is <= 75% of one core; `taskset -cp $(pidof gc2607_isp)`
  shows 0-19.

## 6. Phase 3: 30 fps and exposure control

**D1 30 fps timing with a slower frame rate in dim light (driver).**
- Evidence: `gc2607.c` uses HTS 2048 / VTS 2003, measured 16.1 fps. `max_fps = 30`, the probe log line and
  `V4L2_CID_PIXEL_RATE` (134.4 MHz, the MIPI bus rate, not the readout rate) all misreport it.
  AlexDaichendt measured 29.90 fps with no CSI errors on this board's 19.2 MHz clock, stock PLL, with
  HTS 1959 (0x0342/0x0343 = 0x07a7) and frame length 1116 in both 0x0220/0x0221 and 0x0340/0x0341 (0x045c).
  Source: github.com/AlexDaichendt/gc2607-camera-linux at `5febb7200c3b`,
  `gc2607-kernel/FINDINGS.md` "Hardware results" and "Shipped fix (pathB)".
- Change: (1) init registers HTS 1959 and frame length 1116 (our init writes 0x0340/0x0341 = 0x0a6e today;
  set it to 1116 too). (2) VBLANK writable 36..1152 (frame length 1116..2232 = 29.9..15 fps), writing both
  register pairs as Alex's `gc2607_s_ctrl` does, and re-ranging EXPOSURE to [4, frame length - 8] with
  `__v4l2_ctrl_modify_range` when VBLANK changes. (3) PIXEL_RATE = 1959 x 1116 x 29.90 = ~65.37 MHz;
  HBLANK 39, read-only. (4) `max_fps` and the probe log report 30. (5) Defaults: exposure 1000, gain index 0.
  Keep the gain control as the 0-16 table index.
- Validation: builds; `v4l2-ctl -d <subdev> --list-ctrls` shows `vertical_blanking` writable 36..1152 and the
  new pixel rate; [OWNER] at VBLANK 36, `v4l2-ctl --stream-mmap --stream-count=300` on the capture node
  reports >= 29.5 fps and `sudo -n dmesg` shows no new CSI or CRC errors; at VBLANK 1152 about 15 fps; the
  exposure maximum reads 1108 at VBLANK 36 and 2224 at 1152.

**Q1 Exposure control (ISP), including anti-flicker.**
- Evidence (section 2): never lowered in 15 runs; stuck at the start-up 600 lines and 2x gain; ratchets to
  62 ms and 4x after dim use until the next resume restarts the service; hardware changed in 0% of
  intervals. Cause in code: hardware reduction needs brightness < 0.8, but the highlight cap can never go
  below 0.869 (= 220 x 959 / (952 x 255)); gain only falls once exposure reaches 4 lines; the dark-zone target
  is unreachable, so the cap always rules.
- Change: one controller replaces both the brightness loop and the "Hardware AE" block in `streaming_loop()`.
  - State: exposure E (lines), gain index g (real gain = code/64, Appendix C), frame length F, digital d in
    [1.0, 2.0]. Total T = E x gain(g) x d.
  - Metering per frame: display mean Y (luma 0.299R + 0.587G + 0.114B of the sampled output pixels, 0..1);
    P98 = 98th percentile of linear green x d (existing histogram); clipped = at least 2% of samples in the
    top raw bin (>= 1008).
  - Desired factor: m = min(m_mean, m_cap), with m_mean = (0.45 / Y)^2.2 and m_cap = 0.80 if clipped, else
    0.92 / P98. Backlight floor: if that would leave Y below 0.30 (predicted Y x m^(1/2.2)), use
    m = (0.30 / Y)^2.2 instead, so highlights clip but the subject stays visible. Limit m to [0.5, 2.0]; if
    |log2 m| < 0.05 do nothing; apply m^0.3 per update (m^1.0 for the first 10 frames of a session).
  - Allocate T' = T x m in this order, and release in reverse: exposure up to 1002 lines (30 ms) at gain 0,
    d 1.0; then gain up to index 8 (3.95x); then frame length up to 2232 with exposure up to 2004 lines
    (60 ms, 15 fps); then gain up to 16; then d up to 2.0. Within a step use the largest gain index with
    E x gain <= T' and set d = T' / (E x gain), at most 1.23 (the largest table step). F = max(1116, E + 8).
  - Anti-flicker (`GC2607_ISP_FLICKER_HZ`, 50 default, 60, or 0 = off): when E >= one flicker period (50 Hz:
    10 ms = 334 lines at 29.97 us/line; 60 Hz: 278 lines), round E down to a whole number of periods and
    make up the rest with d.
  - Write hardware at most once every K+1 frames (K = max of T0.4's two values). When E grows past the
    current frame length write VBLANK first; when it shrinks write EXPOSURE first. Switch d to its new
    value K frames after the write, and skip metering on those K frames.
  - Keep the state across sessions (now safe); first start E 1002, g 0, d 1.0.
  - Status line every 150 frames: measured fps, E, g, F, d, Y, P98, clipped %, m. Extend Appendix A for it.
- Validation:
  - Unit tests `tests/test_ae.c`, no camera, simulated sensor (raw = min(1023, 64 + radiance x E x gain / k),
    K-frame latency): (1) from a dark start and from a bright start, Y within 10% of 0.45 within 60 frames;
    (2) scene 8x brighter: E falls and g returns to 0 within 90 frames (the ratchet test); (3) scene 8x
    darker: E, then g, then F rise in ladder order; (4) backlit scene (2% of pixels 50x brighter): Y >= 0.30;
    (5) after convergence Y changes < 3% frame to frame, and never > 12% on one frame while converging;
    (6) allocation over T' from 1 to 2004 x 15.8 x 2: E x gain x d within 1% of T'; g = 0 whenever
    T' <= 1002; E a multiple of 334 whenever E >= 334 (50 Hz); F = 1116 unless E > 1108; d in [1, 2].
  - Live [OWNER, ~2 minutes]: stream 30 s each in room light, lights off, lights on, backlit. In the log:
    gain index back to 0 within 10 s of lights on; exposure lowered at least once; >= 29 fps in room light;
    no line with d < 1.0. After a few days of normal use, Appendix A shows "gain > 0 while exposure below
    max" under 10% (81% today) and every run with a light change lowered exposure.
  - Flicker [OWNER]: `flat` capture under the room LED light at 450 lines (not a multiple of 10 ms) vs at a
    multiple: row banding drops. If the 450-line capture shows < 0.3% banding, record "lights do not
    flicker; check not informative".

## 7. Phase 4: efficiency and service

**E1 Idle CPU from consumer polling** (review #4).
- Evidence: section 2 (~19 CPU-s per idle 10 minutes). `get_consumer_count()` walks every
  `/proc/<pid>/fd` every 2 s.
- Change: subscribe on the output fd to v4l2loopback's client-usage event; delete inotify and the /proc walk.
  Verified in the installed source (`/usr/src/akmods/v4l2loopback-kmod-0.15.4-1.fc44.src.rpm`,
  `v4l2loopback.c` ~line 818): type `V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1`, payload
  `struct { __u32 count; }`, count 1 while a reader is streaming. It is queued on a reader's STREAMON and
  STREAMOFF, and on close (close calls REQBUFS(0), which calls STREAMOFF), so a crashed reader ends it too.
  The header is not installed: define both locally, citing that source. Subscribe with
  `V4L2_EVENT_SUB_FL_SEND_INITIAL`, wait with `poll(POLLPRI)`, dequeue with `VIDIOC_DQEVENT` and keep
  dequeuing while `ev.pending > 0`. Do not call DQEVENT without POLLPRI: the fd is blocking. Idle: poll with
  the 2 s standby timeout; count 1 starts streaming. While streaming, poll the output fd too; count 0 stops
  after a 3 s grace, cancelled if it returns to 1.
- Validation: idle CPU over 10 minutes <= 0.6 s; [OWNER] `ffmpeg -f v4l2 -i /dev/video50 -t 10 -f null -`
  starts the stream within 1 s and stops it within 5 s of ffmpeg ending; `kill -9` of a streaming ffmpeg
  stops it within 5 s; `systemctl --user restart wireplumber` with no app open starts no stream within 10 s.

**E2 Every service start restarts WirePlumber (brief audio cut)** (review #5; only after E1).
- Evidence: `ExecStartPost=/opt/gc2607/gc2607-restart-wireplumber.sh` runs on every start (44 in 14 days:
  boot and each resume). It restarts the audio session manager after a fixed `sleep 5` and exits 0 silently
  if it cannot find the user. It is needed today because `gc2607-service.sh` unloads and reloads
  v4l2loopback on every start.
- Change: load v4l2loopback once, with its options in `/etc/modprobe.d/` and the module in
  `/etc/modules-load.d/` (written by a new `gc2607-setup-service.sh loopback` sub-command), and keep an
  already-loaded module in `gc2607-service.sh`. Then test without the WirePlumber restart; remove
  `ExecStartPost` only if the test passes. The script logs when it skips or fails.
- Validation: with `ExecStartPost` removed, after each of 3 service restarts and 1 suspend/resume:
  `wpctl status` lists "GC2607 Camera" under video sources, and [OWNER] a browser camera test shows video.
  Any failure: keep the restart and record why.

**S1 Service script discovery** (review #10): find media entities by name with retries instead of the
hard-coded `Intel IPU6 CSI2 0` and fixed sleeps. Model: `gc2607-isp-start.sh` in antonbiluta/gc2607-driver.
Validation: the journal shows the stream starting first time on 3 boots/resumes.

**D2 Driver hygiene** (review #9): request the reset GPIO asserted (`GPIOD_OUT_HIGH`); treat a short I2C
transfer as an error (`ret != 2` on read, `ret != 1` on write, return -EIO); routine probe and stream lines
to `dev_dbg`; set `MODULE_AUTHOR`. Validation as R3.

**C1 Dead weight** (review #11): `hal-config/`, `ipu-bridge-oot/7.0.12/` (superseded by the DKMS
pre-build), the disabled `apply_ltm()`, stale comments ("zero CPU", "centre-weighted"); the three `.bak`
files in /opt/gc2607 are the owner's call. Keep the Python fallback only if it is tested.
Validation: `make isp` and `make modules` build; the service starts.

## 8. Phase 5: colour (later; needs equipment)

- **Q4 Colour matrix**, when the owner has the ColorChecker: capture it (T0.2) in daylight and under the room
  lamp; fit a 3x3 matrix by least squares against the chart's published reference values (cite the source);
  apply it in linear space before the curve; remove the 1.25x chroma stand-in. Validation: mean colour error
  (Delta E 2000) over the 24 patches, before and after.
- **Q8 Lens shading:** from the `flat` frames, if any channel's corner/centre ratio is below 0.8, add a
  per-channel gain grid (for example 16x9) applied before white balance. Validation: ratio >= 0.95 after.
- **Q9 White balance robustness:** limit gains to the range seen in 60 days of use (red 1.53-2.45, blue
  1.49-2.18) plus a margin, and leave near-black samples out. Validation: a scene dominated by one colour
  shows less cast in a grey ROI than the baseline.

## Appendix A: ISP log analyser (`tools/isp_log_stats.py`)

```python
#!/usr/bin/env python3
"""Summarise gc2607_isp status lines. Usage:
journalctl -u gc2607-camera.service --since "-60 days" -o short-unix --no-pager | python3 tools/isp_log_stats.py
"""
import collections, re, statistics as st, sys

PAT = re.compile(r'^(\d+)\.\d+ .*\[(\d+)\]: \[gc2607_isp\] (\d+) frames \| WB: R=([\d.]+) B=([\d.]+) \| '
                 r'bright=([\d.]+) \| exp=(\d+) gain=(\d+) \| means: R=[\d.]+ G=([\d.]+) Gdark=([\d.]+) '
                 r'B=[\d.]+ \| AE: mean=>([\d.]+) cap=>([\d.]+)')
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
pct = lambda cond: f"{100 * sum(1 for r in rows if cond(r)) / n:.0f}%"
print(f"{n} status lines (150 frames each)")
runs = collections.defaultdict(list)
for r in rows:
    runs[r['pid']].append(r['ex'])
print(f"{len(runs)} runs; {sum(any(b < a for a, b in zip(e, e[1:])) for e in runs.values())} ever lowered "
      f"exposure; {sum(2002 in e for e in runs.values())} reached 2002")
print("exposure values:", collections.Counter(r['ex'] for r in rows).most_common(6))
print("gain index histogram:", sorted(collections.Counter(r['ga'] for r in rows).items()))
print("gain > 0 while exposure < 2002:", pct(lambda r: r['ga'] > 0 and r['ex'] < 2002))
print("cap more restrictive than mean:", pct(lambda r: r['ac'] < r['am']))
print("cap at floor (>= 2% clipped):", pct(lambda r: r['ac'] <= 0.88))
print("brightness < 1.0:", pct(lambda r: r['br'] < 1.0), "| < 0.9:", pct(lambda r: r['br'] < 0.9))
pairs = [(a, b) for a, b in zip(rows, rows[1:]) if a['pid'] == b['pid'] and b['fr'] == a['fr'] + 150]
changed = sum((a['ex'], a['ga']) != (b['ex'], b['ga']) for a, b in pairs)
print(f"hardware changed in {100 * changed / max(len(pairs), 1):.0f}% of consecutive intervals")
fps = [150 / (b['t'] - a['t']) for a, b in pairs if b['t'] > a['t']]
print(f"fps median {st.median(fps):.1f}" if fps else "fps: n/a")

def disp(x, curve):  # today's LUT maths (curve=True) vs a plain 2.2 gamma
    x = max(0.0, min(1.0, x))
    if curve:
        x = x * x * (3 - 2 * x)
    return 255 * x ** (1 / 2.2)

for name, key in (("darkest-quarter zones", 'gd'), ("frame mean", 'g')):
    lin = [r[key] * r['br'] / 959 for r in rows]
    print(f"{name} rendered: median {st.median(disp(x, True) for x in lin):.0f}/255 "
          f"(plain gamma {st.median(disp(x, False) for x in lin):.0f})")
```

The fps line uses journal timestamps at 1-second resolution, so read it as approximate.

## Appendix B: per-frame timing harness (`tools/bench_common.h`, `tools/bench_isp.c`)

```c
/* tools/bench_common.h */
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static void fill_bayer(uint16_t *b, int n) { unsigned s = 12345; for (int i = 0; i < n; i++) { s = s * 1103515245u + 12345u; b[i] = 64 + ((s >> 16) % 800); } }
#define ITER 200
```

```c
/* tools/bench_isp.c: build with -O2 -march=native, run under taskset -c 0, 12 and 20 */
#define main isp_main
#include "../gc2607_isp.c"
#undef main
#include "bench_common.h"
static uint16_t bayer[1920 * 1080];
static double median(double *t) { qsort(t, ITER, sizeof(double), cmpd); return t[ITER / 2]; }
int main(void) {
    fill_bayer(bayer, 1920 * 1080);
    float r, g, b; uint32_t hist[HISTOGRAM_BINS]; int ht, sc; double t[ITER], a;
    for (int k = 0; k < 20; k++) process_frame(bayer, 2.0f, 1.6f, 1.3f, &r, &g, &b, hist, &ht, &sc);
    for (int k = 0; k < ITER; k++) { a = now_ms(); process_frame(bayer, 2.0f, 1.6f, 1.3f, &r, &g, &b, hist, &ht, &sc); t[k] = now_ms() - a; }
    printf("process_frame: %.2f ms\n", median(t));
    for (int k = 0; k < ITER; k++) { a = now_ms(); chroma_median_filter(yuyv_buf, OUT_W, OUT_H); t[k] = now_ms() - a; }
    printf("chroma_median_filter: %.2f ms\n", median(t));
    return 0;
}
```

When Q3b changes `process_frame()`, update the harness call to the new signature; keep the chroma line only
while that function exists.

## Appendix C: reference values

- Gain table, index 0..16, real gain = code/64 (AlexDaichendt FINDINGS.md "Gain model"): 64, 76, 93, 111,
  130, 156, 184, 221, 253, 304, 367, 434, 510, 607, 717, 847, 1012. Index 4 = 2.03x, 8 = 3.95x, 16 = 15.81x.
- 30 fps timing: HTS 1959, frame length 1116 lines, measured 29.90 fps, so one line = 29.97 us. Lines per
  flicker period: 334 (50 Hz mains, 10 ms) or 278 (60 Hz, 8.33 ms). 1002 lines = 30 ms; 2004 = 60 ms.
- Frame length for 15 fps: 2232 (VBLANK 1152). Exposure maximum = frame length - 8.
- Today: HTS 2048, VTS 2003, 16.1 fps, exposure max 2002 (~62 ms), ISP start-up 600 lines / gain index 4.
- v4l2loopback 0.15.4 client-usage event: section 7, E1.
- CPU layout: cpus 0-11 performance, 12-19 efficiency, 20-21 low-power (`lscpu -e`).
