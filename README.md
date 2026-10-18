# GC2607 Camera Driver for Linux

A fully functional Linux V4L2 driver for the GalaxyCore GC2607 camera sensor, integrated with Intel IPU6 on x86_64 systems.

## Overview

This driver successfully ports the GC2607 sensor from embedded platforms to mainline Linux, enabling camera functionality on laptops with Intel IPU6 that use this sensor.

**Status:** ✅ **FULLY FUNCTIONAL** - Camera working with OBS Studio and video applications!

### Supported Hardware

- **Sensor:** GalaxyCore GC2607
- **Platform:** Intel IPU6 (tested on Huawei MateBook Pro VGHH-XX)
- **Interface:** MIPI CSI-2 (2 lanes, 672 Mbps/lane)
- **Resolution:** 1920x1080 @ 30fps
- **Format:** 10-bit RAW Bayer (GRBG pattern)
- **ACPI HID:** GCTI2607

## Project Status

- ✅ Phase 1: Skeleton driver with ACPI binding
- ✅ Phase 2: Power management and sensor detection
- ✅ Phase 3: Register initialization (122 registers)
- ✅ Phase 4: V4L2 integration (async subdev, pad ops, controls)
- ✅ Phase 5: IPU6 bridge integration
- ✅ Phase 6: Image capture and streaming **SUCCESS!**
- ✅ Phase 7: Exposure & gain controls **COMPLETE!**

## Features

✅ Full V4L2 subdev integration
✅ Intel IPU6 media controller support
✅ MIPI CSI-2 interface (2 lanes @ 336 MHz)
✅ 1920x1080 @ 30fps capture
✅ 10-bit RAW Bayer output
✅ Power management via INT3472 PMIC
✅ Runtime PM support
✅ Proper reset sequencing
✅ **Exposure control (V4L2_CID_EXPOSURE) - range 4 to frame length - 8 (1108 lines at 30 fps)**
✅ **Analog gain control (V4L2_CID_ANALOGUE_GAIN) - LUT index 0-16**
✅ **Gray world white balance** during Bayer-to-RGB conversion
✅ **OBS Studio integration with virtual RGB camera**
✅ **Google Meet / Chrome / Chromium support (24fps I420)**

## Prerequisites

### Required Packages (Arch Linux)

```bash
# Core driver dependencies
sudo pacman -S base-devel linux-headers v4l-utils media-ctl python-pillow python-numpy feh

# For OBS Studio integration (optional)
sudo pacman -S v4l2loopback-dkms gstreamer gst-plugins-base gst-plugins-good
```

### Modified IPU6 Bridge Module

**Important:** This driver requires a modified `ipu_bridge` kernel module that recognizes the GC2607 sensor.

#### Installation

```bash
# 1. Run the setup script to download kernel source
./setup_ipu_bridge_mod.sh

# 2. Compile the modified bridge module
./compile_ipu_bridge_simple.sh

# The script will automatically:
# - Add GCTI2607 support to ipu-bridge.c
# - Compile against your running kernel
# - Install the modified module
# - Create a backup of the original
```

## Building the Driver

```bash
make
```

## Usage

On this laptop the camera runs as `gc2607-camera.service`. `gc2607-service.sh` loads the modules, finds the
sensor's pipeline by following the media graph (`gc2607-media.sh`) and starts `gc2607_isp`, which reads the raw Bayer
frames, runs exposure, white balance, demosaic and the display curve, and writes 1920x1080 YUYV to `/dev/video50`
("GC2607 Camera", v4l2loopback). Apps open that device directly or through PipeWire; the sensor streams only while
one is reading.

| Task | Command |
|---|---|
| First install | `make isp && sudo ./gc2607-setup-service.sh` |
| Update the ISP | `make isp && sudo ./gc2607-install-isp.sh` (restarts the service, rolls back on failure) |
| Update the service scripts, unit or loopback options | `sudo ./gc2607-setup-service.sh scripts`, `unit` or `loopback` |
| Update the driver | `sudo ./gc2607-driver-install.sh` (DKMS, rebuilt on every kernel update) |
| Check health | `bash gc2607-health.sh`; if the camera is missing, `sudo dmesg \| grep -i gc2607` should show `GC2607 probe successful` |
| Raw frames for ISP work | `sudo ./gc2607-raw-capture.sh SCENE EXP:GAIN[:VBLANK] ...` (camera on; see its header) |

Day-to-day operation, kernel updates and recovery: `docs/operations-runbook.md`. The early manual workflow (capture
scripts, Python RAW viewers, virtual-camera and Chrome scripts, phase test scripts) was removed on 2026-10-18 and is in
git history (`git log --diff-filter=D --stat -- 'view_raw*.py' 'test_*.sh'`).

## Architecture

### Media Pipeline

```
┌─────────────┐      ┌──────────────────┐      ┌─────────────────────┐
│  gc2607     │      │ Intel IPU6 CSI2 0│      │ Intel IPU6 ISYS     │
│  5-0037     │─────▶│  (MIPI Receiver) │─────▶│ Capture 0           │
│ (Sensor)    │      │  /dev/v4l-subdev0│      │ /dev/video0         │
└─────────────┘      └──────────────────┘      └─────────────────────┘
 /dev/v4l-subdev6
   SGRBG10_1X10           SGRBG10_1X10              BA10 (GRBG)
   1920x1080              1920x1080                 1920x1080
```

### Key Components

- **gc2607.c** - Main driver (V4L2 subdev, power management, register initialization)
- **ipu-bridge.c** - Modified to recognize GCTI2607 sensor (built by DKMS, `dkms-setup.sh`)
- **gc2607_isp.c** - Software ISP: exposure control, white balance, demosaic, display curve, YUYV output
- **gc2607-service.sh**, **gc2607-media.sh** - Service start-up and media-graph discovery
- **gc2607-setup-service.sh** - Installs the service, its scripts and the v4l2loopback options

## Technical Details

### Sensor Specifications
- **Resolution:** 1920x1080
- **Frame Rate:** 30 fps
- **Bit Depth:** 10-bit RAW
- **Bayer Pattern:** GRBG (MEDIA_BUS_FMT_SGRBG10_1X10)
- **I2C Address:** 0x37
- **Chip ID:** 0x2607

### MIPI Configuration
- **Lanes:** 2
- **Link Frequency:** 336 MHz
- **Data Rate:** 672 Mbps/lane
- **Pixel Rate:** 134.4 MHz

### Power Management
- **PMIC:** INT3472:01 (intel_skl_int3472_discrete)
- **Clock:** 19.2 MHz from platform
- **Regulators:** avdd (INT3472:01), dovdd (dummy), dvdd (dummy)
- **Reset GPIO:** Provided by INT3472 PMIC
- **Reset Sequence:** HIGH (20ms) → LOW (20ms) → HIGH (10ms)

## Tests and Tools

- `make test` - ISP unit tests (`tests/`: display curve, white balance, output, exposure controller)
- `make bench` - Per-frame ISP timing
- `tools/isp_replay.c`, `tools/isp_metrics.py` - Replay raw captures through the ISP and score the output
- `investigate_ipu_bridge.sh` - Analyze bridge sensor support

## Future Enhancements

The driver is fully functional and ready for production use. Potential improvements include:

**High Priority:**
- Auto-exposure (AE) algorithm
- Auto white balance (AWB)
- Improved demosaicing algorithm

**Medium Priority:**
- Multiple resolution support (720p, 480p, etc.)
- Frame rate control (15fps, 24fps options)
- Test pattern mode for debugging

**Low Priority:**
- Auto-focus support (if VCM present)
- HDR support
- Advanced ISP features

## Documentation

- **[CLAUDE.md](CLAUDE.md)** - Complete development guide and technical details
- **[INT3472_INTEGRATION_ANALYSIS.md](INT3472_INTEGRATION_ANALYSIS.md)** - PMIC integration analysis

## References

- [V4L2 Documentation](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/v4l2.html)
- [Media Controller Documentation](https://www.kernel.org/doc/html/latest/userspace-api/media/mediactl/media-controller.html)
- [Intel IPU6 Driver](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/media/pci/intel)

## License

This driver is released under the GPL-2.0 license, consistent with the Linux kernel.

## Contributing

Contributions welcome! Areas of interest:
- Auto-exposure/auto-gain algorithms
- Multi-resolution support
- Other GalaxyCore sensors (GC1029, etc.)
- Testing on different hardware platforms
- OBS Studio plugin for native Bayer support
- Special thanks to [yegor-alexeyev](https://github.com/yegor-alexeyev) for suggesting that the Matebook Pro 2024 VGHH-XX has the GC2607 sensor in [this post](https://github.com/intel/ipu6-drivers/issues/399#issuecomment-3707318638)

## Acknowledgments

- Reference driver from Ingenic T41 platform
- Linux kernel V4L2 subsystem documentation
- Intel IPU6 driver developers

---

**Status:** ✅ Production ready - Full exposure/gain control, OBS Studio & Google Meet compatible
**Tested on:** Huawei MateBook Pro VGHH-XX
**Kernel:** 6.17.9-arch1-1
**Last Updated:** January 7, 2026
**Achievement:** Successfully ported proprietary embedded camera driver to mainline Linux V4L2 with IPU6 integration, full manual controls, real-time video streaming, and WebRTC compatibility
