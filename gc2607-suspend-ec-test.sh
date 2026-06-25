#!/usr/bin/env bash
#
# gc2607-suspend-ec-test.sh [--win SECONDS]
#   DECISIVE test: is EC GPE 0x6E what keeps s2idle out of deep S0ix? Two real on-battery suspends:
#     arm A "ec-baseline"   : gpe6E unmasked (current state)  -> expect 0% S0ix, ~2.3 W (= the overnight drain)
#     arm B "ec-gpe-masked" : gpe6E MASKED during suspend     -> if S0ix jumps and draw drops, EC GPE 0x6E
#                                                                IS the cause and the fix is known.
#   Restores gpe6E to UNMASKED on exit (EXIT trap, fires even on Ctrl-C / early-wake).
#
# WHY THIS EXISTS  (supersedes the 06-15 "AC-artifact, suspend is fine" assumption)
#   2026-06-25 on-battery A/B (gc2607-suspend-ab.sh) found S0ix = 0% in EVERY config — NVMe ASPM on or off,
#   PCIe wakeup armed or disarmed made no difference (2.26 vs 2.40 W = noise). Meanwhile gpe6E fired ~80x
#   per 4-min suspend (~0.33/s) with AC online = 0 (on battery). That REFUTES the earlier "GPE 0x6E is an
#   AC-charging artifact; on battery suspend is fine" note (which was never actually measured on battery).
#   The EC (\_SB_.PC00.LPCB.HWEC) raising its SCI GPE every ~3 s keeps the SoC out of S0ix = the real drain.
#   Masking that one GPE during suspend is the runtime-equivalent of the standard fix (acpi.ec_no_wakeup=1
#   / a mask-on-suspend sleep hook). This proves the mechanism and previews the win before any reboot.
#
# WHAT MASKING DOES / SAFETY
#   gpe6E is the EC's single SCI GPE for ALL its events (battery %, thermal, AC, lid, hotkeys). Masking it
#   ONLY during the test suspend means those EC notifications aren't serviced while asleep — which is
#   exactly what we want for S0ix, and what ec_no_wakeup does in a principled way. The RTC (a different
#   GPE) still auto-wakes the machine, so masking does not strand it. Reversible: unmasked on exit.
#   Masking is a standard kernel debug op (Documentation: /sys/firmware/acpi/interrupts/gpeXX accepts
#   mask/unmask). It does NOT touch the silent-freeze fix (NVMe ASPM) at all.
#
# USAGE (root; UNPLUG the charger; leave idle ~WIN*2 + overhead)
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-suspend-ec-test.sh             # 240 s/arm
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-suspend-ec-test.sh --win 300
#
set +e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$REPO/gc2607-suspend-check.sh"
LOG="$REPO/docs/suspend-measurements.log"
GPE=/sys/firmware/acpi/interrupts/gpe6E
WIN=240
while [ $# -gt 0 ]; do
  case "$1" in
    --win) shift; WIN="$1" ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done

[ "$(id -u)" -eq 0 ] || { echo "Needs root (rtcwake + GPE mask). Re-run: sudo bash $0 $*"; exit 1; }
[ -r "$CHECK" ] || { echo "missing $CHECK"; exit 1; }
[ -w "$GPE" ]   || { echo "missing/!writable $GPE — gpe6E node not present on this kernel?"; exit 1; }

ac_online(){ cat /sys/class/power_supply/A*/online 2>/dev/null | head -1; }
cap(){ cat /sys/class/power_supply/BAT0/capacity 2>/dev/null; }

# --- require battery ---
if [ "$(ac_online)" = "1" ]; then
  echo ">>> UNPLUG the charger to start (waiting up to 2 min)..."
  for i in $(seq 1 120); do [ "$(ac_online)" = "0" ] && break; sleep 1; done
fi
[ "$(ac_online)" = "0" ] || { echo "Still on AC after 2 min — aborting. Unplug and re-run."; exit 1; }
[ "$(cap)" -ge 15 ] 2>/dev/null || { echo "Battery <15% — charge first. Aborting."; exit 1; }
echo "On battery at $(cap)%. Two arms x ${WIN}s. Leave the machine idle."

# --- always leave gpe6E unmasked ---
restore(){ echo unmask > "$GPE" 2>/dev/null; echo ">> gpe6E restored: $(cat "$GPE" 2>/dev/null)"; }
trap restore EXIT

# --- optional: name what GPE 0x6E actually dispatches (needs acpica-tools) ---
echo; echo "===== what is GPE 0x6E? (EC = \_SB_.PC00.LPCB.HWEC) ====="
if command -v iasl >/dev/null 2>&1 && [ -r /sys/firmware/acpi/tables/DSDT ]; then
  TMP=$(mktemp -d)
  cp /sys/firmware/acpi/tables/DSDT "$TMP/DSDT.dat" 2>/dev/null
  ( cd "$TMP" && iasl -d DSDT.dat >/dev/null 2>&1 )
  if [ -r "$TMP/DSDT.dsl" ]; then
    echo "-- _GPE handler for bit 0x6E (_L6E / _E6E):"
    awk '/Method *\(_GPE\._[LE]6E/{f=1} f{print "   "$0} f&&/^    \}/{exit}' "$TMP/DSDT.dsl" | head -40
    echo "-- _Qxx query handlers under the EC (what the EC can notify):"
    grep -nE 'Method *\(_Q[0-9A-F][0-9A-F]' "$TMP/DSDT.dsl" | sed 's/^/   /' | head -40
  fi
  rm -rf "$TMP"
else
  echo "  (acpica-tools not installed — to name it:  sudo dnf install -y acpica-tools  then re-run)"
  echo "  Not required for the test below; this is just to confirm masking is side-effect-safe."
fi

run_arm(){ echo; echo "######################## $1 ########################"; bash "$CHECK" "$WIN" "$1"; }

# arm A — baseline, gpe6E unmasked (how it drains today)
echo unmask > "$GPE" 2>/dev/null
run_arm "ec-baseline gpe6E-unmasked"

# arm B — gpe6E masked during suspend (the fix preview)
echo mask > "$GPE" 2>/dev/null
echo ">> gpe6E now: $(cat "$GPE")"
run_arm "ec-gpe-masked"
echo unmask > "$GPE" 2>/dev/null

# --- summary ---
echo; echo "######################## EC-GPE TEST SUMMARY (on battery, constant idle) ########################"
awk -F, '
  $NF ~ /ec-baseline/   {b_w=$6; b_s=$5; b_wall=$4}
  $NF ~ /ec-gpe-masked/ {m_w=$6; m_s=$5; m_wall=$4}
  END{
    printf "  baseline  (gpe6E unmasked): %6s W   S0ix %s%%   wall %ss\n", b_w, b_s, b_wall
    printf "  gpe6E MASKED              : %6s W   S0ix %s%%   wall %ss\n", m_w, m_s, m_wall
    if(b_w+0>0 && m_w+0>0) printf "  => masking GPE 0x6E saves : %.2f W in suspend\n", b_w-m_w
    if(m_s+0>=50) print  "  => VERDICT: EC GPE 0x6E CONFIRMED as the S0ix blocker. Fix it (see below)."
    else if(m_s!="" && m_s+0<50) print "  => masking did NOT restore S0ix — the blocker is elsewhere; do not deploy the mask fix."
  }' "$LOG"
echo
echo "IF CONFIRMED, two ways to make it permanent (no freeze-fix risk — this is independent of NVMe ASPM):"
echo "  (1) kernel cmdline (cleanest):  sudo grubby --update-kernel=ALL --args=acpi.ec_no_wakeup=1   then reboot"
echo "  (2) reboot-free sleep hook   :  mask gpe6E on suspend / unmask on resume (mirrors gc2607-resume)"
echo "  After either, RE-RUN gc2607-suspend-check.sh on battery to confirm S0ix>=90% and draw<=1 W,"
echo "  and verify lid-open + power-button still wake the machine."
