# Native HAL Stack Investigation (May 2026)

**Status:** **CLOSED — INFEASIBLE.** Hardware ISP path on this hardware/sensor is dead-end as of May 2026 due to upstream architectural decisions, not a bug we can fix.
**Goal (original):** Determine if Fedora 44's native Intel IPU6 HAL stack can replace the custom `gc2607_isp.c` software ISP.
**Conclusion:** Keep `gc2607_isp.c`. It is not a workaround — it is the only viable path.

## TL;DR — three independent blockers, any one of which is fatal

1. **Mainline kernel cannot do HW ISP, ever.** The IPU6 PSYS module (Processing System = the hardware ISP doing Bayer→NV12) was **never upstreamed** because Intel considers the ISP firmware/algorithms proprietary. Mainline kernel 6.10+ has only ISYS (raw CSI receiver). This is a policy decision by Intel, not a missing patch.
2. **The proprietary out-of-tree stack is unmaintained and lagging.** RPMFusion's IPU6 packages (`akmod-intel-ipu6`, `ipu6-camera-bins`, `ipu6-camera-hal`, `gstreamer1-plugins-icamerasrc`) have not been updated since ~Dec 2024 / Jan 2025. Intel's [`intel/ipu6-drivers`](https://github.com/intel/ipu6-drivers) repo stopped tracking kernel API changes around v6.16. F44 ships kernel ≥6.17 — the proprietary stack likely won't build/load against the current kernel even if installed.
3. **GC2607 was never accepted into Intel's IPU6 driver tree.** [Issue #272](https://github.com/intel/ipu6-drivers/issues/272) (opened Oct 2024) is still open with no resolution. The userspace HAL config files for `gc2607-uf` that ship in F44's `ipu6-camera-hal` are community-contributed leftovers, not Intel-blessed — confirmed by the May 2026 diagnostic finding that `gc2607-uf` is **absent from `/usr/share/defaults/etc/camera/libcamhal_profile.xml`'s `availableSensors` list**, so the HAL never registers it as a known sensor.

Even if you could solve any one of these, the other two would still block. Together they kill the path.

## What changed between April and May investigations

The April investigation (`docs/hardware_isp_investigation.md`) concluded "blocked by missing BE SOC bridge in mainline ISYS." That framing implied a missing puzzle piece. The May investigation revealed that framing was incomplete:

- F44 *does* ship `intel_ipu6_psys` and `ipu6-camera-hal` with GC2607 config files. So the userspace pieces look like they're there.
- But the kernel-side BE SOC bridge that connects ISYS → PSYS is **not in mainline** (and never will be — that's the PSYS module being proprietary).
- F44's shipped `gc2607-uf.xml` was *truncated* compared to the working April version: the BE SOC pipeline links were stripped out, leaving only a raw-Bayer-out CSI2 path. This isn't a bug — Intel's HAL packagers stripped the pipeline because the kernel side it requires doesn't exist.
- The May Phase 1 diagnostic (`/tmp/hal-phase2-step1.sh`, run 2026-05-03) confirmed: HAL loads the right platform plugin (`ipu6epmtl.so` for our `8086:7d19` Meteor Lake IPU), but `availableSensors` doesn't list `gc2607-uf`. Even patching that in wouldn't help, because the truncated MediaCtl pipeline can only deliver SGRBG10 — same raw output `gc2607_isp.c` is already consuming. There is no HW Bayer→NV12 conversion path on this kernel.

## What this means for the project

`gc2607_isp.c` (~600 LOC software ISP at ~4% CPU) is the **only viable path** for this sensor on this laptop until either:

- Intel changes policy and upstreams PSYS (no signal this is happening), **or**
- A community kernel BE SOC bridge driver lands in mainline (no active effort known), **and**
- Someone lands GC2607 sensor support in Intel's `ipu6-drivers` (Issue #272 untouched), **and**
- Intel/RPMFusion resume maintaining the proprietary stack against current kernels.

That's a many-year horizon at best. Not worth waiting on.

## Quarterly check (lightweight)

Worth a 5-minute glance every ~3 months at:
- [intel/ipu6-drivers commits](https://github.com/intel/ipu6-drivers/commits/master) — has Intel resumed kernel API tracking?
- [Issue #272](https://github.com/intel/ipu6-drivers/issues/272) — any GC2607 patches landing?
- [linux-media archives](https://lore.kernel.org/linux-media/) — search for `ipu6 PSYS` or `ipu6 BE SOC` — any community upstreaming effort?

If any of these change materially, reopen this investigation.

## Files referenced (kept for archeology)

| File | Why kept |
|------|----------|
| `docs/hardware_isp_investigation.md` | April investigation; first attempt at the HW ISP path |
| `docs/incidents/2026-05-fedora-44-regressions.md` | F44 upgrade context |
| `hal-config/gc2607-uf.xml` | April-era HAL config including the BE SOC pipeline; preserved as evidence of what *would* be needed if the kernel side ever exists |
| `/usr/share/defaults/etc/camera/ipu6epmtl/sensors/gc2607-uf.xml` | F44-shipped truncated version (BE SOC pipeline removed) |

## Sources for this conclusion

- [Intel IPU6 Driver — kernel.org docs](https://docs.kernel.org/driver-api/media/drivers/ipu6.html) (mainline = ISYS only)
- [Intel IPU6 Being Upstreamed In Linux 6.10 — Phoronix](https://www.phoronix.com/news/Intel-IPU6-Media-In-Linux-6.10) (PSYS explicitly out of scope)
- [Javier Tia's blog: IPU6 Webcam on Linux](https://jetm.github.io/blog/posts/ipu6-webcam-libcamera-on-linux/) (PSYS proprietary status)
- [intel/ipu6-drivers Issue #272 — Add support for GC2607 sensor](https://github.com/intel/ipu6-drivers/issues/272) (open, no progress)
- [intel/ipu6-drivers Issue #375 — Fedora rpmfusion IPU6 packages are out of date](https://github.com/intel/ipu6-drivers/issues/375) (proprietary stack unmaintained)
- [Fedora's RPM Fusion Adds Experimental Intel IPU6 Web Camera Support — Phoronix](https://www.phoronix.com/news/Fedora-Fusion-IPU6-Camera) (RPMFusion path)
