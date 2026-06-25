#!/usr/bin/env bash
#
# gc2607-suspend-ltr-test.sh [--win SECONDS]
#   Tests the ONE software-fixable hypothesis for the 0% S0ix: ignore the ACTIVE LTRs (auto-detected from
#   ltr_show) during a single battery suspend and see if S0ix residency recovers. Reads slp_s0 AND
#   substate_residencies deltas, so it also settles whether the legacy counter is just wrong on MTL.
#   Fully reversible: restores every LTR it touched via ltr_restore on exit (no reboot needed).
#
# WHY  (2026-06-25, from gc2607-suspend-pmc-probe.sh, read awake+AC, cross-checked w/ prior battery suspends)
#   - Package reaches PC10 (Package C10 >> C2) => CPU deep-idle is fine; the gap is the SoC S0ix state.
#   - Earlier REAL battery suspends already measured slp_s0 = 0% (S0ix never asserted).
#   - The usual MTL LTR culprits (GBE idx3, ME idx6) advertise NO requirement here. The only valid active
#     LTRs are idx 25 PMC0:IOE_PMC (~71 us) and idx 40 PMC1:SOUTHPORT_D (~70 us) — IOE-die / Thunderbolt.
#   - TCSS (Thunderbolt) is NOT power-gated (TCSS_PGD0_PG_STS=0, PCH-IP TCSS=On) and IOE_COND_MET_S02I2_*=0
#     => looks like the IOE-die / Thunderbolt power-gating blocker (ThinkPad P1 Gen 7 class), NOT the GBE/ME
#     fix. This script TESTS that instead of assuming it: if ignoring those LTRs unblocks S0ix => software
#     win (branch A); if not => IOE-die/CSME firmware blocker (branch B) confirmed by measurement.
#
# OUTCOME READING (baseline is the already-measured 0% S0ix / ~2.1-2.6 W from prior battery suspends):
#   slp_s0 delta ~ WIN  => S0ix REACHED: ltr_ignore is the fix (branch A). Persist via a sleep hook.
#   slp_s0 still 0 but a SUBSTATE residency moved => MTL counter was the wrong lens (branch C); ~fine.
#   slp_s0 0 AND no substate moved => IOE-die/firmware blocker (branch B); not software-fixable here.
#
# SAFETY: ltr_ignore only PERMITS deeper idle; applied just before a self-waking suspend; every touched
#   index is un-ignored via ltr_restore on exit (trap fires on Ctrl-C too). Independent of the freeze fix.
#
# USAGE (root; UNPLUG charger; ~WIN s idle)
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-suspend-ltr-test.sh --win 240
#
set +e
WIN=240
while [ $# -gt 0 ]; do
  case "$1" in
    --win) shift; WIN="$1" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done
[ "$(id -u)" -eq 0 ] || { echo "Needs root. Re-run: sudo bash $0 $*"; exit 1; }

PMC=/sys/kernel/debug/pmc_core
bat=/sys/class/power_supply/BAT0
[ -w "$PMC/ltr_ignore" ] || { echo "no $PMC/ltr_ignore — intel_pmc_core missing?"; exit 1; }
HAVE_RESTORE=0; [ -w "$PMC/ltr_restore" ] && HAVE_RESTORE=1

ac_online(){ cat /sys/class/power_supply/A*/online 2>/dev/null | head -1; }
if [ "$(ac_online)" = "1" ]; then
  echo ">>> UNPLUG the charger to start (waiting up to 2 min)..."
  for i in $(seq 1 120); do [ "$(ac_online)" = "0" ] && break; sleep 1; done
fi
[ "$(ac_online)" = "0" ] || { echo "Still on AC — aborting (need battery for the draw number)."; exit 1; }
[ "$(cat $bat/capacity 2>/dev/null)" -ge 15 ] 2>/dev/null || { echo "Battery <15% — charge first."; exit 1; }

# --- auto-detect ACTIVE LTRs (decoded Non-Snoop or Snoop > 0), excluding the read-only aggregates ---
mapfile -t IDX < <(awk '
  /CURRENT_PLATFORM|AGGREGATED_SYSTEM/ { next }
  {
    idx=$1; ns=0; sn=0
    if (match($0, /Non-Snoop\(ns\): *[0-9]+/)) { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); ns=s }
    if (match($0, /[^-]Snoop\(ns\): *[0-9]+/))  { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); sn=s }
    if (ns+0>0 || sn+0>0) print idx
  }' "$PMC/ltr_show")

if [ "${#IDX[@]}" -eq 0 ]; then echo "No active LTRs detected in ltr_show — nothing to ignore. Stop."; exit 0; fi
echo "On battery at $(cat $bat/capacity)%. Active LTR indices to ignore:"
for i in "${IDX[@]}"; do
  printf '   idx %s  %s\n' "$i" "$(awk -v x="$i" '$1==x{print $2}' "$PMC/ltr_show")"
done

# --- restore on exit ---
restore(){
  if [ "$HAVE_RESTORE" = 1 ]; then
    for i in "${IDX[@]}"; do echo "$i" > "$PMC/ltr_restore" 2>/dev/null; done
    echo ">> restored ${#IDX[@]} LTR(s) via ltr_restore (verify: grep LTR_IGNORE $PMC/ltr_show | grep -c ' 1$')"
  else
    echo ">> NOTE: no ltr_restore on this kernel — the ignores clear on REBOOT. (They only permit deeper idle.)"
  fi
}
trap restore EXIT

snap(){
  printf 'slp_s0 %s\n' "$(cat "$PMC/slp_s0_residency_usec" 2>/dev/null)"
  [ -r "$PMC/substate_residencies" ] && awk 'NR>1 && NF>=2 {print $1, $NF}' "$PMC/substate_residencies"
}

# --- apply ignores, suspend once, measure ---
for i in "${IDX[@]}"; do echo "$i" > "$PMC/ltr_ignore" 2>/dev/null; done
echo "ignored. LTR_IGNORE now set on: $(awk '/LTR_IGNORE: 1/{c++} END{print c+0}' "$PMC/ltr_show") IP(s)"
B=$(snap); b0=$(cat $bat/energy_now 2>/dev/null); t0=$(date +%s)
echo "Suspending ${WIN}s (self-wakes)..."; sync
rtcwake -m mem -s "$WIN" >/dev/null 2>&1; rc=$?
A=$(snap); b1=$(cat $bat/energy_now 2>/dev/null); t1=$(date +%s)
wall=$((t1 - t0))
[ "$rc" -ne 0 ] && echo "WARN: rtcwake rc=$rc"

echo
echo "######## RESULT (LTRs ignored) ########"
echo "wall asleep: ${wall}s   last wakeup IRQ: $(cat /sys/power/pm_wakeup_irq 2>/dev/null)"
echo "residency counters that MOVED (name: +delta usec):"
moved=$({ echo "$B"; echo "$A"; } | awk '
  seen[$1]++ {d=$2-b[$1]; if(d>0) printf "   %-16s +%s\n", $1, d; next}
  {b[$1]=$2}')
echo "${moved:-   (NONE moved)}"
ds0=$(echo "$moved" | awk '/slp_s0/{gsub(/\+/,"",$2); print $2; f=1} END{if(!f)print 0}')
frac=$(awk "BEGIN{w=$wall; if(w>0)printf \"%.0f\", ${ds0:-0}/1e6/w*100; else print 0}")
echo "S0ix (slp_s0) this window: ${frac}% of wall"
if [ -n "$b0" ] && [ -n "$b1" ] && [ "$b1" -lt "$b0" ] 2>/dev/null && [ "$wall" -gt 0 ]; then
  awk "BEGIN{printf \"suspend draw: %.2f W\n\", ($b0-$b1)/1e6/($wall/3600)}"
fi
echo
echo "VERDICT:"
if [ "${frac:-0}" -ge 50 ] 2>/dev/null; then
  echo "  S0ix RECOVERED with LTRs ignored => BRANCH A (software-fixable). Next: persist ignore via a"
  echo "  suspend sleep-hook (echo the indices to ltr_ignore on suspend), re-confirm with gc2607-suspend-check.sh."
elif [ -n "$moved" ]; then
  echo "  slp_s0 flat but a substate moved => BRANCH C: legacy counter is the wrong lens on MTL; suspend may"
  echo "  actually be ~OK. Compare the draw above to the ~2.1 W baseline."
else
  echo "  Nothing moved => BRANCH B: IOE-die / Thunderbolt (TCSS) power-gating blocker — NOT LTR-fixable."
  echo "  Software is exhausted; remaining levers are BIOS (Thunderbolt/Modern-Standby/Linux toggle) or a"
  echo "  Huawei CSME/BIOS firmware update. ~2 W is then this board's s2idle floor."
fi
