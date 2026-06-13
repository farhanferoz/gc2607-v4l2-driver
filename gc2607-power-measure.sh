#!/usr/bin/env bash
#
# gc2607-power-measure.sh [seconds] [note] — measure system power draw, READ-ONLY (applies no tuning).
#
# WHAT IT REPORTS
#   - TOTAL SYSTEM draw  (battery energy delta) — the real runtime number; needs the charger UNPLUGGED.
#   - RAPL package draw  (CPU+SoC only)         — works on AC too; needs sudo to read energy_uj.
#   - Context: kernel, power source, tuned profile, EPP, governor, backlight, PSR, loadavg.
#
# IT ALSO LOGS every run (one CSV line) to docs/power-measurements.log so results accumulate and
# stay comparable run-to-run — this is the whole point: don't re-measure from scratch, append + compare.
#
# USAGE
#   UNPLUG the charger, stop touching the machine, then:
#       sudo bash gc2607-power-measure.sh            # 60 s window, no note
#       sudo bash gc2607-power-measure.sh 90 "idle tuned 7.0.12"
#   (sudo only for the RAPL/powertop breakdown; the TOTAL number reads fine without it.)
#
# BASELINE (2026-06-12, untuned, on battery, light use): TOTAL ~25.8 W  (~2.65 h) / package ~17 W.
# TARGET after tuning: ~13-16 W (~4.5-5 h light use).
#
set +e
WIN="${1:-60}"
NOTE="${2:-}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$REPO/docs/power-measurements.log"
BASE_TOTAL=25.8
line(){ printf '\n========== %s ==========\n' "$1"; }

bat=/sys/class/power_supply/BAT0
ac=$(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1)
kernel=$(uname -r)
tuned=$(tuned-adm active 2>/dev/null | sed 's/.*: //')
epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
psr=$(grep -o 'i915.enable_psr=[0-9]' /proc/cmdline)
bl=$(awk 'BEGIN{c="/sys/class/backlight/intel_backlight/brightness";m="/sys/class/backlight/intel_backlight/max_brightness";getline cv<c;getline mv<m;if(mv>0)printf "%d",cv*100/mv}')

line "STATE"
echo "kernel      : $kernel"
echo "AC online   : ${ac:-?}  (0 = on battery = good for this test, 1 = plugged in)"
echo "battery     : $(cat $bat/status 2>/dev/null)  $(cat $bat/capacity 2>/dev/null)%"
echo "tuned/EPP   : ${tuned} / ${epp}   governor: ${gov}   backlight: ${bl}%   ${psr}"

line "MEASURING ${WIN}s — leave the machine alone..."
rapl=/sys/class/powercap/intel-rapl:0/energy_uj
maxr=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj 2>/dev/null)
e0=$(cat $rapl 2>/dev/null); b0=$(cat $bat/energy_now 2>/dev/null); t0=$(date +%s.%N)
sleep "$WIN"
e1=$(cat $rapl 2>/dev/null); b1=$(cat $bat/energy_now 2>/dev/null); t1=$(date +%s.%N)
dt=$(awk "BEGIN{print $t1-$t0}")

rapl_w=""; total_w=""
if [ -n "$e0" ] && [ -n "$e1" ]; then
  de=$((e1-e0)); [ "$de" -lt 0 ] 2>/dev/null && de=$((de+maxr))
  rapl_w=$(awk "BEGIN{printf \"%.2f\", $de/1e6/$dt}")
  echo "RAPL package (CPU+SoC only): ${rapl_w} W"
else
  echo "RAPL package: not readable (run with sudo)."
fi
if [ -n "$b0" ] && [ -n "$b1" ] && [ "$b1" -lt "$b0" ] 2>/dev/null; then
  db=$((b0-b1))
  total_w=$(awk "BEGIN{printf \"%.2f\", $db/1e6/($dt/3600)}")
  hrs=$(awk "BEGIN{e=$(cat $bat/energy_full 2>/dev/null)/1e6; printf \"%.1f\", e/$total_w}")
  echo "TOTAL SYSTEM draw: ${total_w} W   <<< the real number  (=> ~${hrs} h on a full charge)"
  echo "   vs baseline ${BASE_TOTAL} W (untuned 06-12): $(awk "BEGIN{printf \"%.0f%%\", (1-$total_w/$BASE_TOTAL)*100}") lower"
else
  echo "TOTAL SYSTEM draw: battery not discharging — UNPLUG the charger and re-run for the real number."
fi

# --- append to the comparison log ---
mkdir -p "$(dirname "$LOG")"
if [ ! -f "$LOG" ]; then
  echo "timestamp,kernel,ac_online,tuned,epp,governor,backlight_pct,window_s,rapl_pkg_w,total_system_w,loadavg1,note" > "$LOG"
fi
ts=$(date '+%Y-%m-%d %H:%M:%S')
la=$(cut -d' ' -f1 /proc/loadavg)
echo "${ts},${kernel},${ac:-?},${tuned},${epp},${gov},${bl},${WIN},${rapl_w:-NA},${total_w:-NA},${la},${NOTE}" >> "$LOG"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$LOG" 2>/dev/null
echo
echo "logged -> docs/power-measurements.log"

line "POWERTOP (optional breakdown, measure-only)"
if command -v powertop >/dev/null; then
  powertop --csv=/tmp/gc2607-powertop.csv --time="$WIN" >/dev/null 2>&1
  grep -iaE 'discharge rate|The battery reports' /tmp/gc2607-powertop.csv 2>/dev/null | head
  echo "full report: /tmp/gc2607-powertop.csv"
else
  echo "powertop not installed (optional): sudo dnf install powertop"
fi
line "DONE"
