#!/usr/bin/env bash
#
# gc2607-power-ab.sh [seconds] — controlled A/B of the CPU power-management lever (EPP), same load.
#
# Measures the SAME machine, SAME idle load, back-to-back on battery in two states:
#   B = UNTUNED : EPP = balance_performance  (the performance-leaning default — "without the power-mgmt tuning")
#   A = TUNED   : EPP = balance_power         (what balanced-battery applies on battery — "with the tuning")
# so the difference in draw is attributable to power management, not to a load/moment difference
# (the caveat a single across-days before/after can't escape).
#
# Isolation: only EPP is toggled (and restored on exit). The governor stays powersave-HWP in both states
# (that's HWP dynamic mode, not a frequency cap), so this measures the EPP lever specifically. tuned
# profile / PSR / wifi / backlight are left untouched.
#
# Needs: ON BATTERY, machine left idle for ~2x[seconds] (default 60 each => ~2.5 min). Root for EPP writes.
#
set +e
WIN="${1:-60}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$REPO/docs/power-measurements.log"
EPPS=(/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference)

ac=$(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1)
[ "$ac" = 0 ] || { echo "On AC (online=$ac). UNPLUG the charger — the total-draw number needs the battery discharging." >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo (EPP writes need root): sudo bash $0" >&2; exit 1; }

SAVED=$(cat "${EPPS[0]}")
set_epp(){ for f in "${EPPS[@]}"; do echo "$1" > "$f"; done; echo ">> EPP now: $(cat "${EPPS[0]}") (all cores)"; }
restore(){ for f in "${EPPS[@]}"; do echo "$SAVED" > "$f"; done; echo ">> EPP restored to $SAVED"; }
trap restore EXIT

echo "############ B = UNTUNED (EPP=balance_performance) ############"
set_epp balance_performance; sleep 3
bash "$REPO/gc2607-power-measure.sh" "$WIN" "AB-untuned-balance_performance"

echo; echo "############ A = TUNED (EPP=balance_power) ############"
set_epp balance_power; sleep 3
bash "$REPO/gc2607-power-measure.sh" "$WIN" "AB-tuned-balance_power"

echo; echo "############ A/B SUMMARY (constant load) ############"
grep -E 'AB-(untuned-balance_performance|tuned-balance_power)$' "$LOG" | tail -2 | awk -F, '
  /untuned/        { b=$10 }
  /tuned-balance_power/ { a=$10 }
  END{
    printf "  B UNTUNED (balance_performance): %s W\n", b
    printf "  A TUNED   (balance_power):       %s W\n", a
    if (b+0>0 && a+0>0) printf "  => power-management saving: %.2f W (%.0f%% lower) at the same idle load\n", b-a, (1-a/b)*100
    else print  "  (one run did not record a total — was the charger plugged in?)"
  }'
