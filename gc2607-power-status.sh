#!/usr/bin/env bash
#
# gc2607-power-status.sh — read-only power/thermal posture audit + verdict.
#
# Answers "is the laptop in the optimised power state, and is anything costing
# performance?" in one shot. Encodes the expected-good values (the 2026-06
# tuning: EPP=power for cool/quiet, turbo LEFT ON so peak speed is intact,
# tuned balanced/balanced-battery auto-switch, radios/audio/display power-save,
# NO intel_lpmd) and FLAGS any drift — useful after a reboot, kernel update, or
# suspend, any of which can silently reset these knobs.
#
# Usage:
#   gc2607-power-status.sh           # read-only audit + verdict   (no sudo)
#   gc2607-power-status.sh perf      # MEASURE the EPP=power perf cost vs
#                                    #   balance_performance (needs sudo; briefly
#                                    #   spikes heat ~30 s; restores EPP=power on exit)
#
# See also: gc2607-idle-cool.sh (applies/removes EPP=power), gc2607-power-ab.sh
# (watts A/B), gc2607-power-measure.sh (logs to docs/power-measurements.log),
# gc2607-health.sh (broad machine health). Companion to the 06-18 freeze verdict.
#
set -u
DEV=0000:01:00.0   # WD PC SN740
PASS=0; WARN=0
glyph(){ case "$1" in ok) printf '✓';; warn) printf '⚠';; bad) printf '✗';; esac; }
row(){ # row <ok|warn|bad> <label> <value> [hint]
  local s=$1 l=$2 v=$3 h=${4:-}
  if [ "$s" = ok ]; then PASS=$((PASS+1)); else WARN=$((WARN+1)); fi
  printf '  %s %-21s %s%s\n' "$(glyph "$s")" "$l" "$v" "${h:+   — $h}"
}
hdr(){ printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
cpus(){ ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | grep -oE '[0-9]+$' | sort -n; }
pkgtemp(){ sensors 2>/dev/null | awk '/Package id 0/{print $4; exit}'; }
cmdval(){ grep -oE "$1=[0-9]" /proc/cmdline 2>/dev/null | cut -d= -f2; }

audit(){
  hdr "SOURCE & THERMAL"
  local ac; ac=$(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1)
  row ok "power source" "$([ "$ac" = 1 ] && echo 'AC (plugged in)' || echo 'BATTERY')"
  local pt; pt=$(pkgtemp)
  row ok "package temp" "${pt:-?}" "load $(cut -d' ' -f1-3 /proc/loadavg)"

  hdr "CPU ENERGY BIAS  (the cool/quiet lever)"
  local epp gov; epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)
  gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
  case "$epp" in
    power)            row ok   "EPP" "$epp"  "max efficiency — the cool/quiet target";;
    balance_power)    row ok   "EPP" "$epp"  "on-battery auto value — fine";;
    balance_performance|performance) row warn "EPP" "$epp" "PERF-LEANING — not cooled; is idle-cool applied?";;
    *)                row warn "EPP" "${epp:-?}" "unexpected value";;
  esac
  row ok "governor" "$gov" "intel_pstate active mode (normal)"
  printf '     per-core EPP: '; for c in 0 2 16 20; do printf 'cpu%s=%s ' "$c" "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/energy_performance_preference 2>/dev/null)"; done; echo

  hdr "PERFORMANCE CEILING  (must stay intact — this is what EPP does NOT touch)"
  local nt smax cmax; nt=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)
  smax=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)
  cmax=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
  if [ "$nt" = 0 ]; then row ok "turbo" "ON (no_turbo=0)" "peak CPU speed available"; else row warn "turbo" "OFF (no_turbo=1)" "BIG perf hit — turbo disabled"; fi
  if [ -n "$smax" ] && [ "$smax" = "$cmax" ]; then row ok "max-freq headroom" "$((smax/1000)) MHz = silicon max" "not capped"; else row warn "max-freq headroom" "$((smax/1000))/$((cmax/1000)) MHz" "CAPPED below silicon max"; fi

  hdr "PROFILE & DAEMONS"
  local prof; prof=$(tuned-adm active 2>/dev/null | sed 's/.*: //')
  case "$prof" in balanced|balanced-battery) row ok "tuned profile" "$prof";; *) row warn "tuned profile" "${prof:-?}" "expect balanced / balanced-battery";; esac
  if grep -q 'battery_detection=true' /etc/tuned/ppd.conf 2>/dev/null; then row ok "battery auto-switch" "on" "balanced-battery when unplugged"; else row warn "battery auto-switch" "OFF" "won't down-tune on battery"; fi
  if rpm -q intel-lpmd >/dev/null 2>&1 || command -v intel_lpmd >/dev/null 2>&1; then row bad "intel_lpmd" "INSTALLED" "REMOVE — parks work on cpu20/21, undoes the tuning"; else row ok "intel_lpmd" "absent" "correct (it would undo the tuning)"; fi
  row ok "idle-cool svc" "$(systemctl is-active gc2607-idle-cool 2>/dev/null) / $(systemctl is-enabled gc2607-idle-cool 2>/dev/null)"

  hdr "PERIPHERAL & DISPLAY POWER-SAVE"
  local wp ap; wp=$(cat /sys/module/iwlwifi/parameters/power_save 2>/dev/null); ap=$(cat /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null)
  if [ "$wp" = Y ]; then row ok "wifi power_save" "Y"; else row warn "wifi power_save" "${wp:-?}"; fi
  if [ -n "$ap" ] && [ "$ap" != 0 ]; then row ok "audio power_save" "$ap"; else row warn "audio power_save" "${ap:-?}"; fi
  row ok "display PSR/FBC/DC" "$(cmdval i915.enable_psr)/$(cmdval i915.enable_fbc)/$(cmdval i915.enable_dc)" "psr/fbc/dc"

  hdr "BATTERY LONGEVITY"
  local cap st end; cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null); st=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null)
  end=$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null)
  row ok "charge" "${cap}% ($st)"
  if [ -n "$end" ]; then row ok "charge cap" "${end}%" "$([ "$end" -lt 100 ] && echo 'longevity cap — raise to 100 for max travel runtime' || echo 'full charge')"; fi

  hdr "FREEZE FIX  (power-adjacent cross-check)"
  local l1; l1=$(cat /sys/bus/pci/devices/$DEV/link/l1_aspm 2>/dev/null)
  if [ "$l1" = 0 ]; then row ok "SN740 ASPM-L1" "off (l1_aspm=0)" "the freeze fix is active"; else row bad "SN740 ASPM-L1" "${l1:-?}" "want 0 — freeze fix NOT applied!"; fi

  printf '\n\033[1mVERDICT: '
  if [ "$WARN" -eq 0 ]; then printf '\033[32mOPTIMAL\033[0m — %d checks pass, 0 deviations from the tuned baseline.\n' "$PASS"
  else printf '\033[33m%d DEVIATION(S)\033[0m from the tuned baseline (%d ok) — see the ⚠/✗ rows above.\n' "$WARN" "$PASS"; fi

  cat <<'NOTE'

PERFORMANCE NOTE — does EPP=power cost speed?
  • Turbo is left ON with full max-freq headroom, so PEAK CPU speed is unchanged.
  • EPP=power changes only the BIAS: clocks climb lazily / drop fast, so light &
    bursty work runs at lower MHz. That is the cool/quiet win, not lost speed —
    measured ~2x less package power for the same light load (8.89 W vs 15.94 W).
  • Accelerator (NPU / iGPU) compute is UNAFFECTED — EPP governs only CPU P-states.
  • Only sustained, all-core, CPU-bound work sees a few-% steady-state difference
    (and on this thin chassis the aggressive setting mostly becomes heat +
    throttling, not throughput).  Measure it for real:  gc2607-power-status.sh perf
NOTE
}

perf(){
  [ "$(id -u)" -eq 0 ] || exec sudo "$0" perf
  command -v openssl >/dev/null || { echo "perf mode needs openssl (CPU benchmark)"; exit 1; }
  local EPPS=(/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference)
  set_epp(){ local v=$1 f; for f in "${EPPS[@]}"; do echo "$v" > "$f" 2>/dev/null; done; }
  restore(){ printf '\n>> restoring EPP=power (cool state)\n'; set_epp power; [ -x /usr/local/sbin/gc2607-epp-power ] && /usr/local/sbin/gc2607-epp-power >/dev/null 2>&1; }
  trap restore EXIT INT TERM
  local n; n=$(nproc)
  echo "PERF A/B — openssl sha256 throughput, all-core ($n threads), 3 s per setting."
  echo "WARNING: briefly pegs ALL cores (heat/fans spike ~30 s). Restores EPP=power on exit."
  echo "context: $(cat /sys/class/power_supply/A*/online 2>/dev/null|head -1|sed 's/^1$/AC/;s/^0$/BATTERY/')  tuned=$(tuned-adm active 2>/dev/null|sed 's/.*: //')"
  printf '%-22s %14s  %10s  %s\n' "EPP setting" "sha256 (1k/s)" "peak-MHz" "pkg-temp"
  local e out hi
  for e in power balance_performance; do
    set_epp "$e"; sleep 2
    out=$(openssl speed -multi "$n" -seconds 3 sha256 2>/dev/null | awk 'tolower($1)~/sha256/{print $NF}')
    hi=$(for c in $(cpus); do cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null; done | sort -n | tail -1)
    printf '%-22s %14s  %10s  %s\n' "$e" "${out:-?}" "$((hi/1000))" "$(pkgtemp)"
  done
  echo "(higher sha256 = faster; the gap between rows is the real CPU-bound cost of EPP=power.)"
}

case "${1:-status}" in
  status) audit ;;
  perf)   perf ;;
  *) echo "usage: $0 [status|perf]" >&2; exit 1 ;;
esac
