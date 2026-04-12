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

## Hardware ISP Status (BLOCKED — April 2026)

The IPU6 PSYS hardware ISP could replace the software ISP but is blocked by a missing
kernel bridge (BE SOC) in the mainline ISYS driver. All calibration files from Windows
are extracted and ready in `hal-config/tuning/`. The HAL recognizes the sensor but
produces zero frames. See `docs/hardware_isp_investigation.md` for full details and
what to search for to check if this is unblocked.

## Common Pitfalls

- **Module xz compression**: Fedora's kernel module loader expects `xz --check=crc32`. Default xz uses CRC64 which causes `decompression failed with status 6`.
- **Format mismatch**: Video device must use `pixelformat=BA10` (not `GB10`) to match sensor's GRBG Bayer pattern.
- **Reset sequence**: Reset GPIO must end de-asserted (HIGH) or sensor won't respond to I2C.
- **PipeWire / Wireplumber**: A specific wireplumber rule hides raw IPU6 nodes (`~/.config/wireplumber/wireplumber.conf.d/50-hide-ipu6-raw.conf`). Without this, apps try to use raw IPU6 streams instead of the virtual camera. Must restart wireplumber after v4l2loopback loads.
