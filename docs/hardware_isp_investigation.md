# Hardware ISP Investigation (April 2026)

## Summary

We attempted to use Intel's IPU6 hardware ISP (PSYS) instead of our software ISP
(`gc2607_isp`). We extracted calibration files from the Windows partition and got
the HAL to recognize the GC2607 sensor, but frames do not flow due to a kernel-level
gap. The software ISP remains the working solution.

## What We Have (Ready to Use)

All Intel proprietary calibration files were extracted from Windows and are stored
in `hal-config/tuning/`:

| File | Purpose |
|------|---------|
| `gc2607_gc2607_MTL.aiqb` (298K) | 3A tuning: AWB, AE, gamma curves calibrated for GC2607 |
| `graph_settings_gc2607_gc2607_MTL.xml` (194K) | PSYS firmware pipeline graph definition |
| `gc2607_gc2607_MTL.cpf` (120B) | Additional calibration profile |

Sensor config for the HAL is in `hal-config/gc2607-uf.xml`.
Install script: `hal-config/install.sh`.

**Windows source path:** `C:\Windows\System32\DriverStore\FileRepository\gc2607.inf_amd64_5924907c31b80ed6\`

## What Works

- `intel_ipu6_psys` kernel module builds and loads on kernel 6.19 via RPM Fusion
  `akmod-intel-ipu6` package
- `ipu6-camera-hal` loads the `.aiqb` and enumerates GC2607 as `device-name=gc2607-uf`
- GStreamer pipeline `icamerasrc device-name=gc2607-uf` starts without errors
- All RPM Fusion packages install cleanly:
  `akmod-intel-ipu6`, `ipu6-camera-bins`, `ipu6-camera-hal`, `gstreamer1-plugins-icamerasrc`

## What Fails — The Blocker

**Zero frames are produced.** The pipeline starts but no pixel data flows.

### Root Cause: Missing BE SOC in Mainline ISYS

The IPU6 has two subsystems:
- **ISYS** (Input System): CSI-2 receiver, captures raw Bayer → RAM. In mainline since kernel 6.10.
- **PSYS** (Processing System): Hardware ISP (demosaic, AWB, AE, noise reduction). Never upstreamed.

The camera HAL needs a **BE SOC** (Back End System-on-Chip) bridge entity to route
raw frames from ISYS into PSYS. This bridge exists ONLY in Intel's out-of-tree
`ipu6-drivers` ISYS module (`ipu-isys-csi2-be-soc.c`). The mainline ISYS does not
have it and Intel has shown no intention of adding it.

### Why We Can't Build Out-of-Tree ISYS

| Attempt | Result |
|---------|--------|
| RPM Fusion `akmod-intel-ipu6` | Only builds PSYS + sensor drivers. Deliberately skips ISYS for kernels ≥6.10 because ISYS is in-tree. |
| Force-build from `intel/ipu6-drivers` | Fails. The out-of-tree IPU core is a completely different codebase from the in-tree one (different headers, structs, APIs). They cannot be mixed. |
| Build standalone BE SOC module | Not feasible. BE SOC is deeply integrated into the out-of-tree ISYS internals. |
| Remove BE SOC mediaCfg, use ISYS-only path | HAL starts but still produces zero frames. PSYS firmware graph assumes BE SOC topology. |
| `intel/ipu6-drivers` patches | Only go up to kernel 6.17. No 6.18/6.19 support. |

## How to Check if This is Fixed in Future

An agent checking this should search for ANY of the following — any one would unblock
the hardware ISP:

### Search 1: Out-of-tree drivers catch up to current kernel
```
Check: https://github.com/intel/ipu6-drivers/tree/master/patch/
Look for: a v6.19 or v6.20+ patch directory
If found: the full out-of-tree stack (ISYS with BE SOC) can be built
```

### Search 2: BE SOC lands in mainline kernel
```
Search kernel git log or LKML for:
  - "ipu-isys-csi2-be-soc"
  - "IPU6 BE SOC"
  - "ipu6 psys" in drivers/media/pci/intel/ipu6/
If found: mainline ISYS now has the bridge, HAL should work directly
```

### Search 3: Camera HAL updated to work without BE SOC
```
Check: https://github.com/intel/ipu6-camera-hal
Search issues/commits for: "mainline", "in-tree ISYS", "without BE SOC", "kernel 6.10+"
If found: HAL can route frames through ISYS-only capture path to PSYS
```

### Search 4: libcamera gains PSYS support
```
Check: https://git.libcamera.org/libcamera/libcamera.git
Search for: "psys", "ipu6 hardware ISP", "IPU6 PSYS pipeline"
If found: libcamera can drive the hardware ISP without the proprietary HAL
```

### Search 5: RPM Fusion akmod builds full ISYS
```
Check: dnf info akmod-intel-ipu6
If the package version is newer than 0.0-24.20250909git4bb5b4d and the changelog
mentions ISYS or BE SOC, it may now build the out-of-tree ISYS replacement.
```

### Quick Test Once Unblocked

If any of the above becomes available:

```bash
# 1. Install/update packages
sudo dnf install akmod-intel-ipu6 ipu6-camera-bins ipu6-camera-hal gstreamer1-plugins-icamerasrc

# 2. Install tuning files (from hal-config/)
./hal-config/install.sh

# 3. Stop software ISP
sudo systemctl stop gc2607-camera.service

# 4. Test
gst-launch-1.0 icamerasrc device-name=gc2607-uf ! video/x-raw,format=NV12,width=1280,height=720 ! filesink location=/tmp/test.raw
# Check: /tmp/test.raw should be non-zero size (1280*720*1.5 = 1382400 bytes per frame)

# 5. If working, configure v4l2-relayd
# Edit /etc/v4l2-relayd.d/icamerasrc.conf:
#   VIDEOSRC="icamerasrc device-name=gc2607-uf"
#   CARD_LABEL="GC2607 Camera"
sudo systemctl start v4l2-relayd@icamerasrc
```

## Related GitHub Issues

- [intel/ipu6-drivers#272](https://github.com/intel/ipu6-drivers/issues/272) — GC2607 support request (open, no response)
- [intel/ipu6-drivers#406](https://github.com/intel/ipu6-drivers/issues/406) — kernel 6.18 DMA warning
- [intel/ipu6-drivers#425](https://github.com/intel/ipu6-drivers/issues/425) — kernel 6.15+ API breakage

## Conclusion

The hardware ISP silicon is present and functional (it works on Windows). The
calibration data is extracted and the Linux HAL recognizes the sensor. The only
blocker is a missing kernel bridge (BE SOC) between the raw capture and the image
processor. This is Intel's move to fix — no userspace workaround exists.
