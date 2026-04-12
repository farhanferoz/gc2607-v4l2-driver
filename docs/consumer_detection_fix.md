# GC2607 ISP Consumer Detection Failure [RESOLVED]

**Status:** Fixed in commit `f314c42`. See Phase 9 in `docs/archive/PROJECT_HISTORY.md`.

---

## Problem
The GC2607 camera intermittently stops producing video. Applications (Chrome, OBS, GNOME Camera) open the camera, get a few seconds of frames, then the stream silently dies. The `gc2607-camera.service` stays running but returns to idle.

## Root Cause
**`gc2607_isp.c` uses `inotify` to detect when consumer apps open/close `/dev/video50` (the v4l2loopback output device). inotify on V4L2 character devices is unreliable — `IN_OPEN`/`IN_CLOSE` events don't always fire.**

When a consumer app opens `/dev/video50`, the inotify watch may not trigger → `consumer_count` stays 0 → the ISP never enters `streaming_loop()` → the app gets a black stream and gives up.

Conversely, inotify may miss an `IN_CLOSE` → the ISP keeps streaming to nobody → wastes power until the next check catches it.

## Evidence
Journal logs show the pattern:

```
[gc2607_isp] 1 consumer(s) detected, starting stream...
[gc2607_isp] Streaming started (exp=600 gain=4 bright=1.00)
[gc2607_isp] 150 frames | WB: R=2.07 B=1.84 | means: R=83.2 G=172.1 B=93.4  ← WORKS
[gc2607_isp] No consumers detected, stopping stream (162 frames)  ← ~10s later, drops
[gc2607_isp] Idle, waiting for consumers on /dev/video50...
```

Other sessions show RGB means of R=2.5, G=2.3, B=2.2 — essentially black, meaning the app opened the device but the ISP never transitioned to streaming.

## Current Implementation (`gc2607_isp.c`)
- `init_inotify()` watches `/dev/video50` for `IN_OPEN | IN_CLOSE` (line ~478)
- `drain_inotify()` reads events and increments/decrements `consumer_count` (line ~507)
- The idle loop uses `select()` on the inotify fd with a 2s timeout, writes standby frames
- `streaming_loop()` checks `consumer_count` every 2s via `drain_inotify()`, exits after 5 consecutive no-consumer checks (~10s)

## What Needs to Happen
**Add a `/proc/*/fd` scanning fallback to the existing inotify mechanism.**

1. Keep `inotify` as the primary fast-path detection
2. Every 2 seconds in both the idle loop AND the streaming loop, scan `/proc/[0-9]*/fd/*` symlinks pointing to `/dev/video50` to count actual consumers
3. If `/proc` count > `inotify` count, trust `/proc` (inotify missed opens)
4. If `/proc` count == 0 but `inotify` count > 0, trust `/proc` (inotify missed closes)
5. The `/proc` approach is what the docs claim was implemented ("Uses `inotify` or process scanning") but it was never coded

## Key Files

| File | Role |
|------|------|
| `gc2607_isp.c` | The C ISP daemon — needs the fix |
| `/etc/systemd/system/gc2607-camera.service` | Systemd service, calls `gc2607-service.sh` |
| `/opt/gc2607/gc2607-service.sh` | Boot script that starts the ISP |
| `/dev/video1` | Raw sensor capture (BA10 1920x1080) |
| `/dev/video50` | v4l2loopback output (YUYV 960x540) — needs reliable consumer tracking |

## Constraints
- The `/proc` scan must be efficient — don't stat every process, only those with numeric PIDs
- Must handle permission errors gracefully (can't read all `/proc/PID/fd` entries as non-root)
- Don't remove inotify — it provides instant wake-on-open when it works
- The ISP runs unprivileged (as the logged-in user via systemd), not as root
- After fixing, test: open camera in app → verify stream starts within 2s → close app → verify ISP returns to idle within ~10s
