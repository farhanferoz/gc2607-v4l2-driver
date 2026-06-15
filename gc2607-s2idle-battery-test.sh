#!/usr/bin/env bash
#
# gc2607-s2idle-battery-test.sh [--win SECONDS] — the ONLY valid s2idle test: on battery, idle.
#
# WHY ON BATTERY
#   On AC the Embedded Controller (EC, ACPI GPE 0x6E) fires charge-progress events that wake s2idle
#   every few seconds, faking an early-wake / 0% S0ix failure. That contaminates any plugged-in run.
#   The 2026-06-15 overnight death happened on battery, so battery+idle is the only honest measurement.
#   This script refuses to run on AC, waits for you to unplug, then measures and gives the verdict.
#
# WHAT IT TELLS YOU
#   - Does the machine STAY asleep ~WIN s (good) or wake early (bad)?
#   - Is EC GPE 0x6E STILL storming on battery (real firmware defect) or quiet (suspend is fine)?
#   - S0ix residency % and, since you're on battery, the actual suspend wattage.
#
# USAGE (needs sudo; suspends once for ~WIN s, auto-wakes)
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-s2idle-battery-test.sh
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-s2idle-battery-test.sh --win 90
#
set +e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$REPO/gc2607-suspend-check.sh"
WIN=60
while [ $# -gt 0 ]; do
  case "$1" in
    --win) shift; WIN="$1" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Needs root (debugfs counters + rtcwake). Re-run: sudo bash $0 $*"; exit 1
fi
[ -r "$CHECK" ] || { echo "missing $CHECK"; exit 1; }

ac_online(){ cat /sys/class/power_supply/A*/online 2>/dev/null | head -1; }
cap(){ cat /sys/class/power_supply/BAT0/capacity 2>/dev/null; }
gpe(){ read -r c _ < /sys/firmware/acpi/interrupts/gpe6E 2>/dev/null; echo "${c:-0}"; }

# 1) require battery power — wait for unplug
if [ "$(ac_online)" = "1" ]; then
  echo ">>> UNPLUG THE CHARGER to start the test (waiting up to 2 min)..."
  for i in $(seq 1 120); do
    [ "$(ac_online)" = "0" ] && break
    sleep 1
  done
fi
if [ "$(ac_online)" = "1" ]; then
  echo "Still on AC after 2 min — aborting. Unplug and re-run."; exit 1
fi
echo "On battery at $(cap)%. Good."
if [ "$(cap)" -lt 15 ] 2>/dev/null; then
  echo "WARNING: battery <15% — charge a bit first so this test doesn't flatten it. Aborting."; exit 1
fi

# 2) baseline EC-GPE rate while AWAKE (does it storm on battery at all?)
echo
echo "Sampling EC GPE 0x6E rate while awake on battery (10 s)..."
g0=$(gpe); sleep 10; g1=$(gpe)
awk "BEGIN{r=($g1-$g0)/10; printf \"  awake rate: %.1f events/s\", r;
  if(r<0.2) print \"  => QUIET on battery (EC storm was AC-only; suspend should hold).\";
  else if(r<2) print \"  => some activity.\";
  else print \"  => STILL STORMING on battery (real EC/firmware defect — the ECW1 no-handler suspect).\"}"

# 3) the real suspend measurement (on battery)
echo
bash "$CHECK" "$WIN" "on-battery idle"

echo
echo "READ THE RESULT:"
echo "  - wall time ~${WIN}s + low EC-GPE delta + suspend draw <=1 W  => suspend is HEALTHY; the overnight"
echo "    death was just the ~20% starting charge. No firmware bug; just don't leave it asleep near-empty."
echo "  - early wake + gpe6E delta high + draw >2 W => EC GPE storms on battery too = the real drain bug;"
echo "    next step is the Huawei EC/ECW1 firmware angle, not PCIe wakeup."
