#!/usr/bin/env bash
#
# gc2607-suspend-pmc-probe.sh [--win SECONDS]
#   READ-ONLY Meteor Lake S0ix blocker report (+ one short suspend). NO toggles, nothing to restore.
#   Implements the DOCUMENTED MTL diagnostic flow (Intel 01.org S0ix troubleshooting + blog.fsck.com
#   Meteor Lake power writeup + feeditout ThinkPad P1 Gen 7). Answers: WHY does s2idle never reach S0ix?
#
# WHY  (2026-06-25, after three measured eliminations)
#   On battery, S0ix = exactly 0% in EVERY config: NVMe ASPM on/off, PCIe wakeup armed/disarmed, AND with
#   the EC GPE 0x6E storm masked (221->1 events, S0ix still 0, draw unchanged ~2.1->2.5 W). So the blocker
#   is an S0ix-ENTRY PREREQUISITE at the PMC layer, not a wakeup source. Sourced facts that frame this:
#     - slp_s0_residency_usec = 0 genuinely means NOT reaching S0ix (Intel 01.org). First checkpoint when
#       PC10 is reached but S0ix=0: read pch_ip_power_gating_status.
#     - On Meteor Lake the Management Engine (ME) + GBE LTR values block S0ix on virtually every MTL system
#       unless ignored; fix = echo <index> > pmc_core/ltr_ignore (took one machine 0% -> 93% S0i2.2,
#       ~2-3 W -> near-zero). Indices are PER-MACHINE — read them from ltr_show's leftmost column.
#     - CAVEAT: on the ThinkPad P1 Gen 7 (also MTL) even ltr_ignore did NOT fully fix it — the IOE die
#       (PMC1) failing to power-gate is a CSME FIRMWARE issue, boot-dependent, not software-fixable. So this
#       probe must tell us which layer we're in: fixable LTR vs firmware (PMC1/IOE) vs broken counter.
#
# WHAT IT READS (all /sys/kernel/debug/pmc_core — root-only, harmless reads):
#   substate_requirements  -> the UNMET requirements (`grep Required | grep -v Yes`) = the actual blockers
#   ltr_show               -> per-IP LTR; NON-ZERO decoded entries = active requirements = ltr_ignore candidates
#   pch_ip_power_gating_status -> documented first checkpoint when S0ix=0 but PC10 ok
#   substate_residencies / package_cstate_show / pll_status / lpm_* / substate_status_registers
#   turbostat (10 s awake) -> Pkg pc2/pc8/pc10 + SYS%LPI: can the package deep-idle at all while awake?
#   Then snapshot residencies -> ONE ${WIN}s suspend -> re-snapshot -> show which counters moved.
#
# USAGE (root; battery preferred for the suspend draw, but the blocker tables are valid on AC too)
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-suspend-pmc-probe.sh
#     sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-suspend-pmc-probe.sh --win 120
#
set +e
WIN=60
SUSPEND=1
while [ $# -gt 0 ]; do
  case "$1" in
    --win) shift; WIN="$1" ;;
    --no-suspend) SUSPEND=0 ;;   # read the blocker tables ONLY; never sleeps the machine
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done
[ "$(id -u)" -eq 0 ] || { echo "Needs root (debugfs + rtcwake). Re-run: sudo bash $0 $*"; exit 1; }

PMC=/sys/kernel/debug/pmc_core
line(){ printf '\n========== %s ==========\n' "$1"; }
[ -d "$PMC" ] || echo "WARN: no $PMC — intel_pmc_core not loaded? (lsmod | grep pmc)"

ac=$(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1)
echo "kernel $(uname -r)   AC online=$ac   battery $(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)%"
ls "$PMC" 2>/dev/null | tr '\n' ' '; echo

# --- 1) THE BLOCKER: unmet substate requirements (the most direct answer) ---
line "UNMET SUBSTATE REQUIREMENTS  (these IPs are what's blocking S0ix; PMC1/IOE_die => CSME firmware, not SW-fixable)"
if [ -r "$PMC/substate_requirements" ]; then
  hdr=$(head -1 "$PMC/substate_requirements")
  echo "  $hdr"
  # documented filter: requirements that are Required but NOT met
  grep -iE 'required' "$PMC/substate_requirements" | grep -viE '\bYes\b' | sed 's/^/  /' \
    || echo "  (no 'Required & not-Yes' lines matched — printing full file below)"
  echo "  -- full substate_requirements --"
  cat "$PMC/substate_requirements" | sed 's/^/  /'
else
  echo "  (substate_requirements not present on this kernel)"
fi

# --- 2) LTR table: non-zero decoded = active requirement = ltr_ignore candidate (index in leftmost col) ---
line "LTR_SHOW  (NON-ZERO decoded LTR = active requirement; note its INDEX — that's what you'd pass to ltr_ignore)"
[ -r "$PMC/ltr_show" ] && cat "$PMC/ltr_show" | sed 's/^/  /' || echo "  (ltr_show not present)"

# --- 3) documented first checkpoint + other state ---
line "PCH IP POWER GATING STATUS  (Intel 01.org: read this first when S0ix=0)"
[ -r "$PMC/pch_ip_power_gating_status" ] && cat "$PMC/pch_ip_power_gating_status" | sed 's/^/  /' \
  || echo "  (pch_ip_power_gating_status not present)"

line "PACKAGE C-STATES / PLL / LPM"
for f in package_cstate_show pll_status lpm_status lpm_latch_mode lpm_sts substate_status_registers; do
  [ -r "$PMC/$f" ] && { printf -- '-- %s:\n' "$f"; cat "$PMC/$f" | sed 's/^/   /'; echo; }
done

line "TURBOSTAT (10 s, idle & AWAKE — does the PACKAGE deep-idle / reach SYS%LPI at all?)"
if command -v turbostat >/dev/null 2>&1; then
  turbostat --quiet --show Busy%,Bzy_MHz,Pkg%pc2,Pkg%pc6,Pkg%pc8,Pkg%pc10,SYS%LPI,CPU%LPI,PkgWatt \
    -- sleep 10 2>&1 | grep -vE '^\s*$' | tail -6
else
  echo "  (turbostat missing — sudo dnf install -y kernel-tools, then re-run)"
fi

# --- 4) residency delta across one real suspend: does ANY substate accumulate? ---
snap(){
  printf 'slp_s0 %s\n' "$(cat "$PMC/slp_s0_residency_usec" 2>/dev/null)"
  [ -r "$PMC/substate_residencies" ] && awk 'NR>1 && NF>=2 {print $1, $NF}' "$PMC/substate_residencies"
}
if [ "$SUSPEND" = 1 ]; then
  line "SUSPENDING ${WIN}s — snapshot residencies, sleep, auto-wake, re-snapshot"
  B=$(snap); sync; rtcwake -m mem -s "$WIN" >/dev/null 2>&1; rc=$?; A=$(snap)
  [ "$rc" -ne 0 ] && echo "WARN: rtcwake rc=$rc"
  echo "last wakeup IRQ: $(cat /sys/power/pm_wakeup_irq 2>/dev/null)"
  echo "residency counters that MOVED across the suspend (name: +delta usec):"
  { echo "$B"; echo "$A"; } | awk '
    seen[$1]++ {d=$2-b[$1]; if(d>0) printf "   %-16s +%s\n", $1, d; next}
    {b[$1]=$2}' | sort -t+ -k2 -rn
else
  line "SUSPEND SKIPPED (--no-suspend) — blocker tables above are the decisive data; suspend only confirms branch C"
fi
echo "   (slp_s0 +~${WIN}000000 => reaching legacy S0ix; a SUBSTATE moves but slp_s0 flat => counter is the"
echo "    wrong lens on MTL & ~2 W is the floor; NOTHING moves => genuinely blocked, see unmet reqs above.)"

line "DECISION TREE (no guessing — read the data above)"
echo "  A) Unmet requirements are LTR-fixable IPs (GBE/ME/SOUTHPORT) + they show NON-ZERO LTR in ltr_show"
echo "     => TEST: as root, echo each offending INDEX > $PMC/ltr_ignore, then re-run gc2607-suspend-check.sh."
echo "        Reversible: ltr_ignore clears on REBOOT (no per-index un-ignore). Independent of the freeze fix."
echo "  B) Unmet requirements name PMC1 / IOE_die power-gating => CSME FIRMWARE blocker (ThinkPad P1 G7 case):"
echo "     not software-fixable; ~2 W is likely the floor. Check BIOS for a 'Linux'/'Modern Standby' toggle."
echo "  C) A substate accumulated but slp_s0 stayed 0 => suspend is actually FINE; 0% was a bad MTL counter."
echo "  Paste this whole output back and we pick the branch from the numbers, not a guess."
