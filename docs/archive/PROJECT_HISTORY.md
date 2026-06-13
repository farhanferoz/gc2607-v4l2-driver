# Project History & Current State

This document serves as the chronological save-state for the GC2607 camera driver project. Agents should read this to understand *how* the system evolved, what was tried, and exactly what the current state is.

## 1. Current State (As of May 2026)

**STATUS: FULLY FUNCTIONAL AND EFFICIENT**

The project has transitioned from a proof-of-concept Python pipeline to a high-performance, system-integrated C pipeline. 
*   The camera can be used natively in OBS Studio, Google Meet, Chrome, and GNOME Camera.
*   **Idle Power:** The camera driver successfully enters `s2idle` system sleep dynamically. The userspace ISP daemon consumes ~0.7% CPU when no apps are using the camera.
*   **Active Power:** The C ISP consumes ~4-5% CPU when streaming 1080p@30fps.

## 2. Chronological Development Journey

### Phase 1 & 2: Kernel Driver Skeleton and PMIC Integration
We ported the original Ingenic T41 driver to mainline Linux. The primary hurdle was the `INT3472:01` discrete PMIC. Initially, the driver expected explicit devicetree resources (regulators, clocks, reset GPIO). Because x86_64 laptops often manage this internally or hide it behind ACPI, we had to refactor the driver to make all these power resources *optional* with graceful fallbacks to prevent `-121 EREMOTEIO` probe failures.

### Phase 3 & 4: Register Initialization and V4L2
We successfully mapped the 122-register init sequence for 1080p30. We integrated standard V4L2 pad operations and async subdev components. We added V4L2 controls for Exposure (4-2002) and Analogue Gain (implemented as a 17-entry LUT, writing to 4 registers simultaneously).

### Phase 5 & 6: IPU6 Bridge and Python Virtual Cam
To expose the raw GRBG stream to userspace, we patched the Intel `ipu-bridge.ko` to recognize the `GCTI2607` HID. We initially wrote `gc2607_virtualcam.py` using NumPy to demosaic the Bayer data. This worked but consumed ~43% CPU continuously. We encountered severe "color tinge" issues because the manual static RGB offsets applied over the raw stream were flawed.

### Phase 7: The C Userspace ISP (`gc2607_isp.c`)
To resolve the CPU overhead and color problems, we entirely replaced the Python script with a pure C ISP application.
*   **Performance:** We collapsed all per-pixel mathematics (demosaic, black level, S-curve contrast, gamma) into a 1-D, 1024-entry lookup table (LUT) computed once per frame. This dropped CPU usage to 4%.
*   **Color Correction:** We removed all static offsets and implemented a pure "Gray-World" Auto White Balance (AWB) algorithm.
*   **Auto Exposure:** We implemented a two-stage AE approach: a software multiplier for immediate frame-to-frame responsiveness, integrated with dynamic hardware register manipulation (exposure/gain limits) for large lighting changes.

### Phase 8: Suspend Interoperability & Lazy Activation
The continuous stream loop prevented the IPU6 ISYS from sleeping, causing `-EBUSY` when attempting to close the laptop lid.
*   **Kernel Fix:** We added `SET_SYSTEM_SLEEP_PM_OPS` to `gc2607.c` so the kernel could forcibly power down the sensor via the existing runtime PM hooks upon a sleep signal.
*   **Service Fix:** Added `Conflicts=sleep.target` to the systemd service to tear down gracefully before sleep.
*   **Lazy Activation:** We refactored `gc2607_isp.c` to use inotify on `/dev/video50`. It now sits at ~0.7% CPU, writing a black standby frame to keep PipeWire/WirePlumber happy, and only powers up the sensor hardware when a consumer app attempts to read from `/dev/video50`. AE/AWB states were made `static` so they persist across these activation boundaries without overexposing on startup.

### Phase 9: Consumer Detection Reliability Fix
inotify `IN_OPEN`/`IN_CLOSE` events on V4L2 character devices are unreliable at the kernel level — missed events caused `consumer_count` to drop to zero mid-stream, making the ISP incorrectly stop streaming after ~10s.
*   **Fix:** Added a `/proc/<PID>/fd` scan as ground-truth fallback in `get_consumer_count()`. Every 2s (the existing poll interval), both inotify and `/proc` are checked. If `/proc` says consumers exist, streaming continues; if `/proc` says zero, it is always believed over inotify. The ISP's own PID is excluded to avoid counting its permanently-open `out_fd`.
*   **Result:** Stream now holds for the full consumer session. Verified live: 150+ frames with no drop where it previously always failed.

### Phase 10: Hardware ISP Investigation (April 2026)
We investigated whether Intel's IPU6 hardware ISP (PSYS) could replace the software ISP for better image quality and lower CPU usage.
*   **Tuning files extracted:** Mounted the Windows partition and found the proprietary `.aiqb` tuning file, graph settings XML, and `.cpf` calibration data at `C:\Windows\System32\DriverStore\FileRepository\gc2607.inf_amd64_5924907c31b80ed6\`. These are stored in `hal-config/tuning/`.
*   **PSYS module works:** The `intel_ipu6_psys` kernel module built and loaded successfully on kernel 6.19 via RPM Fusion `akmod-intel-ipu6`.
*   **HAL recognizes GC2607:** We created a sensor config XML (`hal-config/gc2607-uf.xml`), registered it in `libcamhal_profile.xml`, and the HAL enumerated the sensor as `device-name=gc2607-uf` and loaded the `.aiqb`.
*   **Blocker: Zero frames produced.** The mainline ISYS (in kernel since 6.10) lacks "BE SOC" bridge entities needed to route raw frames into PSYS. These exist only in Intel's out-of-tree `ipu6-drivers` which stopped at kernel 6.17. The out-of-tree IPU core is incompatible with the in-tree version — they cannot be mixed. We also tried forcing the ISYS-only media path (removing BE SOC config), but PSYS still produced no output.
*   **Conclusion:** Hardware ISP is blocked by a kernel-level gap that only Intel can fix. All config/tuning files are preserved for future use. Full details in `docs/hardware_isp_investigation.md`.

### Phase 11: Fedora 44 Upgrade — Regressions and HAL Re-investigation (May 2026)
After upgrading Fedora 43 → 44 (kernel 6.19.14-300.fc44, GNOME 48), four user-visible regressions appeared:
*   **Camera service failed at boot** because F44's `v4l2loopback` and `v4l2-relayd` packages auto-load `v4l2loopback` early with default parameters. Our service's `modprobe -r` then `modprobe video_nr=50` is a silent no-op once the module is held open. Combined with `Restart=on-abnormal` (which doesn't cover non-zero exits), the service stayed dead. **Fix:** mask the four autoload files via `/etc/{modules,modprobe}.d/*.conf → /dev/null`, change `Restart=on-failure`.
*   **Suspend hung** after one attempt used `deep` instead of `s2idle`. Meteor Lake firmware doesn't support S3 at all; the system tried, failed, never woke. **Fix:** `grubby --update-kernel=ALL --args="mem_sleep_default=s2idle"`.
*   **Brightness flickered** because GNOME 48's adaptive brightness is on by default and the kernel now exposes ALS readings continuously. **Fix:** `gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled false`.
*   Full details: `docs/incidents/2026-05-fedora-44-regressions.md`. All four fixes verified against authoritative documentation before applying.

The April hardware-ISP investigation was reopened on F44 with initial optimism — `intel_ipu6_psys` is loaded at boot, HAL packages ship Meteor Lake config files for GC2607 (`/usr/share/defaults/etc/camera/ipu6epmtl/`), and `gstreamer1-plugins-icamerasrc` is available. Phase 1 diagnostic (LD_DEBUG plugin trace, MediaCtl pipeline diff, `availableSensors` audit) plus targeted upstream research closed the question:

*   **Closed: HW ISP path is infeasible** on this hardware/sensor as of May 2026. Three independent blockers, each fatal:
    1.  Mainline kernel has no PSYS module (the HW ISP doing Bayer→NV12). Intel keeps PSYS firmware/algorithms proprietary and **will not upstream it**. Mainline 6.10+ has only ISYS (raw CSI receiver). Architectural, not a missing patch.
    2.  Out-of-tree proprietary stack is unmaintained — `intel/ipu6-drivers` and RPMFusion's `akmod-intel-ipu6` stopped tracking kernel API changes ~Dec 2024 / Jan 2025; F44 ships kernel ≥6.17.
    3.  GC2607 was never accepted into Intel's IPU6 driver tree — `intel/ipu6-drivers` Issue #272 (Oct 2024) is still open. F44's shipped `gc2607-uf.xml` had its BE SOC pipeline stripped (because the kernel side doesn't exist), and `gc2607-uf` is absent from `availableSensors` in `libcamhal_profile.xml`.
*   The April framing ("blocked by missing BE SOC bridge") was incomplete — it implied a missing puzzle piece, when the real story is upstream policy. Even with kernel updates, HW ISP would still need (a) GC2607 patches landed in Intel's tree, (b) the proprietary stack actively maintained against the current kernel, and (c) Intel reversing the PSYS-is-proprietary policy.
*   **Conclusion:** `gc2607_isp.c` software ISP (~4% CPU) is **the only viable path** for this sensor on this laptop — not a workaround, the answer. Full analysis with sources in `docs/native_hal_investigation.md`. Quarterly-check criteria documented there; tracked in `RESUME.md`.

### Phase 12: ISP Image-Quality Work (May 2026)

Iterated on the hand-rolled software ISP to address three real-world problems: white-wall blowout on bright scenes, chroma moiré on textured fabric (corduroy), and dim backlit faces.

Shipped:
*   **Multi-zone shadow-priority AE** (commit `0a6bdeb`) — 16×16 zone grid metered on the mean of the darkest 25% of zones. Replaces the centre-weighted target that failed when the subject wasn't centred or when the centre contained the bright background. Pattern matches libcamera `AgcMeanLuminance` / RPi IPA. Paired with the pre-existing percentile highlight cap as a dual-constraint AGC.
*   **Chroma denoise via 3×3 median** on U/V (pre-session, kept). Fixes false colour on flat surfaces.

Abandoned after testing:
*   **Global tone curves** — ACES Narkowicz, asymmetric hyperbolic knee, half-strength smoothstep. All failed for the same reason: no global luma threshold separates skin highlights from wall highlights at the same Y. Tone mapping for backlit scenes is inherently spatial, not global.
*   **Local tone mapping (LTM)** — implemented twice. Box-blurred grid produced halos at the silhouette boundary; bilateral-filtered grid fixed the halo but exposed a new artefact (face-internal "patch" on the well-lit forehead where the cell-grid factor jump becomes visible inside skin). Code is preserved in `gc2607_isp.c` but gated off at the call site. Re-enabling with `LTM_KNEE=200` or a highlight-only threshold is one of the future options.

Deferred:
*   **Malvar-He-Cutler demosaic** (vs current 2×2 binning) — the root cause of corduroy chroma moiré is binning-stage aliasing; chroma median can't unscramble pre-aliased UV. ~150-200 LoC, +2-3% CPU. Open the day someone needs clean fine-pinstripe / sharp screens.

Full session-by-session breakdown of attempts, mechanisms, and pickup options in `docs/research/ISP_IMAGE_QUALITY.md`.

### Phase 13: libcamera Software ISP Path Opened (May 2026)

Investigated whether libcamera's Software ISP (the `simple` pipeline + `soft IPA` added in libcamera 0.3, merged Apr 2024 for IPU6) could replace the hand-rolled daemon. F44 ships libcamera 0.7.1 with the soft IPA module installed (`/usr/lib64/libcamera/ipa/ipa_soft_simple.so`).

Initial probe via `cam --list`: libcamera **did** enumerate the sensor, then refused to instantiate it with `Failed to create sensor: -22 / The sensor kernel driver needs to be fixed`. The driver was missing standard V4L2 sensor controls.

**Phase 1 — V4L2 driver conformance** (commit `aeb1305`). Added to `gc2607.c`:
*   `V4L2_CID_HBLANK` (read-only) = HTS - WIDTH = 128
*   `V4L2_CID_VBLANK` (read-only) = VTS - HEIGHT = 923
*   `get_selection` pad op covering CROP / CROP_DEFAULT / CROP_BOUNDS, returning the full 1920×1080 pixel array (this sensor doesn't crop)
*   `v4l2_fwnode_device_parse` + `v4l2_ctrl_new_fwnode_properties` populating CAMERA_ORIENTATION and CAMERA_SENSOR_ROTATION when fwnode provides them

Pattern templated from `drivers/media/i2c/gc05a2.c` (same SGRBG10 Bayer order, single source pad, fixed-mode sensor). Confirmed no upstream gc2607 driver exists — neither in mainline kernel, lore patches, Intel ipu6-drivers, nor any OEM tree (`intel/ipu6-drivers` Issue #272 is still open with no PR).

After Phase 1: `cam --list` enumerates the sensor (`Adding camera '\_SB_.PC00.LNK0' for pipeline handler simple`). v4l2-ctl --list-ctrls on the subdev shows all the new controls live.

**Phase 2 — end-to-end streaming verified** (commit `042911a`). `cam -c 1 -C60 -F frame-#.ppm` streams 60 frames at 1920×1080 / 16 fps. Soft IPA's grey-world AWB has converged by ~frame 30. Image quality at frame 60 is roughly comparable to `gc2607_isp.c` — slightly weaker WB, similar exposure in backlit scenes, much better resolution. Reproducible via `sudo gc2607-libcamera-snap.sh`.

**Phase 3 — quality parity (in progress, mostly open):**
*   **Open: rotation.** Sensor mounted upside-down on this MateBook; ACPI _DSD doesn't carry rotation. Driver-side override attempts (`v4l2_ctrl_new_std(CAMERA_SENSOR_ROTATION, 180, ...)`; modifying `props.rotation` before `v4l2_ctrl_new_fwnode_properties`) both failed — control stayed at min=max=0, debug `dev_warn` calls inside the override block didn't appear in dmesg despite being present in the .ko string table. Mechanism not understood. Workaround: ffmpeg post-rotate after capture. Real fix is likely libcamera-side (an entry in `CameraSensorProperties` database) which requires rebuilding libcamera.
*   **Open: `CameraSensorHelperGc2607`.** Soft IPA logs "Failed to create camera sensor helper for gc2607" → AGC operates with reduced/wrong gain range. Fix: ~30-LoC C++ class in `src/ipa/libipa/camera_sensor_helper.cpp` mapping our 17-entry analogue-gain LUT to actual gain values. Requires rebuilding libcamera.
*   **Open: tuned `gc2607.yaml`.** Currently falls back to `uncalibrated.yaml`. A tuned config with CCM + gamma + black-level values would close the colour-accuracy gap.
*   **Open: lazy activation / suspend interop on the libcamera path.** Our daemon's strengths; PipeWire has a different model.

**Status at session end:** Software ISP via libcamera is a *reachable* path, not yet a *better* one. The hand-rolled `gc2607_isp.c` daemon remains the shipped pipeline. Phase 3 is upstream-style C++ work in libcamera that would close the gap. Quarterly check criteria for revisiting: a `gc2607.yaml` ships upstream, or someone writes `CameraSensorHelperGc2607` and lands it in libcamera. See `docs/research/ISP_IMAGE_QUALITY.md` for the full algorithmic context informing this decision.

### Phase 14: libcamera Path A/B Tested in Real Consumer — Confirmed Unshippable (May 2026)

Short session: switched the live pipeline from daemon to libcamera bridge, opened the GNOME camera app, observed output, switched back.

*   **Empirical result:** the libcamera path is visibly broken in a consumer app — image upside-down **and** badly overexposed (washed-out white). Both failure modes match the open items flagged at the end of Phase 13: rotation is not actually being corrected end-to-end, and the soft IPA's AGC operates with the wrong gain range because `CameraSensorHelperGc2607` does not exist. The gstreamer `videoflip method=rotate-180` in the bridge is not closing the rotation gap, and no amount of bridge-side tuning fixes the AGC.
*   **Conclusion:** the libcamera path stays parked exactly where Phase 13 left it. The two open items (`CameraSensorHelperGc2607` + tuned `gc2607.yaml` + libcamera-side rotation entry in `CameraSensorProperties`) are not optional polish — they are the gate. The hand-rolled `gc2607_isp.c` daemon remains the only shippable pipeline on this hardware as of May 2026.
*   **Bug found in `gc2607-libcamera-bridge.sh`:** stopping the bridge does **not** clean up the libcamera `soft_ipa_proxy` child it spawned via PipeWire/wireplumber. The orphaned proxy keeps `/dev/video0` busy via the kernel V4L2 subdev, so a subsequent `gc2607-camera.service` restart fails its first `VIDIOC_REQBUFS` and loops. Symptom: "camera stops working" after a bridge stop. Workaround used this session: `sudo pkill -f 'soft_ipa_proxy|libcamera_ipa' && systemctl --user restart wireplumber` before restarting the daemon. Permanent fix is to teach the bridge's `stop` action to do that cleanup itself.

#### Pickup notes (for a future libcamera revival)

Concrete entry points for whoever picks this up:

*   **Try it again first** — switch live: `/tmp/gc2607-switch-to-libcamera.sh` (one-shot generated this session; reproduce with: stop+disable `gc2607-camera.service`, `sudo pkill -f 'soft_ipa_proxy|libcamera_ipa'`, restart user wireplumber, then `sudo gc2607-libcamera-bridge.sh start`). Revert with `/tmp/gc2607-switch-back-to-daemon.sh`.
*   **Headless A/B without a camera app** — `sudo gc2607-libcamera-snap.sh` captures N PPM frames straight from `cam` (bypasses the gstreamer bridge entirely; tests raw libcamera output). Useful when separating "libcamera bug" from "bridge bug".
*   **Bridge pipeline** — `gc2607-libcamera-bridge.sh:~110` is the full gst-launch line: `pipewiresrc target-object=$node ! videoconvert ! videoflip method=rotate-180 ! capsfilter caps=video/x-raw,format=YUY2 ! v4l2sink device=/dev/video51`. Resolution is 640×480 because that's what PipeWire's libcamera node currently exposes; raising it is upstream libcamera config work, not in this script.
*   **Driver conformance** (already shipped, do not redo) — `gc2607.c`: `gc2607_get_selection()` at line 571, HBLANK/VBLANK ctrls at lines 920–948, fwnode prop parsing at lines 949–963. Templated from `drivers/media/i2c/gc05a2.c`. Commit `aeb1305`.
*   **Gain LUT for the helper class** — `gc2607.c:78–97`, `gc2607_gain_table[]`, 17 entries, each `{reg2b3, reg2b4, reg2b8, reg2b9}` plus implicit gain multiplier per row. A `CameraSensorHelperGc2607` in libcamera's `src/ipa/libipa/camera_sensor_helper.cpp` needs to expose this table as analogue-gain values so the soft IPA's AGC has the right gain range. ~30 LoC; follow the pattern of the existing `CameraSensorHelperImx*` / `CameraSensorHelperOv*` classes in the same file. Build with `meson compile -C build`, install to `/usr/lib64/libcamera/`.
*   **Tuning YAML** — drop a `gc2607.yaml` at `/usr/share/libcamera/ipa/simple/` (currently only `uncalibrated.yaml` is installed there). Use one of the other simple-IPA YAMLs in the libcamera source tree as a template; fill in CCM, gamma curve, and black-level. The values we already use in `gc2607_isp.c` are a starting point.
*   **Rotation** — driver-side override of `V4L2_CID_CAMERA_SENSOR_ROTATION=180` did not stick (mechanism unknown; debug `dev_warn` calls in the override block did not appear in dmesg despite being in the `.ko` string table). The realistic fix is a `CameraSensorProperties` entry for gc2607 in libcamera, which then requires a libcamera rebuild. Until then, the bridge has `videoflip method=rotate-180` and that still didn't produce a right-side-up image in the GNOME camera app — diagnosis pending.
*   **Verify it's actually instantiating** — `cam --list` must show `Adding camera '\_SB_.PC00.LNK0' for pipeline handler simple`. If it falls back to `Failed to create sensor: -22`, the driver conformance regressed. If it succeeds but the soft IPA logs `Failed to create camera sensor helper for gc2607`, the helper class is the missing piece.
