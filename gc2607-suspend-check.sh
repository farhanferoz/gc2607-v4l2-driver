#!/usr/bin/env bash
#
# gc2607-suspend-check.sh [wake_seconds] [note] — measure SUSPEND (s2idle) health, with one real suspend cycle.
#
# WHY THIS EXISTS
#   On 2026-06-15 the laptop was left suspended (s2idle) overnight at 23:13 and was FLAT by morning
#   (~70 Wh drained in ~9 h => ~4 W in suspend). A healthy Meteor Lake S0ix idles ~0.3-1 W. That gap
#   means the SoC was NOT reaching the deep S0ix substate. This tool measures the S0ix residency
#   FRACTION across a short real suspend so the drain is a number, not a guess — and logs it so
#   before/after a wakeup-source change is directly comparable.
#
# WHAT IT REPORTS
#   - S0ix residency fraction  = time in deep S0ix / wall time asleep.  >=90% good; <50% = NOT sleeping deep.
#   - Suspend power draw       = battery energy delta / wall time asleep (needs charger UNPLUGGED).
#   - Wakeup-armed devices     = PCI devices with power/wakeup=enabled (TB4/USB4/xHCI block deep S0ix).
#
# HOW IT WORKS
#   Snapshots pmc_core S0ix residency + battery energy, suspends via rtcwake for WAKE_SECONDS (auto-wakes,
#   no key press), re-snapshots, prints deltas. Suspend mode = whatever /sys/power/mem_sleep defaults to
#   (currently s2idle, pinned by mem_sleep_default=s2idle on the cmdline).
#
# USAGE  (NEEDS sudo for debugfs + rtcwake; UNPLUG charger for the power number)
#     sudo bash gc2607-suspend-check.sh                 # 30 s suspend, no note
#     sudo bash gc2607-suspend-check.sh 30 "baseline TB4 wakeup on"
#     sudo bash gc2607-suspend-check.sh 30 "TB4 wakeup disabled"   # after a change, to compare
#
# BASELINE (2026-06-15 overnight, inferred): ~4 W in suspend, S0ix fraction unknown -> this tool fills it in.
# TARGET: S0ix fraction >=90%, suspend draw <=1 W (=> days on a charge, not hours).
#
set +e
WAKE="${1:-30}"
NOTE="${2:-}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$REPO/docs/suspend-measurements.log"
line(){ printf '\n========== %s ==========\n' "$1"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "This test needs root (debugfs S0ix counters + rtcwake suspend)."
  echo "Re-run:  sudo bash $0 ${WAKE} \"${NOTE}\""
  exit 1
fi

PMC=/sys/kernel/debug/pmc_core
S0IX="$PMC/slp_s0_residency_usec"
bat=/sys/class/power_supply/BAT0
ac=$(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1)
kernel=$(uname -r)

if [ ! -r "$S0IX" ]; then
  echo "WARN: $S0IX not readable — pmc_core debugfs missing; S0ix fraction will be NA."
fi

line "STATE"
echo "kernel       : $kernel"
echo "AC online    : ${ac:-?}   (0 = on battery = required for the power number)"
echo "battery      : $(cat $bat/status 2>/dev/null)  $(cat $bat/capacity 2>/dev/null)%"
echo "mem_sleep    : $(cat /sys/power/mem_sleep 2>/dev/null)"
echo "wake after   : ${WAKE}s (rtcwake auto-wake)"

if [ "${ac:-1}" = "1" ]; then
  echo
  echo "  !!! ON AC — RESULT IS NOT TRUSTWORTHY. While charging, the Embedded Controller (EC, GPE 0x6E)"
  echo "      fires charge-progress events that wake s2idle every few seconds, faking an early-wake/low-S0ix"
  echo "      failure that does NOT occur on battery. Run this UNPLUGGED + idle for a real verdict."
fi

line "WAKEUP-ARMED DEVICES (PCIe layer — note: an EC GPE storm wakes via IRQ 9/SCI, not these)"
for d in /sys/bus/pci/devices/*/power/wakeup; do
  [ "$(cat "$d" 2>/dev/null)" = "enabled" ] || continue
  pci=$(basename "$(dirname "$(dirname "$d")")"); pci=${pci#0000:}
  printf '  %-8s %s\n' "$pci" "$(lspci -s "$pci" 2>/dev/null | cut -d: -f3- | sed 's/^ //')"
done

# --- snapshot ACPI GPE/interrupt counters so we can name the actual waker ---
ACPI_IRQ=/sys/firmware/acpi/interrupts
gpe_snapshot(){ # -> "name count" per active line
  for f in "$ACPI_IRQ"/*; do
    n=$(basename "$f"); read -r c _ < "$f" 2>/dev/null
    [ -n "$c" ] && echo "$n $c"
  done
}
GPE_BEFORE=$(gpe_snapshot)

# --- snapshot, suspend, snapshot ---
s0_0=$(cat "$S0IX" 2>/dev/null); b0=$(cat $bat/energy_now 2>/dev/null); t0=$(date +%s)
line "SUSPENDING for ${WAKE}s — machine will sleep and auto-wake; do not touch it"
sync
rtcwake -m mem -s "$WAKE" >/dev/null 2>&1
rc=$?
GPE_AFTER=$(gpe_snapshot)
s0_1=$(cat "$S0IX" 2>/dev/null); b1=$(cat $bat/energy_now 2>/dev/null); t1=$(date +%s)
wall=$((t1 - t0))
wirq=$(cat /sys/power/pm_wakeup_irq 2>/dev/null)
[ "$rc" -ne 0 ] && echo "WARN: rtcwake returned $rc (suspend may have failed)."
if [ -n "$wirq" ]; then
  src=$(grep -E "^\s*${wirq}:" /proc/interrupts 2>/dev/null | sed -E 's/^[^A-Za-z]*//; s/  +/ /g')
  echo "last wakeup IRQ : ${wirq}  -> ${src:-unknown}   (RTC = expected; IRQ 9 / acpi = an ACPI GPE woke it)"
fi
# Which ACPI GPE/event counters moved across the suspend? That names the real waker.
echo "ACPI events that fired during suspend (name: +delta):"
{ echo "$GPE_BEFORE"; echo "$GPE_AFTER"; } | awk '
  seen[$1]++ {d=$2-b[$1]; if(d>0) printf "   %-12s +%s\n", $1, d; next}
  {b[$1]=$2}' | grep -vE '^\s+sci ' | sort -t+ -k2 -rn | head -12
echo "   (gpeXX = a specific GPE; map with: grep -i gpe /sys/firmware/acpi/interrupts/* ; high-count one = the waker.)"

line "RESULT"
echo "wall time asleep+overhead : ${wall}s  (requested ${WAKE}s)"
if [ "$wall" -lt "$((WAKE - 5))" ] 2>/dev/null; then
  echo "   *** EARLY WAKE: a wakeup source pulled the machine out of suspend after ${wall}s, not the RTC."
  echo "       This alone drains the battery overnight (never stays asleep). Disarm the wakeup-armed"
  echo "       devices listed above and re-test. S0ix% below is unreliable on such a short window."
fi
frac=""
if [ -n "$s0_0" ] && [ -n "$s0_1" ] && [ "$wall" -gt 0 ]; then
  ds0=$(( (s0_1 - s0_0) ))
  frac=$(awk "BEGIN{printf \"%.0f\", $ds0/1e6/$wall*100}")
  echo "S0ix residency in window  : $(awk "BEGIN{printf \"%.1f\", $ds0/1e6}")s  =>  ${frac}% of wall"
  if [ "$frac" -ge 90 ] 2>/dev/null;   then echo "   VERDICT: GOOD — reaching deep S0ix."
  elif [ "$frac" -ge 50 ] 2>/dev/null; then echo "   VERDICT: PARTIAL — something is limiting S0ix; check wakeup-armed devices above."
  else                                       echo "   VERDICT: BAD — barely entering S0ix; this is the overnight-drain cause."
  fi
else
  echo "S0ix residency            : NA (counter unreadable)"
fi
sus_w=""
if [ -n "$b0" ] && [ -n "$b1" ] && [ "$b1" -lt "$b0" ] 2>/dev/null && [ "$wall" -gt 0 ]; then
  db=$((b0 - b1))
  sus_w=$(awk "BEGIN{printf \"%.2f\", $db/1e6/($wall/3600)}")
  full=$(awk "BEGIN{printf \"%.0f\", $(cat $bat/energy_full 2>/dev/null)/1e6}")
  days=$(awk "BEGIN{printf \"%.1f\", $full/$sus_w/24}")
  echo "suspend draw              : ${sus_w} W   (=> ~${days} days from full)"
else
  echo "suspend draw              : NA (charger plugged in, or window too short to register) — UNPLUG and re-run"
fi

# --- append to comparison log ---
mkdir -p "$(dirname "$LOG")"
[ -f "$LOG" ] || echo "timestamp,kernel,ac_online,wall_s,s0ix_pct,suspend_w,note" > "$LOG"
ts=$(date '+%Y-%m-%d %H:%M:%S')
echo "${ts},${kernel},${ac:-?},${wall},${frac:-NA},${sus_w:-NA},${NOTE}" >> "$LOG"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$LOG" 2>/dev/null
echo; echo "logged -> docs/suspend-measurements.log"
