# GC2607 camera stack review (2026-10-18)

> **Correction (later the same day):** this review checked robustness and idle CPU but not picture quality or
> CPU while streaming. Its "mostly built properly" verdict does not hold for the image pipeline, and "ahead on
> usable AE" is withdrawn: the ISP's logs show exposure never comes back down. Findings, evidence, fixes and
> validation: `docs/reviews/2026-10-18-camera-fix-handover.md`.

Scope: the sensor driver (`gc2607.c`), the patched ipu-bridge, the service (`gc2607-camera.service`,
`/opt/gc2607/gc2607-service.sh`, `gc2607-restart-wireplumber.sh`), the userspace ISP (`gc2607_isp.c`), the
install/update path, and a comparison with five community projects (detail:
`docs/reviews/2026-10-18-community-comparison.md`). Out of scope: the non-camera power scripts (workspace-sync D138).
Read-only: nothing was changed. Laptop: Fedora 44, kernel 7.2.11-200.fc44, libcamera 0.7.2, v4l2loopback 0.15.4.

## Verdict

Mostly built properly. The driver is the most complete of the six GC2607 drivers found on power management, sleep
handling, privacy LED and libcamera-mandatory controls; the ISP validates formats and buffer sizes, cleans up on
failure and recovers from stalls; DKMS rebuilds both modules on kernel updates (built for 7.2.9, 7.2.10, 7.2.11) and
the service had 0 failures in 14 days (44 starts, matching suspend/resume). The problems sit around the core: a
broken setup script and a stale runbook (both bite on the next reinstall), video at 16 fps, ~3 % of a core burned
while idle, and rollback checks that run too early to catch a bad build. Nothing is urgent while the laptop runs.

## Measurements (2026-10-18)

| What | Value | How |
|---|---|---|
| Delivered frame rate | 16.1 fps | ISP log: 150 frames per 9.30 s, two sessions (journal) |
| Advertised frame rate | 30 fps (mode/log); controls imply 32.8 fps | `max_fps = 30`; 134.4 MHz / (2048 x 2003) |
| Idle CPU of the service | 369 CPU-s in ~3 h 15 min idle = ~3 % of a core | `systemctl show -p CPUUsageNSec`, nobody holding /dev/video50 (`fuser`) |
| Exposure used, last 60 days | 23 % of streaming time above 1100 lines (exp 1350-2002) | 4,546 ISP log lines, each = 150 frames |
| Installed driver source | = repo HEAD (`1ca2115eb53d`) | sha256 of /usr/src/gc2607-1.0/gc2607.c vs `git show HEAD:gc2607.c` |
| Installed ISP binary | = repo binary; rebuild today differs by 48 B | consistent with glibc-devel update 2026-10-01; built 09-23 10:03, source unchanged since |
| Service failures, 14 days | 0 (44 starts) | `journalctl -u gc2607-camera.service` |

## Findings, worst first

| # | Severity | Finding | Where | Fix |
|---|---|---|---|---|
| 1 | Medium-High | Full setup aborts: after `install -m 0644 ...gc2607-camera.service` the body of the old heredoc (`[Unit]`...`SVCEOF`) was left behind when 0030017 (2026-09-23) removed its `cat > ... << SVCEOF` opener. `[Unit]` runs as a command -> exit 127 under `set -e`, before `daemon-reload`, `enable`, `start`. `bash -n` passes. The `unit` sub-command still works. | `gc2607-setup-service.sh:110-128` | Delete lines 110-128. |
| 2 | Medium | Runbook tells the reader to hand-build and copy modules after a kernel update - the method `gc2607-driver-install.sh`'s header says silently put the January driver back on 7.2.5-7.2.7. DKMS now does this. README still points at upstream's `init_camera.sh`; `gc2607-install.sh` hard-codes `kernel/v6.x` URLs (cannot work on 7.x). | `docs/operations-runbook.md:50-61`, `README.md:90,144`, `gc2607-install.sh:78,140` | Rewrite the section: DKMS rebuilds; check `dkms status`; driver change -> `gc2607-driver-install.sh`. Mark `gc2607-install.sh` / `init_camera.sh` historical. |
| 3 | Medium | 16 fps video. HTS 2048 / VTS 2003 gives 16 fps (measured; AlexDaichendt measured 16.12 for the same timing). Their HTS 1959 / VTS 1116 on the stock PLL measured 29.90 fps with clean CSI, but caps exposure at ~1100 lines - which the last 60 days exceeded 23 % of the time (low light). Separately, `max_fps`, the log line and `V4L2_CID_PIXEL_RATE` (bus rate, not readout rate) misreport the timing. | `gc2607.c:53-56,363` | Best: 30 fps base timing plus a writable VBLANK that the ISP's AE extends only in low light (standard sensor practice). Quick alternative: 30 fps outright (darker/noisier in low light). Either way fix the advertised values. |
| 4 | Medium | Idle CPU ~3 %: `get_consumer_count()` walks every `/proc/<pid>/fd` every 2 s, idle and streaming. The header claims "zero CPU usage" idle. The walk exists because inotify open/close on the device was found unreliable (`docs/consumer_detection_fix.md`). v4l2loopback 0.15.4 (installed) has `V4L2_EVENT_PRI_CLIENT_USAGE`, queued when a reader starts or stops streaming (v4l2loopback.c `client_usage_queue_event`, called from STREAMON/STREAMOFF) - the mechanism v4l2-relayd and AlexDaichendt's stack use. | `gc2607_isp.c:963-1039,1341-1385` | Subscribe to the client-usage event on the output fd; drop inotify and the /proc walk. Removes the CPU cost and the need for root to see other users' fds. |
| 5 | Medium-Low | Every service start (boot, each resume, each crash restart) restarts the user's WirePlumber, i.e. the audio session manager: a short audio interruption, mid-call if the ISP restarts during a call. Fixed `sleep 5` guess; on failure to find the user it exits 0 silently. Needed today because the service unloads and reloads v4l2loopback on every start, recreating /dev/video50 as an output-only device. | `gc2607-restart-wireplumber.sh`, `gc2607-service.sh:75-85` | After (4), test whether loading v4l2loopback once (modules-load + modprobe options) and never reloading it removes the need; log when the restart is skipped or fails. Unverified - test first. |
| 6 | Medium-Low | Rollback checks run too early: both installers test `systemctl is-active` 2 s after restart, but the service script `exec`s the ISP only after ~3.5 s (`sleep 1` + `sleep 2` + media-ctl). A broken new binary/driver passes the check, so the rollback never fires. | `gc2607-install-isp.sh:21-23`, `gc2607-driver-install.sh:123-125` | Wait (up to ~15 s) for the ISP's "Idle, waiting for consumers" log line or its process. |
| 7 | Low-Medium | Probe failure leaves the sensor powered: `err_power` does `put_noidle` / `disable` / `set_suspended` without `gc2607_power_off()`, so regulators and clock stay enabled after a failed chip-ID read. | `gc2607.c:1040-1044` | Call `gc2607_power_off()` in `err_power`. |
| 8 | Low-Medium | Gate covers only the driver source. Nothing checks the ISP binary, the /opt copy of the service script, or that both DKMS packages are installed for the running kernel. | workspace-sync `monitoring/validate.sh` `c_camera_driver_source` | Extend the check: /opt script = repo (modulo the `SCRIPT_DIR` line), /opt ISP = repo binary, `dkms status` installed for `uname -r` for both packages. |
| 9 | Low | Driver hygiene: reset GPIO requested de-asserted (physical HIGH) at probe and left so if power-on fails at the clock - the same "driving a line into an unpowered sensor" the 09-23 power_off fix addressed, at the other end; I2C short transfers not detected (`ret < 0` only); TRY formats not handled (legacy subdev API); ~6 info-level kernel lines per camera use; `MODULE_AUTHOR("Your Name")`. | `gc2607.c:834,148-196,527-568,381-451,1104` | Request reset `GPIOD_OUT_HIGH`; check `ret != 2/3`; `dev_dbg` for routine lines; set author. Not needed: a stream-off guard - kernel 7.2.11's `call_s_stream()` already drops repeated calls (v4l2-subdev.c:484). |
| 10 | Low | Service script: hard-coded entity names (`Intel IPU6 CSI2 0`), fixed sleeps and one pass then exit; runs everything as root with no hardening. antonbiluta's `gc2607-isp-start.sh` discovers entities (`media-ctl -e`) and waits with retries. | `gc2607-service.sh:19-69`, unit | Discover entities, poll for the topology; after (4) run the ISP as an unprivileged user (`User=` + `ExecStartPre=+` for module/media setup). |
| 11 | Low | Dead weight: `hal-config/` (dead per `docs/native_hal_investigation.md`), `ipu-bridge-oot/7.0.12/` (superseded by the DKMS pre-build; untracked build artefacts beside it), `apply_ltm()` (~140 lines, disabled), Python fallback with `.python-path` -> miniconda, three `.bak` files in /opt/gc2607, stale comments (AE "centre-weighted", "zero CPU"). | as named | Archive or delete; keep the fallback only if it is tested. |
| 12 | Info | The bridge DKMS pre-build downloads `ipu-bridge.c` for the exact kernel from git.kernel.org at every kernel update (tarball fallback ~150 MB); it needs network and has no checksum, but fails loudly offline. Better than AlexDaichendt's pinned copy. | `/usr/src/ipu-bridge-gc2607-1.0/dkms-prebuild.sh` | None needed. |
| 13 | Option | Rotation: AlexDaichendt, zylona and fstronin add a DMI upside-down quirk for HUAWEI VGHH-XX (this model) to ipu-bridge, so the kernel reports rotation 180. The ISP rotates in software already, so this only matters if the libcamera route is revived. | their `ipu-bridge.c:139-145` | Add the hunk to the pre-build sed if libcamera is revived. |

## Comparison (detail in the community report)

| Layer | This fork | Best alternative seen | Verdict |
|---|---|---|---|
| Sensor driver | most complete on PM/sleep/LED/libcamera controls | AlexDaichendt: 30 fps timing, linear gain codes (code/64), readout pixel rate | behind on fps and gain model, ahead on the rest |
| ipu-bridge | DKMS pre-build fetches the exact kernel's source | homezloco same technique (minor-version tag) | level or ahead; lacks the rotation quirk |
| Image processing | custom C ISP, AE with highlight cap | AlexDaichendt/zylona: Intel HAL + Windows tuning (vendor colour, AE not working, patched HAL build, Arch only); fstronin: libcamera soft ISP + CCM yaml, no rebuild | ahead on usable AE; libcamera route still blocked here by the missing GC2607 helper/rotation (own May test: upside-down, overexposed) and a kernel oops on soft-IPA close recorded 2026-05-14 (`AI_RULES.md:116`) |
| Packaging | DKMS + scripts, Fedora | fstronin .deb + weekly health check; Alex AUR | level for Fedora |
| Service | single unit, lazy activation via /proc walk | v4l2-relayd with the client-usage event (Alex, fstronin); antonbiluta's dynamic discovery | behind on consumer detection (4) and discovery (10), ahead on sleep integration |
| Upstream (abbood) | contains all 18 upstream commits, 39 ahead | dormant since 2026-01-07; PR #4 closed unmerged 2026-05-03 | nothing to pull |

## Open decisions for the owner

1. Frame rate: 30 fps base with low-light fallback (recommended), 30 fps outright, or keep 16 fps (fix the advertised values either way).
2. Whether to switch on the camera briefly to confirm the sensor itself (not the ISP) runs at 16 fps - lights the privacy LED for a few seconds.
3. Which findings to fix, and in what order. Suggested first batch, all small: 1, 2, 7, 6.
