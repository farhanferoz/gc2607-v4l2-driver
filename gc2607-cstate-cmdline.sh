#!/usr/bin/env bash
# gc2607-cstate-cmdline.sh — manage the intel_idle.max_cstate=1 KERNEL CMDLINE cap.
#
# WHY THIS EXISTS
#   The silent-freeze investigation once trialled C6-off (`intel_idle.max_cstate=1`)
#   as a *candidate* freeze mitigation. That theory was RETIRED: the real fix is the
#   WD SN740 NVMe ASPM-L1 disable (gc2607-nvme-aspm, l1_aspm=0), proven ~2 weeks clean
#   on 7.0.12 WITH deep sleep (C6/C10) ENABLED (boots -8/-7/-6/-4, 2026-06-15..07-01).
#
#   BUT the `intel_idle.max_cstate=1` arg was never removed from the PERSISTENT cmdline
#   (/etc/kernel/cmdline + /etc/default/grub), so every newly-installed kernel (7.0.13,
#   7.0.14) re-inherited it via its BLS entry. The existing gc2607-cstate-*.sh tools only
#   toggle per-core SYSFS state — they CANNOT undo a cmdline cap (with the cap present the
#   deep C-states are never even registered: only POLL + C1E exist).
#
#   MEASURED COST of the leftover cap: s2idle draw ~10 W (CPU pinned at C1E, package never
#   power-gates) vs ~2.2 W on 7.0.12 without the cap (docs/suspend-measurements.log).
#   Removing it restores the ~2.2 W firmware floor => ~4.5x better suspend battery life.
#
#   Removing the cap is FREEZE-SAFE: the ASPM fix stays active and is the real protection;
#   C6-on + ASPM-off has multi-day clean proof. It is a forward-compatible CMDLINE cleanup,
#   NOT a kernel rollback.
#
# USAGE
#   sudo bash gc2607-cstate-cmdline.sh status    # report cap state in all sources + live C-states
#   sudo bash gc2607-cstate-cmdline.sh clear     # remove the cap everywhere (drain fix) — needs reboot
#   sudo bash gc2607-cstate-cmdline.sh restore    # re-add the cap (emergency freeze protect) — needs reboot
#
#   After clear/restore: REBOOT, then verify with `status` (C6/C10 present) and re-measure:
#     sudo bash gc2607-suspend-check.sh 240 "post-cstate-cmdline-clear"   # expect ~2.2 W on battery
#   Freeze watch is already running (gc2607 telemetry/triage); revert with `restore` if a freeze recurs.
set -euo pipefail

ARG_RE='intel_idle\.max_cstate=[0-9]\+'   # BRE for grep/sed
ARG_SET='intel_idle.max_cstate=1'         # canonical form for restore / grubby
KCMD=/etc/kernel/cmdline
GRUBDEF=/etc/default/grub
TAG=gc2607-cstate-cmdline

[ "$(id -u)" -eq 0 ] || { echo "Needs root (grubby + /etc + grub regen). Re-run: sudo bash $0 ${*:-status}"; exit 1; }
command -v grubby >/dev/null || { echo "grubby not found — aborting."; exit 1; }

ts() { date +%Y%m%d-%H%M%S; }
running_kernel() { grubby --default-kernel 2>/dev/null; }

find_grubcfg() {
  for p in /boot/grub2/grub.cfg /boot/efi/EFI/fedora/grub.cfg; do [ -f "$p" ] && { echo "$p"; return; }; done
}

show_live_cstates() {
  local n d
  echo "  live idle states (what the CPU can actually enter now):"
  for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
    [ -d "$s" ] || continue
    n=$(cat "$s/name" 2>/dev/null); d=$(cat "$s/disable" 2>/dev/null)
    echo "    $(basename "$s")  name=$n  disable=$d"
  done
  echo "  intel_idle max_cstate param : $(cat /sys/module/intel_idle/parameters/max_cstate 2>/dev/null || echo '?')"
}

status() {
  echo "========== gc2607 cstate-cmdline STATUS =========="
  echo "kernel (running)   : $(uname -r)"
  echo "default entry      : $(running_kernel)"
  echo
  echo "-- cap presence in each persistent source ($ARG_SET) --"
  if grep -q "$ARG_RE" /proc/cmdline; then echo "  /proc/cmdline (LIVE)   : PRESENT  (cap active this boot -> C6/C10 blocked)"; \
    else echo "  /proc/cmdline (LIVE)   : absent   (deep sleep available this boot)"; fi
  if grubby --info="$(running_kernel)" 2>/dev/null | grep -q "$ARG_RE"; then echo "  BLS entry (grubby)     : PRESENT  (will re-apply next boot)"; \
    else echo "  BLS entry (grubby)     : absent"; fi
  if grep -qs "$ARG_RE" "$KCMD"; then echo "  $KCMD : PRESENT  (seeds NEW kernels)"; \
    else echo "  $KCMD : absent"; fi
  if grep -qs "$ARG_RE" "$GRUBDEF"; then echo "  $GRUBDEF : PRESENT  (seeds NEW kernels)"; \
    else echo "  $GRUBDEF : absent"; fi
  echo
  show_live_cstates
  echo
  if grep -q "$ARG_RE" /proc/cmdline; then
    echo ">> Cap is ACTIVE. 'clear' removes it (drain fix); a reboot is required to take effect."
  else
    echo ">> No cap active this boot. If sources above show PRESENT, a future kernel would re-inherit it — run 'clear' to scrub the sources."
  fi
}

scrub_file() {  # $1=file : remove the arg token + tidy whitespace, backup first (idempotent)
  local f="$1"
  [ -f "$f" ] || { echo "  (skip $f — not present)"; return; }
  if ! grep -q "$ARG_RE" "$f"; then echo "  $f : already clean"; return; fi
  cp -a "$f" "$f.gc2607.bak.$(ts)"
  sed -i -E "s/ ?intel_idle\.max_cstate=[0-9]+//g; s/  +/ /g; s/\" /\"/g; s/ \"/\"/g" "$f"
  echo "  $f : removed (backup: $f.gc2607.bak.*)"
}

add_to_file() {  # $1=file : ensure the arg is present inside the value (for restore)
  local f="$1"
  [ -f "$f" ] || { echo "  (skip $f — not present)"; return; }
  if grep -q "$ARG_RE" "$f"; then echo "  $f : already has cap"; return; fi
  cp -a "$f" "$f.gc2607.bak.$(ts)"
  if [ "$f" = "$GRUBDEF" ]; then
    sed -i -E "s/^(GRUB_CMDLINE_LINUX=\".*)\"/\1 $ARG_SET\"/" "$f"
  else
    sed -i -E "s/\$/ $ARG_SET/" "$f"; sed -i -E "s/  +/ /g; s/^ //" "$f"
  fi
  echo "  $f : added $ARG_SET (backup: $f.gc2607.bak.*)"
}

regen_grub() {
  local cfg; cfg=$(find_grubcfg)
  if [ -n "$cfg" ] && command -v grub2-mkconfig >/dev/null; then
    echo "  regenerating $cfg ..."; grub2-mkconfig -o "$cfg" >/dev/null 2>&1 && echo "  grub.cfg regenerated" || echo "  (grub2-mkconfig returned nonzero — BLS entries already updated by grubby, usually fine)"
  else
    echo "  (no grub.cfg / grub2-mkconfig — BLS entries handled by grubby)"
  fi
}

clear_cap() {
  echo "========== CLEAR intel_idle.max_cstate cap (drain fix) =========="
  echo "[1/4] all BLS boot entries (grubby --update-kernel=ALL --remove-args) ..."
  grubby --update-kernel=ALL --remove-args="intel_idle.max_cstate" 2>/dev/null || true
  # grubby matches by key; also strip the explicit =1 form just in case
  grubby --update-kernel=ALL --remove-args="$ARG_SET" 2>/dev/null || true
  echo "  done"
  echo "[2/4] persistent seed files ..."
  scrub_file "$KCMD"; scrub_file "$GRUBDEF"
  echo "[3/4] grub config ..."; regen_grub
  echo "[4/4] verify default entry no longer carries the cap ..."
  if grubby --info="$(running_kernel)" 2>/dev/null | grep -q "$ARG_RE"; then
    echo "  !! STILL PRESENT in the default entry — inspect: grubby --info=$(running_kernel)"; exit 1
  else
    echo "  OK — default entry is clean."
  fi
  logger -t "$TAG" "cleared intel_idle.max_cstate cap from BLS + seed files"
  echo
  echo ">>> REBOOT REQUIRED for this to take effect (the LIVE cmdline still has the cap until then)."
  echo ">>> A reboot STOPS running jobs (Docker stacks, StratSense, any XPU run) — quiesce first if needed."
  echo ">>> After reboot:  sudo bash $0 status   (expect POLL/C1E + C6/C10)  then re-measure suspend on battery."
}

restore_cap() {
  echo "========== RESTORE intel_idle.max_cstate=1 cap (emergency freeze-protect) =========="
  grubby --update-kernel=ALL --args="$ARG_SET" 2>/dev/null || true
  add_to_file "$KCMD"; add_to_file "$GRUBDEF"; regen_grub
  logger -t "$TAG" "restored intel_idle.max_cstate=1 cap"
  echo ">>> REBOOT REQUIRED. Note: the confirmed freeze fix is NVMe ASPM (gc2607-nvme-aspm), not this cap."
}

case "${1:-status}" in
  status)  status ;;
  clear)   clear_cap ;;
  restore) restore_cap ;;
  *) echo "usage: sudo bash $0 [status|clear|restore]" >&2; exit 2 ;;
esac
