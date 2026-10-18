#!/bin/bash
#
# Wait until gc2607-camera.service is running the ISP: the unit is active AND its current
# invocation has logged the ISP's idle line. `systemctl is-active` alone passes too early:
# gc2607-service.sh reaches `exec gc2607_isp` only ~3.5 s after the start, so a binary that
# exits at once was installed as "OK" (review #6, 2026-10-18). Used by the install scripts.
#
# Usage: gc2607-wait-ready.sh [TIMEOUT_SECONDS=15]   exit 0 = ready, 1 = not ready in time
#
set -u

SERVICE=gc2607-camera.service
READY='[gc2607_isp] Idle, waiting for consumers'
deadline=$((SECONDS + ${1:-15}))

while [ "$SECONDS" -lt "$deadline" ]; do
    # -I: this invocation only, so a line from the process just replaced cannot pass
    if systemctl is-active --quiet "$SERVICE" &&
        journalctl -u "$SERVICE" -I -o cat --no-pager 2>/dev/null | grep -F "$READY" >/dev/null; then
        exit 0
    fi
    sleep 0.5
done
exit 1
