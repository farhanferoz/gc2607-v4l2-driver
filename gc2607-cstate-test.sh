#!/usr/bin/env bash
#
# gc2607-cstate-test.sh - Phase-1 selective C-state controller for the
# silent-freeze diagnosis (docs/incidents/2026-05-silent-freezes.md).
#
# THE EXPERIMENT: park the i915 GPU interrupt on a performance core that is
# kept OUT of C6, and allow C6 on every OTHER core. This discriminates:
#   * GPU-interrupt-in-C6 (software) hypothesis  -> predicts STABLE
#   * any-core-C6-corrupts (hardware / MTL066)    -> predicts WEDGE
#
# Boot mode is auto-detected, with the kernel command line as the bullet-proof
# fail-safe (cap present ALWAYS wins -> PROTECT). Among the test modes, the
# marker file /etc/gc2607-cstate-mode selects which experiment runs:
#   intel_idle.max_cstate=1 PRESENT   -> PROTECT (C6 absent; reassert global off)
#   ABSENT + mode-file 'test1b'       -> TEST1B  (C6 off on LP-E cores 20/21 only)
#   ABSENT + 'test1'/absent (default) -> TEST1   (C6 off only on the GPU-IRQ core)
#
# Fail-safe ordering: global C6-off is applied FIRST; C6 is re-enabled on the
# other cores ONLY AFTER the GPU IRQ is found + pinned. Any failure (IRQ not
# found, etc.) leaves the machine global-C6-off = protected.
#
# Usage (root; self-sudo if not):
#   gc2607-cstate-test.sh apply        # what the boot service runs (auto-mode)
#   gc2607-cstate-test.sh test1        # apply the Phase-1 config live (cpu2 awake)
#   gc2607-cstate-test.sh test1b       # apply the Phase-1b config live (LP-E 20/21 off)
#   gc2607-cstate-test.sh protect-now  # live global C6-off (emergency revert)
#   gc2607-cstate-test.sh status
#
set -u
IRQ_CORE="${IRQ_CORE:-2}"          # P-core (5.1GHz) that hosts the GPU IRQ, kept awake
LPE_CORES="${LPE_CORES:-20 21}"    # Phase 1b: low-power-island cores (cap 2.5GHz) kept out of C6
MODE_FILE="${MODE_FILE:-/etc/gc2607-cstate-mode}"  # test1 | test1b (cmdline cap always wins)
TAG=gc2607-cstate-test

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"

cpus() { ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | grep -oE '[0-9]+$' | sort -n; }

discover_gpu_irq() {
  awk -F: '/i915/ && $1 ~ /[0-9]/ {gsub(/ /,"",$1); print $1; exit}' /proc/interrupts
}

# set C6/C8/C10 disable=$2 on cpu $1, matched by state NAME (index-robust)
set_deep() {
  local c=$1 v=$2 d nm
  for d in /sys/devices/system/cpu/cpu$c/cpuidle/state*/; do
    nm=$(cat "$d/name" 2>/dev/null)
    case "$nm" in C6|C6S|C8|C10|C10S) [ -w "$d/disable" ] && echo "$v" > "$d/disable" ;; esac
  done
}

global_off() { local c; for c in $(cpus); do set_deep "$c" 1; done; }

apply_test1() {
  global_off                                    # safe baseline FIRST
  local irq="" i
  for i in $(seq 1 20); do irq=$(discover_gpu_irq); [ -n "$irq" ] && break; sleep 0.5; done
  if [ -z "$irq" ]; then
    logger -t "$TAG" "ERROR: i915 IRQ not found after 10s; STAYING global C6-off (safe)"
    return 0
  fi
  echo "$IRQ_CORE" > /proc/irq/$irq/smp_affinity_list 2>/dev/null
  local c
  for c in $(cpus); do [ "$c" = "$IRQ_CORE" ] && continue; set_deep "$c" 0; done
  logger -t "$TAG" "TEST1 applied: i915 IRQ=$irq pinned cpu${IRQ_CORE} (got cpu$(cat /proc/irq/$irq/effective_affinity_list 2>/dev/null)); C6 OFF on cpu${IRQ_CORE}; C6 ON on all other cores"
}

# Phase 1b: keep ONLY the low-power-island cores (cpu20/21) out of C6; C6 stays
# ON for the other 20. GPU IRQ still pinned to a P-core so it can't ride a
# sleeping LP-E core. Discriminates "LP-E C6 is fatal" (-> stable, cheap fix)
# from "any core's C6 is fatal / hardware" (-> wedge).
apply_test1b() {
  global_off                                    # safe baseline FIRST
  local irq="" i
  for i in $(seq 1 20); do irq=$(discover_gpu_irq); [ -n "$irq" ] && break; sleep 0.5; done
  if [ -n "$irq" ]; then
    echo "$IRQ_CORE" > /proc/irq/$irq/smp_affinity_list 2>/dev/null
  else
    logger -t "$TAG" "WARN: i915 IRQ not found; proceeding with LP-E-only cap (LP-E stays out of C6 = safe)"
  fi
  local c k keep
  for c in $(cpus); do
    keep=0
    for k in $LPE_CORES; do [ "$c" = "$k" ] && keep=1; done
    [ "$keep" = 1 ] && continue                 # LP-E cores stay capped (C6 off)
    set_deep "$c" 0                             # all other cores: C6 back ON
  done
  logger -t "$TAG" "TEST1b applied: i915 IRQ=${irq:-?} pinned cpu${IRQ_CORE} (got cpu$(cat /proc/irq/${irq:-0}/effective_affinity_list 2>/dev/null)); C6 OFF on LP-E cores [${LPE_CORES}]; C6 ON on all other cores"
}

apply_auto() {
  if grep -q 'intel_idle.max_cstate=1' /proc/cmdline; then
    global_off
    logger -t "$TAG" "boot mode=PROTECT (cmdline cap present); reasserted global C6-off"
    return
  fi
  local mode=test1
  [ -r "$MODE_FILE" ] && mode=$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null)
  case "$mode" in
    test1b)
      logger -t "$TAG" "boot mode=TEST1B (cmdline cap absent, $MODE_FILE=test1b)"
      apply_test1b ;;
    *)
      logger -t "$TAG" "boot mode=TEST1 (cmdline cap absent, ${MODE_FILE}=${mode:-unset/default})"
      apply_test1 ;;
  esac
}

status() {
  echo "cmdline cap : $(grep -q intel_idle.max_cstate=1 /proc/cmdline && echo 'PRESENT -> protect mode' || echo 'ABSENT -> test mode')"
  echo "phase mode  : $( [ -r "$MODE_FILE" ] && tr -d '[:space:]' < "$MODE_FILE" || echo 'test1 (default; no marker)')   (LP-E cores: ${LPE_CORES})"
  local irq; irq=$(discover_gpu_irq)
  echo "i915 IRQ    : ${irq:-?} @ cpu$(cat /proc/irq/${irq:-0}/effective_affinity_list 2>/dev/null || echo '?')"
  echo "irqbalance  : $(systemctl is-active irqbalance 2>/dev/null) / $(systemctl is-enabled irqbalance 2>/dev/null)"
  echo "per-core deep-C-state disable (1=off, blank row = C6 absent):"
  local c d nm st
  for c in $(cpus); do
    st=""
    for d in /sys/devices/system/cpu/cpu$c/cpuidle/state*/; do
      nm=$(cat "$d/name" 2>/dev/null)
      case "$nm" in C6) st="$st C6=$(cat "$d/disable" 2>/dev/null)";; C10) st="$st C10=$(cat "$d/disable" 2>/dev/null)";; esac
    done
    [ -n "$st" ] && printf "  cpu%-2s%s\n" "$c" "$st"
  done
}

case "${1:-status}" in
  apply)        apply_auto ;;
  test1)        apply_test1; echo; status ;;
  test1b)       apply_test1b; echo; status ;;
  protect-now)  global_off; logger -t "$TAG" "protect-now: live global C6-off"; echo "global C6-off applied"; echo; status ;;
  status)       status ;;
  *) echo "usage: $0 [apply|test1|test1b|protect-now|status]" >&2; exit 1 ;;
esac
