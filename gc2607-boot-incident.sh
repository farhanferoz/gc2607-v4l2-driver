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

# clean shutdowns leave one of these fingerprints in the tail of the boot;
# a silent wedge leaves none (the last lines are just normal operation).
if journalctl -b -1 -n 150 --no-pager 2>/dev/null \
     | grep -qiE "systemd-shutdown|Reached target.*(Shutdown|Power-Off|Reboot|Halt)|Powering off|Rebooting\.|Shutting down"; then
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
