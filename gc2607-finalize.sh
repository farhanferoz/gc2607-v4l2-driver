#!/bin/bash
#
# gc2607-finalize.sh — graduate the silent-freeze fix to permanent and migrate to kernel 7.0.12.
#
# VERDICT (2026-06-13): Phase-1b SURVIVED. Holding the two LP-E cores (cpu20/21) out of C6 is the
# cure — a software fix, no warranty. This script makes that the standing config on 7.0.12 and
# folds in the post-verdict battery tuning. It is idempotent; safe to re-run.
#
#   Run once:  sudo bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-finalize.sh
#   Then:      reboot           # boots 7.0.12; 7.0.11 stays in the menu as a pristine fallback
#
set -uo pipefail   # deliberately NOT -e: attempt every section, report per-step

REPO=/home/ff235/dev/gc2607-v4l2-driver
K12=7.0.12-201.fc44.x86_64
V12=/boot/vmlinuz-$K12
V11=/boot/vmlinuz-7.0.11-200.fc44.x86_64
ok(){   printf '  \033[32mOK\033[0m   %s\n' "$1"; }
warn(){ printf '  \033[33m!!\033[0m   %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }

echo "== 1. Install the PATCHED camera modules for $K12 (built this session) =="
"$REPO/gc2607-fix-bridge.sh" "$K12" "$REPO/ipu-bridge-oot/7.0.12/ipu-bridge.ko" \
  && ok "patched ipu-bridge.ko installed" || warn "ipu-bridge install FAILED — camera will not work on 7.0.12"
install -d "/lib/modules/$K12/extra"
if xz -c --check=crc32 --lzma2=dict=1MiB "$REPO/gc2607.ko" > "/lib/modules/$K12/extra/gc2607.ko.xz"; then
  ok "gc2607.ko.xz installed"
else
  warn "gc2607.ko install FAILED"
fi
depmod "$K12"
for m in ipu-bridge gc2607; do
  r=$(modinfo -k "$K12" -F filename "$m" 2>/dev/null)
  case "$r" in */extra/*) ok "depmod resolves $m -> $r" ;; *) warn "depmod resolves $m -> ${r:-NOT FOUND} (expected .../extra/)" ;; esac
done

echo "== 2. Boot args — let the Phase-1b marker drive 7.0.12; re-enable PSR (7.0.12 ONLY) =="
# Remove the global C6 cap so the marker (C6-off on cpu20/21 only) takes effect; flip PSR for battery.
grubby --update-kernel="$V12" --remove-args="intel_idle.max_cstate=1 i915.enable_psr=0"
# PSR battery args + match 7.0.11's per-entry nvme.max_host_mem_size_mb=0 (harmless; keeps the
# only intended deltas vs the proven config = kernel version + PSR).
grubby --update-kernel="$V12" --args="i915.enable_psr=2 i915.enable_fbc=1 i915.enable_dc=4 nvme.max_host_mem_size_mb=0"
grubby --set-default="$V12" && ok "7.0.12 set as default boot entry"
echo "  -- 7.0.12 args now:"
grubby --info="$V12" | sed -n 's/^args=/       /p'
echo "  -- 7.0.11 FALLBACK args (must stay psr=0, NO cap, Phase-1b via marker — i.e. unchanged):"
grubby --info="$V11" | sed -n 's/^args=/       /p'

echo "== 3. Phase-1b marker present =="
printf 'test1b\n' > /etc/gc2607-cstate-mode && ok "/etc/gc2607-cstate-mode = test1b"

echo "== 4. Battery tuning (post-verdict) =="
PREV=$(tuned-adm active 2>/dev/null | sed 's/.*: //')
tuned-adm profile balanced-battery && ok "tuned profile: balanced-battery  (was: ${PREV:-unknown})" || warn "tuned-adm failed"
printf 'options iwlwifi power_save=1\n'      > /etc/modprobe.d/iwlwifi-power.conf && ok "iwlwifi power_save=1 (takes effect on reboot)"
printf 'options snd_hda_intel power_save=1\n' > /etc/modprobe.d/audio-power.conf  && ok "snd_hda_intel power_save=1 (takes effect on reboot)"

echo "== 5. Close the freeze case =="
snap refresh --unhold >/dev/null 2>&1 && ok "snap auto-refresh un-held" || warn "snap unhold skipped (no held snaps?)"

echo
echo "DONE. Review the 7.0.12 args above (sanity-check nothing freeze-relevant is missing vs 7.0.11),"
echo "then:  reboot"
echo "If the camera or display misbehaves on 7.0.12, pick the 7.0.11 entry at the boot menu —"
echo "it is the pristine, proven Phase-1b config. Post-reboot check: bash $REPO/gc2607-verify-712.sh"
