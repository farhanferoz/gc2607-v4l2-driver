#!/bin/bash
#
# gc2607-kernel-cleanup.sh — remove an old boot-menu kernel and/or sweep orphaned
# /boot cruft on this freeze-prone box, without endangering the running/default kernel.
#
#   sudo bash gc2607-kernel-cleanup.sh <version>   # remove one kernel (RPMs+BLS+modules), then sweep orphans
#   sudo bash gc2607-kernel-cleanup.sh sweep       # only sweep orphaned non-rpm /boot files
#
#   e.g.  sudo bash gc2607-kernel-cleanup.sh 7.0.11-200.fc44.x86_64
#
# Guards: refuses to remove the RUNNING kernel or the DEFAULT boot entry.
# Sweep only deletes /boot files whose version has NO installed rpm and is not
# running/rescue — i.e. leaked kdump initramfs from long-gone kernels (dnf can't
# remove these because no package owns them).
#
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo bash $0 <version|sweep>" >&2; exit 1; }

RUN=$(uname -r)

# --- orphan sweep: delete /boot files no rpm owns (leaked kdump initramfs etc.) ------
sweep_orphans() {
    mapfile -t LIVE < <(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core 2>/dev/null)
    LIVE+=("$RUN")                                   # full NVRA versions we must keep
    local f b k keep any=0
    for f in /boot/initramfs-* /boot/vmlinuz-* /boot/System.map-* /boot/symvers-* /boot/config-*; do
        [ -e "$f" ] || continue
        case "$f" in *0-rescue-*) continue ;; esac   # never touch the rescue image
        b=$(basename "$f")
        # Keep if the filename contains ANY live kernel version. Substring-match on the
        # full NVRA (e.g. 7.0.12-201.fc44.x86_64) is robust to every suffix the kernel
        # ships (.img, .xz, .hmac, kdump.img, ...) — do NOT parse/strip suffixes, that
        # is what wrongly swept symvers-<running>.xz before.
        keep=0
        for k in "${LIVE[@]}"; do
            [ -n "$k" ] || continue
            case "$b" in *"$k"*) keep=1; break ;; esac
        done
        [ "$keep" = 1 ] && continue
        echo "  rm $f"; rm -f -- "$f"; any=1
    done
    [ "$any" = 0 ] && echo "  (no orphaned /boot files)"
}

if [ "${1:-}" = "sweep" ]; then
    echo "--- sweeping orphaned /boot files ---"
    sweep_orphans
    exit 0
fi

KV="${1:?usage: sudo bash $0 <version e.g. 7.0.11-200.fc44.x86_64> | sweep}"
[ "$KV" = "$RUN" ] && { echo "REFUSING: $KV is the running kernel." >&2; exit 1; }
DEF=$(grubby --default-kernel 2>/dev/null)
case "$DEF" in *"$KV"*) echo "REFUSING: $KV is the default boot entry ($DEF). Re-pin first: sudo bash gc2607-boot-kernel.sh set-running" >&2; exit 1 ;; esac

# rpm -qa glob matches NAMES (no version), so match the full NVRA by filtering instead.
PKGS=$(rpm -qa | grep -F -- "$KV" | grep -E '^kernel')
[ -n "$PKGS" ] || { echo "No installed kernel packages contain version ${KV}" >&2; exit 1; }
echo "Removing kernel $KV — packages:"; echo "$PKGS" | sed 's/^/    /'
dnf -y remove $PKGS 2>&1 | tail -15

echo
echo "--- sweeping orphaned /boot files (incl. any freshly-leaked kdump initramfs) ---"
sweep_orphans

echo
echo "--- kernels still installed ---"; rpm -q kernel-core | sed 's/^/    /'
echo "--- default boot entry ---"; grubby --default-kernel
