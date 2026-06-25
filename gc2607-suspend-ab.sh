#!/usr/bin/env bash
#
# gc2607-suspend-ab.sh [--win SECONDS] [--no-aspm-arm] [--no-wakeup-arm]
#   Controlled A/B of the two deep-S0ix blockers, to ATTRIBUTE the overnight suspend drain to a number
#   instead of guessing. Mirrors gc2607-power-ab.sh, but for suspend (s2idle) instead of runtime idle.
#
# WHY THIS EXISTS
#   2026-06-25: suspended on battery at 80%, woke 14 h later at 28%  =>  ~36 Wh / 14 h = ~2.6 W in s2idle.
#   A healthy Meteor Lake S0ix idles ~0.3-1 W, so this is ~3x too high. Two textbook deep-S0ix blockers
#   are present RIGHT NOW and visible in sysfs:
#     (1) NVMe ASPM-L1 DISABLED  (l1_aspm=0 on 0000:01:00.0)  -- this IS the SILENT-FREEZE FIX
#         (gc2607-nvme-aspm.service -> gc2607-aspm-off). A link with ASPM-L1 off cannot reach L1.2, and on
#         Meteor Lake the SoC package cannot reach the DEEPEST S0ix substate unless every PCIe link is in
#         L1.2. So this costs the whole-package deep-S0ix miss, not just the link's own milliwatts.
#     (2) 7 wakeup-armed PCIe devices: the Thunderbolt-4 / USB4 / xHCI cluster + Root Port #10 (00:06.0,
#         which hosts the NVMe). TB4/USB4/xHCI with wakeup armed are the other classic thing that keeps
#         SoC IP blocks from power-gating in S0ix.
#   The old docs/power-tuning-plan.md dismissed PCIe ASPM as "<0.5 W, not worth reopening a freeze
#   variable" -- but that estimate was for RUNTIME idle. In SUSPEND, ASPM-off blocks the package deep-idle
#   itself, which is far larger. The runtime conclusion does NOT transfer to suspend. This measures it.
#
# WHAT IT DOES  (each arm = ONE real rtcwake suspend on battery, logged to docs/suspend-measurements.log)
#   arm 1  "ab-baseline"      : ASPM off + wakeup armed        (EXACTLY how it suspended overnight)
#   arm 2  "ab-aspm-on"       : ASPM-L1 ENABLED, wakeup armed  (isolates the freeze-fix SUSPEND tax)
#   arm 3  "ab-wake-disarmed" : ASPM off + TB4/xHCI/RP wakeup DISARMED  (isolates the freeze-SAFE lever)
#   Then prints suspend-W + S0ix% per arm and the two deltas at constant idle load:
#       freeze-fix suspend tax = arm1 - arm2   (the price of the silent-freeze cure, in suspend watts)
#       wakeup-disarm saving   = arm1 - arm3   (FREE -- independent of the freeze fix)
#
# SAFETY
#   - EXIT trap (fires even on Ctrl-C / early-wake) restores l1_aspm to its saved value (0 = freeze fix ON)
#     and RE-ARMS every wakeup it touched. The machine is left in the safe freeze-fix state.
#   - arm 2 re-enables the freeze variable for only ~WIN seconds. The silent freezes took 1.5-7.5 h to
#     appear (#18-#20), so a ~2-minute window is freeze-safe.
#   - Refuses to run on AC: the Embedded Controller fires charge-progress GPEs that wake s2idle every few
#     seconds and fake an early-wake / low-S0ix failure. Also refuses below 15% (it runs 3 suspends).
#
# USAGE (root; UNPLUG the charger; leave it idle for ~WIN*3 + overhead)
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-suspend-ab.sh             # 120 s/arm
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-suspend-ab.sh --win 240   # cleaner watts
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-suspend-ab.sh --no-aspm-arm   # skip the ASPM-on arm
#
set +e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$REPO/gc2607-suspend-check.sh"
LOG="$REPO/docs/suspend-measurements.log"
WIN=120
DO_ASPM=1
DO_WAKE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --win) shift; WIN="$1" ;;
    --no-aspm-arm)   DO_ASPM=0 ;;
    --no-wakeup-arm) DO_WAKE=0 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done

[ "$(id -u)" -eq 0 ] || { echo "Needs root (rtcwake + sysfs writes). Re-run: sudo bash $0 $*"; exit 1; }
[ -r "$CHECK" ] || { echo "missing $CHECK (the per-arm measurement primitive)"; exit 1; }

ac_online(){ cat /sys/class/power_supply/A*/online 2>/dev/null | head -1; }
cap(){ cat /sys/class/power_supply/BAT0/capacity 2>/dev/null; }

# --- require battery (wait for unplug) ---
if [ "$(ac_online)" = "1" ]; then
  echo ">>> UNPLUG the charger to start the A/B (waiting up to 2 min)..."
  for i in $(seq 1 120); do [ "$(ac_online)" = "0" ] && break; sleep 1; done
fi
[ "$(ac_online)" = "0" ] || { echo "Still on AC after 2 min — aborting. Unplug and re-run."; exit 1; }
[ "$(cap)" -ge 15 ] 2>/dev/null || { echo "Battery <15% — charge first (this runs 3 suspends). Aborting."; exit 1; }
arms=$(( 1 + DO_ASPM + DO_WAKE ))
echo "On battery at $(cap)%. Running ${arms} arm(s) x ${WIN}s (+ overhead). Leave the machine idle."

# --- the knobs ---
NVME=0000:01:00.0
L1=/sys/bus/pci/devices/$NVME/link/l1_aspm
SAVED_L1=$(cat "$L1" 2>/dev/null)   # expected 0 (freeze fix). Restored on exit no matter what.

# snapshot every currently wakeup-ENABLED pci device, to disarm in arm 3 and restore on exit
mapfile -t WAKE_ON < <(for w in /sys/bus/pci/devices/*/power/wakeup; do
  [ "$(cat "$w" 2>/dev/null)" = "enabled" ] && echo "$w"; done)

restore(){
  [ -n "$SAVED_L1" ] && echo "$SAVED_L1" > "$L1" 2>/dev/null
  for w in "${WAKE_ON[@]}"; do echo enabled > "$w" 2>/dev/null; done
  echo ">> restored SAFE state: l1_aspm=$(cat "$L1" 2>/dev/null) (0=freeze fix on), ${#WAKE_ON[@]} wakeup arm(s) re-enabled"
}
trap restore EXIT

run_arm(){ echo; echo "######################## $1 ########################"; bash "$CHECK" "$WIN" "$1"; }

# arm 1 — exactly how it suspended overnight
[ -n "$SAVED_L1" ] && echo "$SAVED_L1" > "$L1" 2>/dev/null
for w in "${WAKE_ON[@]}"; do echo enabled > "$w" 2>/dev/null; done
run_arm "ab-baseline aspm-off wake-armed"

# arm 2 — isolate the freeze-fix suspend tax (ASPM-L1 briefly ON)
if [ "$DO_ASPM" = 1 ]; then
  echo 1 > "$L1" 2>/dev/null
  echo ">> arm 2: l1_aspm temporarily set to $(cat "$L1" 2>/dev/null) (ASPM-L1 on) — freeze-safe for ~${WIN}s"
  run_arm "ab-aspm-on wake-armed"
  [ -n "$SAVED_L1" ] && echo "$SAVED_L1" > "$L1" 2>/dev/null   # straight back to freeze-fix state
fi

# arm 3 — isolate the freeze-SAFE lever (disarm wakeup; ASPM stays off)
if [ "$DO_WAKE" = 1 ]; then
  for w in "${WAKE_ON[@]}"; do echo disabled > "$w" 2>/dev/null; done
  echo ">> arm 3: ${#WAKE_ON[@]} TB4/xHCI/root-port wakeup arm(s) disarmed (ASPM stays off)"
  run_arm "ab-wake-disarmed aspm-off"
  for w in "${WAKE_ON[@]}"; do echo enabled > "$w" 2>/dev/null; done
fi

# --- summary (last matching row per arm wins) ---
# log columns: timestamp,kernel,ac_online,wall_s,s0ix_pct,suspend_w,note
echo; echo "######################## A/B SUMMARY (constant idle, on battery) ########################"
awk -F, '
  $NF ~ /ab-baseline/      {b_w=$6; b_s=$5}
  $NF ~ /ab-aspm-on/       {a_w=$6; a_s=$5}
  $NF ~ /ab-wake-disarmed/ {w_w=$6; w_s=$5}
  END{
    printf "  arm1 baseline (aspm-off, wake-armed) : %6s W   S0ix %s%%   <- how it slept overnight\n", b_w, b_s
    if(a_w!="") printf "  arm2 aspm-ON  (wake-armed)           : %6s W   S0ix %s%%\n", a_w, a_s
    if(w_w!="") printf "  arm3 wake-DISARMED (aspm-off)        : %6s W   S0ix %s%%\n", w_w, w_s
    if(a_w+0>0 && b_w+0>0) printf "  => freeze-fix suspend tax : %.2f W  (arm1 - arm2 = cost of the silent-freeze cure)\n", b_w-a_w
    if(w_w+0>0 && b_w+0>0) printf "  => wakeup-disarm saving   : %.2f W  (arm1 - arm3 = FREE, independent of the freeze fix)\n", b_w-w_w
    if((a_w!="" && a_w+0<=0) || (w_w!="" && w_w+0<=0)) print  "  (an arm logged NA watts — window too short to register; re-run with --win 240)"
  }' "$LOG"
echo
echo "Machine left in the SAFE state (freeze fix on, wakeup re-armed). Confirm:  cat $L1   # must read 0"
echo "Raw per-arm detail + the named waker (which ACPI GPE fired) are in the arm output above; rows in docs/suspend-measurements.log"
