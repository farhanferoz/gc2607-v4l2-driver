# AI Agent Rules & Project Context

This is the central source of truth for all AI agents contributing to the GC2607 camera driver project.
**Agents must read this file before attempting any modifications to the codebase.**

## Project Overview

V4L2 Linux kernel driver for the GalaxyCore GC2607 camera sensor, ported from the Ingenic T41 platform (MIPS) to Intel IPU6 on x86_64. The camera starts automatically at boot via a systemd service using a C-based ISP daemon.

**Target hardware:** Huawei MateBook Pro VGHH-XX with GC2607 sensor on I2C bus 5 at address 0x37.

## Architecture

### Full Pipeline
```
gc2607 sensor (SGRBG10 raw 10-bit Bayer)
  → Intel IPU6 CSI2 0
  → Intel IPU6 ISYS Capture 0 (/dev/videoN)
  → gc2607_isp (C: demosaic + lazy activation + auto-WB + auto-exposure + gamma via LUT)
  → v4l2loopback /dev/video50 ("GC2607 Camera", YUYV 960x540)
  → PipeWire → camera apps (GNOME Camera, Chrome, OBS, etc.)
```

### Userspace ISP (`gc2607_isp.c`)
- **Language**: Pure C. Uses ~1% CPU when idle, ~4-5% when streaming.
- **Lazy Activation**: Uses a hybrid `inotify` + `/proc/<PID>/fd` consumer detection on `/dev/video50`. inotify provides instant wake-on-open; a `/proc` scan runs every 2s as ground-truth fallback because inotify `IN_OPEN`/`IN_CLOSE` events are unreliable on V4L2 character devices. When idle, the ISP writes a black frame to keep the loopback device alive for PipeWire, but frees the sensor hardware.
- **Key design (per-channel LUT)**: All per-pixel operations (black level subtract → WB gain → brightness → S-curve contrast → sRGB gamma) are composed into three 1024-entry LUTs (one per R/G/B channel), recomputed once per frame to maintain high performance.
- **Auto White Balance (AWB)**: Gray-world implementation. No manual offsets (`G_OFFSET`, `R_OFFSET`, etc MUST NOT be added).
- **Auto Exposure (AE)**: Software brightness multiplier for fast response, driving hardware exposure/gain adjustment for range.

### Kernel Driver (`gc2607.c`)
- **ACPI matching**: Uses HID "GCTI2607" targeting x86_64 laptops.
- **INT3472 PMIC**: Power/reset/clock managed through Intel's discrete PMIC driver, not direct GPIO.
- **Gain via LUT**: Analogue gain uses a 17-entry lookup table (index 0-16) that writes to 4 registers simultaneously.
- **Power Management**: Requires `SET_SYSTEM_SLEEP_PM_OPS` alongside `SET_RUNTIME_PM_OPS` to properly release the hardware during system suspend so that it doesn't cause `-EBUSY` kernel panics.

### Service Lifecycle (Suspend/Resume)

The `gc2607-camera.service` lifecycle is controlled by **two** coordinated pieces. Both must be preserved:

1. `Conflicts=sleep.target` in the service file — stops the service cleanly on suspend to prevent `-EBUSY` kernel panics.
2. `/usr/lib/systemd/system-sleep/gc2607-resume` sleep hook — restarts the service on the `post` event after resume. Source tracked in repo as `gc2607-resume`.

`Restart=on-abnormal` does NOT cover clean stops, so without the hook the service stays dead after the first suspend. See `docs/incidents/2026-04-suspend-resume-failure.md`.

## Hardware Details

| Parameter | Value |
|-----------|-------|
| Sensor | GC2607 (chip ID 0x2607) |
| I2C | Bus 5, address 0x37 |
| MIPI CSI-2 | 2 lanes, 672 Mbps/lane (link_freq=336 MHz) |
| Format | SGRBG10 (10-bit Bayer GRBG, pixelformat=BA10) |
| ACPI | GCTI2607:00 at \_SB_.PC00.LNK0 |

## Development Conventions & Constraints

- **Main Driver**: All sensor-specific kernel logic belongs in `gc2607.c`.
- **C/ISP Logic**: The ISP (`gc2607_isp.c`) must remain highly optimized. Do not add heavy processing loops inside the per-pixel iteration.
- **Format limits**: The kernel uses Linux standard coding style for C.
- **Dependencies**: The ISP must remain pure executable C requiring no external interpretation (Do not use Python/NumPy for camera streaming due to excessive overhead).

## Hardware ISP / Native HAL Stack Status (CLOSED — INFEASIBLE — re-checked 2026-06-19)

The IPU6 hardware ISP path is still **dead-end for this sensor**, but the *reason* has
narrowed since the original May-2026 assessment. Two of the three original blockers have
softened; one decisive blocker remains (verified on-device 2026-06-19).

1. ~~Mainline kernel has no PSYS module~~ **PSYS is actually PRESENT on this machine.**
   Mainline still ships only ISYS, but we run RPMFusion's out-of-tree `akmod-intel-ipu6`,
   which *includes* the PSYS driver (the HW ISP doing Bayer→NV12). Verified: `kmod-intel-ipu6-7.0.12-201`
   built for the running kernel and `intel_ipu6_psys` is loaded (`lsmod`). So "mainline has
   no PSYS" is true for *mainline* but is **not** why the HW ISP is unavailable here.
2. ~~Out-of-tree stack is unmaintained~~ **Maintained again.** `intel/ipu6-drivers` now
   carries kernel-7.0 patches (June 2026) and the RPMFusion akmod builds + loads on F44's
   kernel 7.0.12 (package source is pinned to a 2025-09-09 snapshot, but it builds). The
   "stopped tracking kernel API at v6.16" claim is outdated.
3. **DECISIVE BLOCKER — GC2607 has zero HAL/libcamera support and no proprietary tuning.**
   [Issue #272](https://github.com/intel/ipu6-drivers/issues/272) (Oct 2024) is still open,
   no maintainer action since Jan 2026. In the installed `ipu6-camera-hal`: gc2607 is absent
   from every `availableSensors` list (ipu6 / ipu6ep / **ipu6epmtl** = the Meteor Lake
   profile); **no `gc2607*.xml` sensor config ships at all** (not even a stripped one); and
   **no `gc2607*.aiqb` tuning binary exists** (shipped tunings are hm11b1/ov01a1s/ar0234/
   imx390/…). The IPU6 HW ISP cannot process gc2607 frames without that per-sensor `.aiqb`
   AIQ tuning, which only Intel produces and has never released for gc2607. libcamera has no
   gc2607 `CameraSensorHelper` either.

**Conclusion (unchanged):** The custom `gc2607_isp.c` software ISP (~4% CPU) remains **the
only viable path**. Even with PSYS loaded, the missing gc2607 `.aiqb` tuning + HAL/libcamera
entry is fatal. The realistic future path is upstream — add a gc2607 `CameraSensorHelper` to
libcamera and ride its maturing software ISP (same *category* as the current solution), NOT
the IPU6 hardware ISP. See `docs/native_hal_investigation.md` for full analysis and
quarterly-check criteria for reopening if upstream policy changes.

## Fedora 44 Setup Notes (post-upgrade)

After Fedora 43 → 44, four regressions were identified and fixed (see
`docs/incidents/2026-05-fedora-44-regressions.md`):
1. F44's `v4l2loopback` and `v4l2-relayd` packages auto-load v4l2loopback at boot, which
   conflicts with our service. We mask their autoload via `/etc/{modules,modprobe}.d/*.conf
   → /dev/null` symlinks. **Do not unmask these** unless decommissioning the custom service.
2. The service's `Restart=on-abnormal` was changed to `on-failure` so non-zero exits trigger
   retry (per `systemd.service(5)`).
3. `mem_sleep_default=s2idle` is pinned on the kernel cmdline (Meteor Lake firmware doesn't
   support deep S3).
4. GNOME adaptive brightness is disabled (`org.gnome.settings-daemon.plugins.power
   ambient-enabled=false`).

## Common Pitfalls

- **Module xz compression**: Fedora's kernel module loader expects `xz --check=crc32`. Default xz uses CRC64 which causes `decompression failed with status 6`.
- **Format mismatch**: Video device must use `pixelformat=BA10` (not `GB10`) to match sensor's GRBG Bayer pattern.
- **Reset sequence**: Reset GPIO must end de-asserted (HIGH) or sensor won't respond to I2C.
- **PipeWire / Wireplumber**: Two wireplumber drop-ins must be in place:
  - `~/.config/wireplumber/wireplumber.conf.d/50-hide-ipu6-raw.conf` — hides raw IPU6 nodes. Without this, apps try to use raw IPU6 streams instead of the virtual camera.
  - `~/.config/wireplumber/wireplumber.conf.d/51-disable-libcamera-gc2607.conf` — disables WP's libcamera monitor component entirely. Required because libcamera autodiscovers the gc2607 subdev via its "simple" pipeline handler but has **no `CameraSensorHelper` for `gc2607` in its sensor DB** — the soft IPA fails on close and crashes the kernel in `subdev_close+0x2a` (oops observed 2026-05-14). Until a `CameraSensorHelperGc2607` lands upstream (see `docs/archive/PROJECT_HISTORY.md` Phase 13–14), this component must stay disabled. The per-device `monitor.libcamera.rules` approach did not fire in WP 0.5.14 — component-disable is what's deployed.
  - Restart wireplumber after `v4l2loopback` loads.
