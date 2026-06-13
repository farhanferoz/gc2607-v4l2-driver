#!/bin/bash
#
# gc2607-verify-712.sh — confirm the 7.0.12 migration after reboot:
# kernel, the Phase-1b C6 split, GPU-IRQ pin, the patched camera, and battery settings.
# Read-only. No sudo needed.
#
b(){ printf '\033[1m%-16s\033[0m %s\n' "$1" "$2"; }

echo "===== gc2607 7.0.12 post-reboot verification ====="
b "kernel:"     "$(uname -r)   (expect 7.0.12-201.fc44.x86_64)"
b "uptime:"     "$(uptime -p)"
b "C6 cap:"     "$(grep -o 'intel_idle.max_cstate=[0-9]' /proc/cmdline || echo 'absent — good (marker drives Phase-1b)')"
b "PSR arg:"    "$(grep -o 'i915.enable_psr=[0-9]' /proc/cmdline || echo '(none)')"
printf '\033[1m%-16s\033[0m' "C6 split:"
for c in 0 2 20 21; do printf 'cpu%s=%s ' "$c" "$(cat /sys/devices/system/cpu/cpu$c/cpuidle/state2/disable 2>/dev/null)"; done
echo "  (expect cpu0=0 cpu2=0 cpu20=1 cpu21=1)"
b "IRQ200 affin:" "$(cat /proc/irq/200/smp_affinity_list 2>/dev/null)   (expect 2)"
b "cstate svc:"  "$(systemctl is-active gc2607-cstate-test.service)"
echo
b "camera svc:"  "$(systemctl is-active gc2607-camera.service)"
b "loaded mods:" "$(lsmod | grep -E 'ipu_bridge|gc2607|intel_ipu6' | awk '{print $1}' | tr '\n' ' ')"
b "bridge file:" "$(modinfo -F filename ipu_bridge 2>/dev/null)"
b "bridge vmag:" "$(modinfo -F vermagic ipu_bridge 2>/dev/null)"
echo "video nodes:"; v4l2-ctl --list-devices 2>/dev/null | sed 's/^/   /' | head -20
echo
b "tuned:"       "$(tuned-adm active 2>/dev/null | sed 's/.*: //')   (expect balanced-battery)"
b "EPP(cpu0):"   "$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)"
b "telemetry:"   "$(systemctl --user is-active gc2607-telemetry.service)"
echo
echo "If kernel=7.0.12, the C6 split is 20/21-only, and the camera service is active, the migration is good."
echo "Battery: unplug and run  sudo bash $PWD/gc2607-power-measure.sh  (restore from the 06-12 archive) to measure."
