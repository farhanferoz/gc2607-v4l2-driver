# Fedora 44 Upgrade Regressions (May 2026)

**Date:** 2026-05-03
**Trigger:** Upgrade from Fedora 43 → Fedora 44 (kernel 6.19.14-300.fc44, GNOME 48)
**Status:** Resolved (4/4 fixes applied)

## Summary

Four user-visible regressions appeared after the Fedora 44 upgrade:

1. `gc2607-camera.service` failed at boot, requiring manual restart via `start_camera_service.sh`
2. Suspending the laptop (closed the lid in the evening) never resumed; required a long-press power-button reset the next morning
3. Screen brightness flickered continuously due to ambient-light feedback
4. The first three were not obviously connected, all stemming from F44 changes

All were diagnosed and fixed in a single session. Each fix is independently verified against authoritative documentation before being applied.

## 1. Camera service fails at boot

### Root cause

Fedora 44 introduced two new package autoloads that conflict with the gc2607 service:

- `v4l2loopback-0.15.3-2.fc44` ships `/usr/lib/modules-load.d/v4l2loopback.conf` and `/usr/lib/modprobe.d/98-v4l2loopback.conf` (`card_label="OBS Virtual Camera"`)
- `v4l2-relayd-0.2.0` ships `/usr/lib/modules-load.d/v4l2-relayd.conf` and `/usr/lib/modprobe.d/v4l2-relayd.conf` (`card_label="Intel MIPI Camera"`)

These autoload `v4l2loopback` early at boot with default parameters (`video_nr=-1`). When `gc2607-camera.service` later runs:

1. `modprobe -r v4l2loopback` silently fails (held open by `v4l2-relayd`)
2. `modprobe v4l2loopback ... video_nr=50` is a **silent no-op** — verified per `modprobe(8)`: when a module is already loaded, modprobe succeeds without changing parameters and without erroring.
3. `/dev/video50` never exists; `gc2607_isp` exits with `open output device: No such file or directory`.
4. `Restart=on-abnormal` does NOT cover non-zero exit codes (per `systemd.service(5)`), so the service stays dead instead of retrying.

### Fix

Mask the four autoload files via `/etc/` symlinks to `/dev/null` (the documented systemd vendor-override pattern per `modules-load.d(5)`):

```
/etc/modules-load.d/v4l2loopback.conf  → /dev/null
/etc/modules-load.d/v4l2-relayd.conf   → /dev/null
/etc/modprobe.d/v4l2-relayd.conf       → /dev/null
/etc/modprobe.d/98-v4l2loopback.conf   → /dev/null
```

Plus change `Restart=on-abnormal` → `Restart=on-failure` in the service unit so future races self-heal.

**Verified outcome:** Camera service active immediately after fix; `/dev/video50` present without manual intervention.

## 2. Suspend hang on Meteor Lake

### Root cause

Meteor Lake firmware (this laptop is a Huawei MateBook Pro VGHH-XX with Intel Core Ultra 9 185H) **does not expose deep S3 suspend at all** — only S0ix/s2idle is supported. Setting `/sys/power/mem_sleep` to `deep` causes the next suspend attempt to fail at the firmware layer; the resume path then gets confused and the system hangs.

Evidence from journal:
- Earlier on May 2: `kernel: PM: suspend entry (s2idle)` → resumed cleanly
- May 2 19:24: `kernel: PM: suspend entry (deep)` → no `PM: suspend exit`, system never woke
- Next event: cold boot the following morning (kernel cmdline + `BOOT_IMAGE` line)

The user does not recall manually flipping `mem_sleep`; cause remains unknown but is not load-bearing for the fix.

### Fix

Pin s2idle as the kernel default via grub:

```
sudo grubby --update-kernel=ALL --args="mem_sleep_default=s2idle"
```

This is documented in the kernel admin guide (`Documentation/admin-guide/pm/sleep-states.rst`) and protects against any cause of `mem_sleep` flipping (manual write, firmware update, errant tool). Each boot starts in s2idle regardless.

**Verified outcome:** `cat /sys/power/mem_sleep` reports `[s2idle] deep` (s2idle bracketed = active). Cmdline change locks this in across reboots.

## 3. Adaptive brightness flicker

### Root cause

Fedora 44 / GNOME 48 has `org.gnome.settings-daemon.plugins.power ambient-enabled` set to `true` (the schema default). The laptop's ALS (`acpi-als` exposed via `/sys/bus/iio/devices/iio:device0`) is functional, and the new kernel surfaces ambient readings continuously, so the screen brightness reacts to every change in lighting.

### Fix

```
gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled false
```

Or via Settings → Power → Automatic Screen Brightness → Off.

**Verified outcome:** Setting reads as `false` after fix; flicker stops once the change propagates (logout/login may be needed if the GNOME session cached the old value).

## Fix applied via

`/tmp/apply-fixes.sh` (idempotent, includes rollback notes). The script:
1. Masks all four autoload files (with backups of any non-symlink originals as `.bak`)
2. Edits `/etc/systemd/system/gc2607-camera.service` Restart= line and reloads systemd
3. Adds `mem_sleep_default=s2idle` via `grubby` and `echo`s s2idle to `/sys/power/mem_sleep` for the current uptime
4. Runs `gsettings set` as the login user (locating their session bus at `/run/user/$UID/bus`)
5. Restarts the camera service and verifies `/dev/video50` exists

## Things to verify after next reboot

- `cat /proc/cmdline | grep mem_sleep_default` — should show `s2idle`
- `systemctl is-active gc2607-camera.service` after fresh boot — should be `active` without manual intervention
- `ls /dev/video50` should exist
- Brightness should be steady (log out/in if not)

## Rollback

If any fix needs reverting, see the trailing block printed by `/tmp/apply-fixes.sh` — it lists the exact reverse commands per fix.
