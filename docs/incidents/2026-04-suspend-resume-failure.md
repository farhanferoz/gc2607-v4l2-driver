# INC-001: Camera Service Stays Dead After Suspend

**Date:** 2026-04-12 → 2026-04-20 (8 days undetected)
**Severity:** Medium — camera unavailable, manual recovery required
**Status:** Fixed

## Summary

`gc2607-camera.service` stopped cleanly during system suspend on 2026-04-12 18:47
and never restarted. It remained dead through 8 days of suspend/resume cycles
until the user noticed camera apps couldn't find a device.

## Impact

Camera unavailable to GNOME Camera, Chrome, OBS, and other PipeWire consumers
after the first suspend event following boot. Users had to manually run
`sudo systemctl start gc2607-camera.service` to recover.

## Root Cause

The service has two relevant systemd directives:

```ini
Conflicts=sleep.target        # Added Phase 8 to prevent -EBUSY on suspend
Restart=on-abnormal            # Only restarts on crashes, not clean stops
```

When the system enters `sleep.target`, systemd stops any unit with
`Conflicts=sleep.target`. This is a **clean stop** (exit status 0), not a crash —
so `Restart=on-abnormal` does not trigger on resume.

The service was missing a mechanism to restart on resume.

## Evidence (journalctl)

```
Apr 12 18:47:54 systemd-logind[1275]: Suspending...
Apr 12 18:47:59 systemd[1]: Reached target sleep.target - Sleep.
Apr 12 18:47:59 systemd[1]: Stopping gc2607-camera.service ...
Apr 12 18:47:59 gc2607-service.sh[3640792]: [gc2607_isp] Exiting
Apr 12 18:47:59 systemd[1]: gc2607-camera.service: Deactivated successfully.
```

`journalctl --list-boots` confirmed no reboot between 2026-04-06 and the
incident report date, so the service stayed dead through multiple suspend cycles.

## Fix Applied

Added a `systemd-sleep` hook that restarts the service on the `post` event
(fires after every resume from suspend, hibernate, hybrid-sleep, or
suspend-then-hibernate):

**File:** `/usr/lib/systemd/system-sleep/gc2607-resume`
**Source tracked in repo:** `gc2607-resume`

```bash
#!/bin/bash
case "$1" in
    post)
        systemctl start gc2607-camera.service
        ;;
esac
```

`systemctl start` is idempotent — no harm if the service is already active.

## Install / Verify

```bash
# Install
sudo cp gc2607-resume /usr/lib/systemd/system-sleep/gc2607-resume
sudo chmod +x /usr/lib/systemd/system-sleep/gc2607-resume

# Verify
ls -la /usr/lib/systemd/system-sleep/gc2607-resume   # must be executable
systemctl is-active gc2607-camera.service            # should be "active"

# Test: suspend the laptop, resume, then:
systemctl is-active gc2607-camera.service            # should still be "active"
```

## Alternatives Considered

### A. Remove `Conflicts=sleep.target`
Rely solely on `SET_SYSTEM_SLEEP_PM_OPS` in the kernel driver to force-release
hardware. Simpler (no hook), but removes the belt-and-braces defence against
`-EBUSY` panics. **Rejected** — kept defence-in-depth.

### B. `Restart=always`
Would restart on any stop, but creates a race: systemd tries to restart while
the system is still entering sleep, potentially causing `Conflicts=` cycles or
delaying suspend. **Rejected** — wrong semantics.

### C. Separate `gc2607-camera-resume.service` with `WantedBy=suspend.target`
More systemd-idiomatic than a shell script. Equivalent effect, but more files
and more moving parts. **Not necessary** — the sleep hook is simpler and
standard.

### D. Track user-initiated stops with a flag file
If the user ran `systemctl stop` manually, don't auto-restart on next resume.
**Rejected** — overengineered. A user who wants the service permanently off
can `systemctl disable gc2607-camera.service`.

## Prevention / Monitoring

The service lifecycle now depends on TWO controls. **Both must be present** —
removing one without the other re-breaks the camera:

| Control | Role | Location |
|---------|------|----------|
| `Conflicts=sleep.target` | Stop on suspend (prevents -EBUSY) | `/etc/systemd/system/gc2607-camera.service` |
| Sleep hook | Restart on resume | `/usr/lib/systemd/system-sleep/gc2607-resume` |

If troubleshooting the camera being dead, check:

```bash
# Is the hook present and executable?
ls -la /usr/lib/systemd/system-sleep/gc2607-resume

# What was the last service event?
journalctl -u gc2607-camera.service --since "-24h" --no-pager | tail -20

# Were there recent suspend events?
journalctl --since "-24h" | grep -iE "suspend|sleep.target" | tail -10
```

## Future Reference for Agents

If an agent is asked to modify the service lifecycle, they MUST preserve both
controls or design an equivalent replacement. The constraints are:
1. Service must stop cleanly before `sleep.target` activates (kernel panic risk)
2. Service must restart after resume (or the camera stays dead)
3. Clean stops are not crashes — `Restart=on-abnormal` does not cover suspend
