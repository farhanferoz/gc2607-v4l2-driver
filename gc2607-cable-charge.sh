#!/usr/bin/env bash
#
# gc2607-cable-charge.sh {status|measure LABEL [SECONDS]|watch [SECONDS]|report|guide|restore}
#   USB-C cable & coupler tester. Two jobs:
#     - measure: how much charging power a cable/charger delivers (tell a healthy cable from a weak one).
#     - watch:   whether a link is STABLE or drops the PD contract (e.g. a female-to-female coupler chain
#                that charges but cycles on/off every few seconds).
#   `guide` prints the full A/B + coupler/orientation test protocol so it never has to be re-derived.
#
#   The MateBook EC negotiates USB-PD invisibly — there is NO /sys/class/typec
#   port and AC0 reports only online=1 (no input V/A), so the negotiated PD profile is unreadable. The one
#   real signal the kernel exposes is BAT0/power_now (charge power INTO the battery) + voltage_now.
#
# HOW IT WORKS / CAVEATS:
#   - power_now is charge power into the battery = (cable delivery) - (system load). We can't read system
#     load, so this is a LOWER BOUND on what the cable delivers. For a fair A/B: same battery % band, same
#     idle load. A weak cable shows up as much lower peak charge W — or the battery DISCHARGING while plugged.
#   - The battery is capped at charge_control_end_threshold (here 80%). At the cap, power_now=0 for ANY cable.
#     So `measure` TEMPORARILY raises the end threshold to 100 to force active charging, then RESTORES it
#     (trap-protected, runs even on Ctrl-C/error). Net cost: battery charges ~1-2% during a 30 s run.
#   - Charge power tapers as the battery fills, so compare cables at a SIMILAR capacity (e.g. both ~80-82%).
#
# USAGE (the cable A/B comparison):
#   sudo -n /abs/gc2607-cable-charge.sh measure cable-A-known-good     # on the working cable
#   ... physically swap to the other cable ...
#   sudo -n /abs/gc2607-cable-charge.sh measure cable-B-suspect        # on the suspect cable
#   bash /abs/gc2607-cable-charge.sh report                           # diffs the last two runs
#
# Results are appended to docs/cable-charge-measurements.log (comparable rows, per ops convention).
#
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SELF_DIR/docs/cable-charge-measurements.log"
BAT=/sys/class/power_supply/BAT0
AC=/sys/class/power_supply/AC0
END_THR="$BAT/charge_control_end_threshold"

CMD="${1:-status}"
need_root(){ [ "$(id -u)" -eq 0 ] || { echo "Needs root: sudo -n $SELF_DIR/$(basename "$0") $*"; exit 1; }; }
rd(){ cat "$1" 2>/dev/null; }
uW(){ awk -v v="$(rd "$1")" 'BEGIN{printf "%.2f", (v+0)/1e6}'; }   # µW/µV -> W/V

snapshot(){
  local ac status cap pw vn end
  ac=$(rd "$AC/online"); status=$(rd "$BAT/status"); cap=$(rd "$BAT/capacity")
  pw=$(uW "$BAT/power_now"); vn=$(uW "$BAT/voltage_now"); end=$(rd "$END_THR")
  printf '  AC online   : %s\n' "${ac:-?}"
  printf '  BAT status  : %s   capacity %s%%   charge cap %s%%\n' "${status:-?}" "${cap:-?}" "${end:-?}"
  printf '  charge power: %s W   @ %s V\n' "$pw" "$vn"
}

case "$CMD" in
  status)
    echo "===== gc2607 cable-charge status (read-only) ====="
    snapshot
    s=$(rd "$BAT/status")
    if [ "$(rd "$AC/online")" != 1 ]; then echo "  >> Not plugged in — plug the cable to measure."
    elif [ "$s" = "Charging" ]; then echo "  >> Charging now; \`measure LABEL\` will sample delivered watts."
    else echo "  >> Plugged but '$s' (likely at the $(rd "$END_THR")% cap) — \`measure\` forces charging to read watts."; fi
    ;;

  measure)
    need_root "$@"
    LABEL="${2:-cable}"; SECS="${3:-30}"
    [ "$(rd "$AC/online")" = 1 ] || { echo "Not plugged in (AC0 online=0). Plug the cable first."; exit 1; }
    SAVED_END="$(rd "$END_THR")"
    restore_thr(){ [ -n "${SAVED_END:-}" ] && { echo "$SAVED_END" > "$END_THR" 2>/dev/null; echo "  restored charge cap -> ${SAVED_END}%"; }; }
    trap restore_thr EXIT
    echo "===== measuring '$LABEL' for ${SECS}s ====="
    echo "  forcing charge (raising end threshold ${SAVED_END}% -> 100%)..."
    echo 100 > "$END_THR" 2>/dev/null || { echo "  !! could not write $END_THR"; exit 1; }
    sleep 2   # let the EC react and charging ramp
    peak=0; sum=0; n=0; vsum=0; charged=0; cap0=$(rd "$BAT/capacity")
    for ((i=0; i<SECS; i++)); do
      pw=$(uW "$BAT/power_now"); vn=$(uW "$BAT/voltage_now"); st=$(rd "$BAT/status")
      [ "$st" = "Charging" ] && charged=$((charged+1))
      read peak sum <<<"$(awk -v p="$pw" -v pk="$peak" -v s="$sum" 'BEGIN{printf "%.2f %.4f", (p>pk?p:pk), s+p}')"
      vsum=$(awk -v v="$vn" -v s="$vsum" 'BEGIN{printf "%.4f", s+v}'); n=$((n+1))
      printf '\r  t=%2ds  now=%5s W  status=%-12s' "$i" "$pw" "$st"
      sleep 1
    done
    cap1=$(rd "$BAT/capacity")
    avg=$(awk -v s="$sum" -v n="$n" 'BEGIN{printf "%.2f", (n? s/n:0)}')
    vavg=$(awk -v s="$vsum" -v n="$n" 'BEGIN{printf "%.2f", (n? s/n:0)}')
    note="ok"; [ "$charged" -eq 0 ] && note="NEVER-CHARGED(weak/full?)"
    echo; echo "  ---"
    printf '  peak %s W   avg %s W   @ %s V   charging %d/%d s   cap %s%%->%s%%   [%s]\n' \
      "$peak" "$avg" "$vavg" "$charged" "$n" "$cap0" "$cap1" "$note"
    mkdir -p "$(dirname "$LOG")"
    [ -f "$LOG" ] || printf '# date\tlabel\tpeak_W\tavg_W\tavg_V\tcharging_s/total\tcap%%\tnote\n' > "$LOG"
    printf '%s\t%s\t%s\t%s\t%s\t%d/%d\t%s->%s\t%s\n' \
      "$(date '+%Y-%m-%d %H:%M')" "$LABEL" "$peak" "$avg" "$vavg" "$charged" "$n" "$cap0" "$cap1" "$note" >> "$LOG"
    [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$LOG" 2>/dev/null   # keep the log user-owned, not root
    echo "  logged -> $LOG"
    ;;

  report)
    [ -f "$LOG" ] || { echo "No measurements yet ($LOG). Run: measure LABEL"; exit 0; }
    echo "===== $LOG ====="; column -t -s$'\t' "$LOG"
    # diff the last two data rows
    mapfile -t rows < <(grep -v '^#' "$LOG")
    if [ "${#rows[@]}" -ge 2 ]; then
      a="${rows[-2]}"; b="${rows[-1]}"
      la=$(cut -f2 <<<"$a"); pa=$(cut -f3 <<<"$a"); lb=$(cut -f2 <<<"$b"); pb=$(cut -f3 <<<"$b")
      echo; echo "--- last two: '$la' vs '$lb' (peak charge W) ---"
      awk -v la="$la" -v pa="$pa" -v lb="$lb" -v pb="$pb" 'BEGIN{
        d=pb-pa; pct=(pa>0? d/pa*100:0);
        printf "  %-22s %6.2f W\n  %-22s %6.2f W\n  delta %+.2f W (%+.0f%%)  =>  %s\n",
          la, pa, lb, pb, d, pct,
          (pa>0 && pb < pa*0.8 ? "\""lb"\" is WEAKER (>20% less) — likely underpowered" :
           pb>pa*1.2 ? "\""lb"\" is STRONGER" : "comparable")
      }'
    fi
    ;;

  watch)
    SECS="${2:-40}"
    echo "===== link stability watch (${SECS}s @0.5s, read-only) ====="
    echo "  detects PD dropouts: charging that flickers on/off (chained cables / a F-F coupler)."
    [ "$(rd "$AC/online")" = 1 ] || echo "  (note: AC0 online=0 right now — measuring a detached/half-seated link)"
    ac_flips=0; st_flips=0; prev_ac=""; prev_st=""; on=0; n=0; samples=$((SECS*2))
    for ((i=0; i<samples; i++)); do
      a=$(rd "$AC/online"); s=$(rd "$BAT/status"); p=$(uW "$BAT/power_now")
      [ -n "$prev_ac" ] && [ "$a" != "$prev_ac" ] && ac_flips=$((ac_flips+1))
      [ -n "$prev_st" ] && [ "$s" != "$prev_st" ] && st_flips=$((st_flips+1))
      [ "$a" = 1 ] && on=$((on+1)); n=$((n+1)); prev_ac="$a"; prev_st="$s"
      printf '\r  t=%5.1fs  AC=%s  %-12s %5sW   [AC-drops=%d status-flips=%d]' \
        "$(awk -v i="$i" 'BEGIN{print i*0.5}')" "$a" "$s" "$p" "$ac_flips" "$st_flips"
      sleep 0.5
    done
    echo; echo "  --- $n samples ---"
    printf '  AC online %d/%d   AC transitions %d   status transitions %d\n' "$on" "$n" "$ac_flips" "$st_flips"
    if [ "$ac_flips" -gt 0 ]; then
      echo "  >> UNSTABLE: the input itself drops out ($ac_flips transitions) — marginal/non-compliant PD link"
      echo "     (typical of chained cables / a female-to-female coupler). Not reliable for charging."
    elif [ "$st_flips" -gt 2 ]; then
      echo "  >> WOBBLY: AC stays attached but charge current modulates — borderline contract, input not dropping."
    else
      echo "  >> STABLE: no input drops over this window."
    fi
    ;;

  guide)
    cat <<'G'
===== USB-C cable / coupler test protocol (so we don't reinvent it) =====
Goal: tell a healthy cable from a weak one, and judge a coupler / chained link.

1) Single-cable A/B — is one cable underpowered?
     sudo -n THIS measure cable-A 30      # on cable A
     (swap to cable B, same port)
     sudo -n THIS measure cable-B 30      # on cable B
     THIS report                          # diffs the last two; >20% lower peak = weaker
   CAVEAT: at the 80% charge cap the controller limits to ~12 W, so this only flags a cable that
   can't sustain ~12 W. To separate higher-wattage cables, repeat below 60% battery (pulls 40-65 W).

2) Coupler / chained link — two cables joined by a female-to-female coupler
   a. Plug it. If `THIS status` shows AC online=0 / Discharging, the ORIENTATION is wrong:
      USB-C couplers work in only ~half of plug orientations. Unplug ONE plug, rotate it 180,
      replug, re-check `status`. Try the orientations before concluding "dead" — it is NOT a
      defective coupler, it's the CC/Vconn topology of chaining (non-compliant by USB spec).
   b. Once it charges, check STABILITY (chained links often drop the contract):
      THIS watch 40                       # flags input drops: AC online 1->0->1 cycling
   A single good cable holds steady ~11.9 W; a chain that cycles every ~15 s is marginal PD —
   fine for data extension, unreliable for charging. Use a single cable to actually charge.

Results are logged to: docs/cable-charge-measurements.log   (THIS report to view/diff)
G
    ;;

  restore)
    need_root "$@"; echo 80 > "$END_THR" 2>/dev/null && echo "charge cap reset to 80%."
    ;;

  *) echo "usage: $0 {status|measure LABEL [SECONDS]|watch [SECONDS]|report|guide|restore}"; exit 2 ;;
esac
