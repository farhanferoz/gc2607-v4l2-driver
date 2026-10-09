#!/usr/bin/env bash
#
# gc2607-boot-incident.sh - runs once at boot. If the PREVIOUS boot did not
# shut down cleanly it almost certainly wedged (silent freeze), so auto-run the
# crash triage while the evidence is fresh. Triage pulls the off-box telemetry
# window from the NAS (the <=2s-before-death snapshot of C6 entry + GPU IRQ).
#
set -u
TAG=gc2607-boot-incident
TRIAGE=/home/ff235/dev/gc2607-v4l2-driver/gc2607-crash-triage.sh

# no previous boot recorded -> nothing to judge
if ! journalctl -b -1 -n1 --no-pager >/dev/null 2>&1; then
  logger -t "$TAG" "no previous boot recorded; skip"; exit 0
fi

# Every clean poweroff/reboot ends in systemd-shutdown (PID 1's last stage), which logs under its
# own identifier; a wedge or an un-resumed hibernate never gets there. Matching message TEXT was
# wrong: sssd_kcm's idle exit "Shutting down (status = 0)" at 19:21 passed the 2026-10-09 hibernate
# hang (and the 09-22 forced power-off) as clean, so neither was triaged. This test classifies all
# 16 boots in the journal on 2026-10-09 correctly.
if journalctl -b -1 -t systemd-shutdown -n1 --no-pager -q 2>/dev/null | grep -q .; then
  logger -t "$TAG" "previous boot shut down cleanly; no triage needed"
  exit 0
fi

logger -t "$TAG" "previous boot did NOT shut down cleanly (suspected silent wedge) -> running crash triage -1"
if [ -x "$TRIAGE" ]; then
  if "$TRIAGE" -1 >/dev/null 2>&1; then
    logger -t "$TAG" "crash triage complete -> /var/log/gc2607-crash-triage/ (see telemetry-window.txt for the C6/GPU-IRQ state at death)"
  else
    logger -t "$TAG" "crash triage exited non-zero; check /var/log/gc2607-crash-triage/"
  fi
else
  logger -t "$TAG" "ERROR: triage script not executable at $TRIAGE"
fi
