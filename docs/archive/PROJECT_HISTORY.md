# Project History & Current State

This document serves as the chronological save-state for the GC2607 camera driver project. Agents should read this to understand *how* the system evolved, what was tried, and exactly what the current state is.

## 1. Current State (As of April 2026)

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
