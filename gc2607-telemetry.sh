#!/usr/bin/env bash
#
# gc2607-telemetry.sh - silent-freeze MECHANISM telemetry.
#
# Emits one compact line every INTERVAL via logger (tag: gc2607-telem) so it
# rides the EXISTING journal->NAS stream (journal-capture-nas.service) off-box.
# Because it ships off-box continuously, the last line on the NAS brackets a
# silent wedge to within ~INTERVAL seconds - the forensic trace the 16 crashes
# never left locally (pstore empty, nmi_watchdog never fired).
#
# It captures the TWO signals that discriminate the competing hypotheses:
#   c6cores=[...]  which CPUs entered C6 or deeper since the last sample
#   irq200=cpuN    where the i915 GPU interrupt is pinned  (d=rate since last)
# If a wedge's last sample shows other cores entering C6 while the GPU-IRQ core
# stayed awake -> the "any core's C6 is fatal" (hardware) signature.
# If wedges only ever coincide with the GPU-IRQ core itself entering C6 -> the
# GPU-interrupt (software) signature.
# Plus package temp / freq span / loadavg for context.
#
# Read-only; no root needed. Runs as the gc2607-telemetry.service user unit.
#
INTERVAL="${1:-2}"
TAG=gc2607-telem
# discover the i915 GPU interrupt by NAME (its MSI number changes across boots)
GPU_IRQ="${GPU_IRQ:-$(awk -F: '/i915/ && $1 ~ /[0-9]/ {gsub(/ /,"",$1); print $1; exit}' /proc/interrupts)}"
GPU_IRQ="${GPU_IRQ:-200}"

cpus=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null \
        | grep -oE 'cpu[0-9]+$' | sed 's/cpu//' | sort -n)

declare -A prev_c6
prev_irq=0

# state dirs on $1 whose name is C6 or deeper (C8/C10)
deep_states_for() {
  local c=$1 d nm
  for d in /sys/devices/system/cpu/cpu$c/cpuidle/state*/; do
    nm=$(cat "$d/name" 2>/dev/null)
    case "$nm" in C6|C6S|C8|C10|C10S) echo "$d";; esac
  done
}
# total usage across $1's C6+ states (0 if those states don't exist, e.g. capped)
sum_deep_usage() {
  local c=$1 d s=0 u
  for d in $(deep_states_for "$c"); do
    u=$(cat "$d/usage" 2>/dev/null); [ -n "$u" ] && s=$((s+u))
  done
  echo "$s"
}
# total fire count of the GPU IRQ across all CPUs
irq_total() {
  awk -v irq="${GPU_IRQ}:" '$1==irq{t=0;for(i=2;i<=NF;i++)if($i~/^[0-9]+$/)t+=$i;print t;exit}' \
      /proc/interrupts 2>/dev/null
}
pkg_temp_c() {
  local f lbl
  for f in /sys/class/hwmon/hwmon*/temp1_input; do
    lbl=$(cat "${f%input}label" 2>/dev/null)
    [ "$lbl" = "Package id 0" ] && { echo $(( $(cat "$f" 2>/dev/null)/1000 )); return; }
  done
}

logger -t "$TAG" "started interval=${INTERVAL}s gpu_irq=${GPU_IRQ} ncpu=$(echo $cpus | wc -w) c6states=$(deep_states_for 0 | wc -l)"

for c in $cpus; do prev_c6[$c]=$(sum_deep_usage "$c"); done
prev_irq=$(irq_total); [ -n "$prev_irq" ] || prev_irq=0

while :; do
  sleep "$INTERVAL"

  c6list=""
  for c in $cpus; do
    cur=$(sum_deep_usage "$c"); [ -n "$cur" ] || cur=0
    [ "$cur" -gt "${prev_c6[$c]:-0}" ] && c6list="${c6list}${c6list:+,}$c"
    prev_c6[$c]=$cur
  done

  irqcpu=$(cat /proc/irq/${GPU_IRQ}/effective_affinity_list 2>/dev/null)
  curirq=$(irq_total); [ -n "$curirq" ] || curirq=$prev_irq
  dirq=$((curirq - prev_irq)); prev_irq=$curirq

  fmin=99999999; fmax=0
  for c in $cpus; do
    f=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null) || continue
    [ -n "$f" ] || continue
    [ "$f" -lt "$fmin" ] && fmin=$f
    [ "$f" -gt "$fmax" ] && fmax=$f
  done
  [ "$fmax" -eq 0 ] && { fmin=0; }

  logger -t "$TAG" "irq${GPU_IRQ}=cpu${irqcpu:-?} d=${dirq} c6cores=[${c6list}] pkg=$(pkg_temp_c)C f=$((fmin/1000))-$((fmax/1000))MHz load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)"
done
