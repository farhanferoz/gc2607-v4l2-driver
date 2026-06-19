#!/bin/bash
#
# gc2607-boot-kernel.sh - control which installed kernel boots by DEFAULT, so a
# silent-freeze + auto-reboot can never bounce onto an untrusted kernel (crash #19
# auto-rebooted into 7.0.12 because the default was still 7.0.12). Productized A/B
# helper - the RESUME follow-up for kernel toggling. Runs via the gc2607-*.sh
# sudo trampoline (raw grubby needs real root; this script does not).
#
#   status          - show running kernel, current default, and all installed kernels
#   set <ver|path>  - set the default boot kernel (e.g. 7.0.11-200.fc44.x86_64)
#   set-running     - pin the default to the currently-running kernel
#
set -u
MODE="${1:-status}"

if [ "$(id -u)" -ne 0 ]; then
    echo "re-exec as root via trampoline..." >&2
    exec sudo -n "$0" "$@"
fi

resolve() {
    case "$1" in
        /boot/vmlinuz-*) echo "$1" ;;
        vmlinuz-*)       echo "/boot/$1" ;;
        *)               echo "/boot/vmlinuz-$1" ;;
    esac
}

case "$MODE" in
  status)
    echo "running default check:"
    echo "  running : $(uname -r)"
    echo "  default : $(grubby --default-kernel 2>/dev/null || echo '<grubby read failed>')"
    echo "  installed:"
    for k in /boot/vmlinuz-*.fc44.x86_64; do
        mark=""; [ "$(basename "$k")" = "vmlinuz-$(uname -r)" ] && mark="   <- running"
        echo "    $k$mark"
    done
    ;;
  set)
    K="$(resolve "${2:-}")"
    [ -e "$K" ] || { echo "FATAL: $K not found"; exit 1; }
    grubby --set-default="$K" && echo "default set -> $(grubby --default-kernel)"
    ;;
  set-running)
    K="/boot/vmlinuz-$(uname -r)"
    grubby --set-default="$K" && echo "default pinned -> $(grubby --default-kernel)"
    ;;
  *)
    echo "usage: $0 {status | set <version|path> | set-running}"; exit 2 ;;
esac
