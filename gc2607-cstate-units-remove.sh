#!/usr/bin/env bash
#
# gc2607-cstate-units-remove.sh - remove the two stale C-state systemd units
# left over from retired freeze-mitigation experiments. Both are disabled,
# inactive, and superseded by the SN740 ASPM-L1 fix (gc2607-nvme-aspm), which
# is the sole active freeze mitigation.
#
# WHY: gc2607-cstate-fix.service (Rung-1 global C6/C10-off) and
#   gc2607-cstate-test.service (Phase-1 test1b, retired by gc2607-cstate-clear.sh)
#   are dead weight left in /etc/systemd/system. Neither is referenced by any
#   other unit or tool; the shared drop-in /usr/lib/systemd/system/service.d/
#   10-timeout-abort.conf is a stock Fedora file used by 212 other units and
#   is NOT touched by this script.
#
# WHAT (one-shot, idempotent):
#   1. verify both are disabled + inactive (abort if not);
#   2. rm the two unit files from /etc/systemd/system;
#   3. systemctl daemon-reload + reset-failed.
#
# REVERSE: unit file text is preserved in this script's git history
#   (`git log -p -- gc2607-cstate-units-remove.sh` / repo history before this
#   commit) if either ever needs to be redeployed.
#
# JOB INTERFERENCE: none. Both units are already inactive; no camera/telemetry/
#   XPU/drive impact. The SN740 ASPM-L1 fix and freeze watchers are untouched.
#
# Usage: sudo /home/ff235/dev/gc2607-v4l2-driver/gc2607-cstate-units-remove.sh
#
set -euo pipefail
UNITS=(gc2607-cstate-fix.service gc2607-cstate-test.service)

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
say() { printf '\n=== %s ===\n' "$*"; }

say "PRE-CHECK: both units must be disabled + inactive"
for u in "${UNITS[@]}"; do
  en=$(systemctl is-enabled "$u" 2>/dev/null) || true
  ac=$(systemctl is-active "$u" 2>/dev/null) || true
  [ -n "$en" ] || en="not-found"
  [ -n "$ac" ] || ac="not-found"
  printf '%-30s enabled=%s active=%s\n' "$u" "$en" "$ac"
  if [ "$en" != "disabled" ] && [ "$en" != "not-found" ]; then
    echo "ABORT: $u is not disabled (enabled=$en) -- refusing to remove" >&2
    exit 1
  fi
  if [ "$ac" != "inactive" ] && [ "$ac" != "not-found" ]; then
    echo "ABORT: $u is not inactive (active=$ac) -- refusing to remove" >&2
    exit 1
  fi
done

say "REMOVE unit files"
for u in "${UNITS[@]}"; do
  f="/etc/systemd/system/$u"
  if [ -f "$f" ]; then
    rm -v "$f"
  else
    echo "$f already absent"
  fi
done

say "RELOAD systemd"
systemctl daemon-reload
for u in "${UNITS[@]}"; do systemctl reset-failed "$u" 2>/dev/null || true; done

say "VERIFY"
for u in "${UNITS[@]}"; do
  systemctl status "$u" --no-pager 2>&1 | head -3 || true
done

say "DONE"
echo "Both stale C-state units removed. SN740 ASPM-L1 fix (gc2607-nvme-aspm) is unaffected."
