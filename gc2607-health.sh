#!/usr/bin/env bash
#
# gc2607-health.sh — one-shot health check for the GC2607 machine. READ-ONLY, no sudo needed.
# Run anytime (after a reboot, a kernel update, or "is everything still OK?") to confirm:
#   1. the silent-freeze fix (SN740 PCIe ASPM-L1 off — the 2026-06-18 verdict) is engaged,
#   2. the camera (patched ipu-bridge + gc2607) is up,
#   3. power-management state (tuned/EPP/PSR), and
#   4. no crash on the last boot.
# Kernel-agnostic — reports actual values, doesn't assume a version.
#
b(){ printf '  %-15s %s\n' "$1" "$2"; }
hdr(){ printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

hdr "SYSTEM"
b "kernel:"  "$(uname -r)"
b "uptime:"  "$(uptime -p)"
# How did the boot just before this one end? (first crash/shutdown line = the previous boot's end)
prevend=$(last -x 2>/dev/null | grep -wE 'crash|shutdown' | head -1)
case "$prevend" in
  *crash*) b "prev boot:" "⚠ the previous boot ended in a CRASH — check: last -x | head" ;;
  *)       b "prev boot:" "previous boot shut down cleanly ✓" ;;
esac

hdr "SILENT-FREEZE FIX (expect: SN740 PCIe ASPM-L1 OFF — the 2026-06-18 verdict)"
b "SN740 l1_aspm:" "$(cat /sys/bus/pci/devices/0000:01:00.0/link/l1_aspm 2>/dev/null) (want 0 = ASPM-L1 disabled ✓)"
b "aspm svc:" "$(systemctl is-active gc2607-nvme-aspm.service 2>/dev/null) / $(systemctl is-enabled gc2607-nvme-aspm.service 2>/dev/null)"
b "link / AER:" "$(cat /sys/bus/pci/devices/0000:01:00.0/current_link_speed 2>/dev/null) x$(cat /sys/bus/pci/devices/0000:01:00.0/current_link_width 2>/dev/null), correctable=$(awk '/TOTAL_ERR_COR/{print $2}' /sys/bus/pci/devices/0000:01:00.0/aer_dev_correctable 2>/dev/null) (want 0)"
b "deep sleep:" "stock on all cores — C-state/test1b theory RETIRED 06-18 (marker=$(cat /etc/gc2607-cstate-mode 2>/dev/null||echo none), cstate svc $(systemctl is-active gc2607-cstate-test.service 2>/dev/null))"

hdr "CAMERA"
b "service:" "$(systemctl is-active gc2607-camera.service 2>/dev/null)"
b "modules:" "$(lsmod | grep -E 'ipu_bridge|gc2607|intel_ipu6' | awk '{print $1}' | tr '\n' ' ')"
b "bridge:" "$(modinfo -F filename ipu_bridge 2>/dev/null) ($(modinfo -F vermagic ipu_bridge 2>/dev/null | awk '{print $1}'))"
b "video nodes:" "$(v4l2-ctl --list-devices 2>/dev/null | grep -c '/dev/video') present"

hdr "POWER / BATTERY"
ac=$(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1)
b "power source:" "$([ "$ac" = 1 ] && echo 'AC (plugged in)' || echo 'BATTERY')"
b "tuned/EPP:" "$(tuned-adm active 2>/dev/null | sed 's/.*: //') / $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)"
b "battery auto:" "$(grep -q 'battery_detection=true' /etc/tuned/ppd.conf 2>/dev/null && echo 'on — balanced-battery auto-applies when unplugged ✓' || echo 'OFF')"
b "PSR:" "$(grep -o 'i915.enable_psr=[0-9]' /proc/cmdline)"
b "iwlwifi/audio ps:" "$(cat /sys/module/iwlwifi/parameters/power_save 2>/dev/null)/$(cat /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null)"

hdr "INSTRUMENTATION (freeze watchers — can retire once the cure is trusted)"
for s in gc2607-telemetry journal-capture-nas nvme-temp-watch gc2607-link-telem i915-watch; do
  st=$(systemctl is-active "$s.service" 2>/dev/null); su=$(systemctl --user is-active "$s.service" 2>/dev/null)
  b "$s:" "system=$st user=$su"
done
echo
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")"&&pwd)
echo "Full power posture + verdict + perf cost:  bash $HERE/gc2607-power-status.sh [perf]"
echo "To measure battery power: unplug, then       sudo bash $HERE/gc2607-power-measure.sh"
