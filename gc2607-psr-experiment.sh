#!/bin/bash
#
# gc2607-psr-experiment.sh - manage the i915 display power-saving args
# (PSR / FBC / DC states) on a kernel boot entry.
#
# History: born as the crash-#18 discriminator (toggled display PM on the 7.0.12
# entry only, to isolate the kernel-bump variable; see
# docs/incidents/2026-05-silent-freezes.md). Crash #19 EXONERATED display PM
# (the PSR-off re-soak still froze), and 7.0.11 is now the daily-driver kernel,
# so this is generalised to operate on ANY installed kernel entry.
#
#   on      -> battery config: i915.enable_psr=2 enable_fbc=1 enable_dc=4
#   off     -> i915.enable_psr=0, drop fbc/dc (back to kernel defaults)
#   status  -> show the display args for every installed kernel, change nothing
#
# Target kernel: defaults to the RUNNING kernel. Override with a 2nd arg, e.g.
#   gc2607-psr-experiment.sh on /boot/vmlinuz-7.0.12-201.fc44.x86_64
# Takes effect on the next reboot. Runs via the gc2607-*.sh sudo trampoline.
#
set -u

MODE="${1:-status}"
TARGET="${2:-/boot/vmlinuz-$(uname -r)}"

if [ "$(id -u)" -ne 0 ]; then
    echo "re-exec as root via trampoline..." >&2
    exec sudo -n "$0" "$@"
fi

show() {
    local k="$1" args disp
    args=$(grubby --info="$k" 2>/dev/null | sed -n 's/^args="\(.*\)"/\1/p')
    disp=$(echo "$args" | grep -oE 'i915\.enable_(psr|fbc|dc)=[0-9]+' | tr '\n' ' ')
    echo "  $(basename "$k"): ${disp:-<kernel defaults (no explicit i915 display args)>}"
}

echo "=== gc2607-psr-experiment ($MODE) ==="
echo "target: $(basename "$TARGET")"
echo "BEFORE:"
for k in /boot/vmlinuz-*.fc44.x86_64; do show "$k"; done

case "$MODE" in
  on)
    [ -e "$TARGET" ] || { echo "FATAL: $TARGET not found"; exit 1; }
    grubby --update-kernel="$TARGET" \
           --remove-args="i915.enable_psr i915.enable_fbc i915.enable_dc"
    grubby --update-kernel="$TARGET" \
           --args="i915.enable_psr=2 i915.enable_fbc=1 i915.enable_dc=4"
    ;;
  off)
    [ -e "$TARGET" ] || { echo "FATAL: $TARGET not found"; exit 1; }
    grubby --update-kernel="$TARGET" \
           --remove-args="i915.enable_psr i915.enable_fbc i915.enable_dc"
    grubby --update-kernel="$TARGET" --args="i915.enable_psr=0"
    ;;
  status)
    echo "(status only - no change)"
    exit 0
    ;;
  *)
    echo "usage: $0 {off|on|status} [/boot/vmlinuz-VERSION]"; exit 2
    ;;
esac

echo "AFTER:"
for k in /boot/vmlinuz-*.fc44.x86_64; do show "$k"; done
echo
echo "Done. Takes effect on next reboot (target: $(basename "$TARGET"))."
echo "Revert: sudo $0 off $TARGET"
