#!/usr/bin/env bash
#
# gc2607-suspend-crashfix-test.sh [--win SECONDS]
#   Answers ONE question by measurement, not argument: did the silent-freeze fix (NVMe SN740 ASPM-L1
#   disabled) break suspend / cause the 0% S0ix? Two full-length battery suspends, back to back:
#     arm A "crashfix-ON"  : l1_aspm=0  (current freeze fix)        -> baseline (~2.3 W, 0% S0ix)
#     arm B "crashfix-OFF" : l1_aspm=1  (fix REVERTED = pre-fix)    -> does reverting it restore S0ix?
#   Reads slp_s0 AND substate_residencies each arm. Restores l1_aspm=0 (fix ON) on exit via trap.
#
# WHY  (2026-06-25) The user recalls suspend was fine BEFORE the crash fix. Prior data already points away
#   from the fix: (1) the measured S0ix blocker is TCSS/Thunderbolt + IOE die — a DIFFERENT subsystem than
#   the NVMe the fix touches; (2) the earlier ab-aspm-on arm (fix reverted) still showed 0% S0ix but
#   early-woke at 10 s, so it was not airtight. This re-runs the counterfactual cleanly, full-length.
#   EXPECTED: identical ~0% S0ix in both arms => fix exonerated; the Thunderbolt/IOE blocker is independent
#   and pre-existing. If arm B recovers S0ix => the fix IS implicated and we have a real tradeoff to weigh.
#
# SAFETY  Reverting the fix (ASPM-L1 ON) for ~WIN s is freeze-safe: the silent freezes took 1.5-7.5 h
#   (#18-#20). The trap restores l1_aspm=0 (fix ON) on exit even on Ctrl-C / early-wake. Touches ONLY the
#   NVMe l1_aspm knob — nothing else.
#
# USAGE (root; UNPLUG charger; ~WIN*2 + overhead idle)
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-suspend-crashfix-test.sh --win 240
#
set +e
WIN=240
while [ $# -gt 0 ]; do
  case "$1" in
    --win) shift; WIN="$1" ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done
[ "$(id -u)" -eq 0 ] || { echo "Needs root. Re-run: sudo bash $0 $*"; exit 1; }

PMC=/sys/kernel/debug/pmc_core
bat=/sys/class/power_supply/BAT0
L1=/sys/bus/pci/devices/0000:01:00.0/link/l1_aspm
[ -w "$L1" ] || { echo "no $L1 — NVMe not at 01:00.0?"; exit 1; }
SAVED=$(cat "$L1")   # expected 0 = fix ON

ac_online(){ cat /sys/class/power_supply/A*/online 2>/dev/null | head -1; }
if [ "$(ac_online)" = "1" ]; then
  echo ">>> UNPLUG the charger to start (waiting up to 2 min)..."
  for i in $(seq 1 120); do [ "$(ac_online)" = "0" ] && break; sleep 1; done
fi
[ "$(ac_online)" = "0" ] || { echo "Still on AC — aborting (need battery for the draw)."; exit 1; }
[ "$(cat $bat/capacity 2>/dev/null)" -ge 15 ] 2>/dev/null || { echo "Battery <15% — charge first."; exit 1; }
echo "On battery at $(cat $bat/capacity)%. Two arms x ${WIN}s. (Reverting the fix for arm B is freeze-safe at this duration.)"

restore(){ [ -n "$SAVED" ] && echo "$SAVED" > "$L1" 2>/dev/null; echo ">> l1_aspm restored to $(cat "$L1") (0 = freeze fix ON)"; }
trap restore EXIT

snap(){
  printf 'slp_s0 %s\n' "$(cat "$PMC/slp_s0_residency_usec" 2>/dev/null)"
  [ -r "$PMC/substate_residencies" ] && awk 'NR>1 && NF>=2 {print $1, $NF}' "$PMC/substate_residencies"
}

run_arm(){ # $1=label  $2=l1value
  echo; echo "######## $1 (l1_aspm=$2) ########"
  echo "$2" > "$L1" 2>/dev/null; echo "  l1_aspm now: $(cat "$L1")"
  local B A b0 b1 t0 t1 wall ds0 frac
  B=$(snap); b0=$(cat $bat/energy_now 2>/dev/null); t0=$(date +%s)
  echo "  suspending ${WIN}s (self-wakes)..."; sync
  rtcwake -m mem -s "$WIN" >/dev/null 2>&1
  A=$(snap); b1=$(cat $bat/energy_now 2>/dev/null); t1=$(date +%s); wall=$((t1-t0))
  echo "  wall asleep: ${wall}s  (wakeup IRQ $(cat /sys/power/pm_wakeup_irq 2>/dev/null))"
  [ "$wall" -lt "$((WIN-30))" ] 2>/dev/null && echo "  *** EARLY WAKE — S0ix% from a short window is less reliable; note the substate deltas instead."
  echo "  residency moved (name: +delta usec):"
  local moved; moved=$({ echo "$B"; echo "$A"; } | awk 'seen[$1]++{d=$2-b[$1]; if(d>0)printf "     %-16s +%s\n",$1,d; next}{b[$1]=$2}')
  echo "${moved:-     (NONE)}"
  ds0=$(echo "$moved" | awk '/slp_s0/{gsub(/\+/,"",$2);print $2;f=1}END{if(!f)print 0}')
  frac=$(awk "BEGIN{w=$wall;if(w>0)printf \"%.0f\",${ds0:-0}/1e6/w*100;else print 0}")
  echo "  S0ix this window: ${frac}%"
  if [ -n "$b0" ] && [ -n "$b1" ] && [ "$b1" -lt "$b0" ] 2>/dev/null && [ "$wall" -gt 0 ]; then
    awk "BEGIN{printf \"  suspend draw: %.2f W\n\",($b0-$b1)/1e6/($wall/3600)}"
  fi
}

run_arm "ARM A  crashfix-ON  (current safe state)" 0
run_arm "ARM B  crashfix-OFF (fix REVERTED = pre-fix ASPM)" 1
echo "$SAVED" > "$L1" 2>/dev/null   # back to fix-on immediately (trap also does it)

echo
echo "######## VERDICT ########"
echo "  Both arms ~0% S0ix and ~same draw  => the crash fix is NOT the cause; the Thunderbolt/IOE blocker"
echo "                                         is independent and was there before the fix. Exonerated."
echo "  Arm B (fix off) S0ix jumps / draw drops => the crash fix IS implicated; real tradeoff to discuss."
echo "  Machine left in the SAFE state (l1_aspm=0, freeze fix ON). Confirm: cat $L1   # = 0"
