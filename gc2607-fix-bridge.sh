#!/bin/bash
#
# Install a patched ipu-bridge.ko (with GC2607 support) into
# /lib/modules/<kver>/extra/ and, if <kver> is the running kernel,
# hot-swap it and restart the camera service.
#
# Usage: sudo ./gc2607-fix-bridge.sh <kver> <path-to-ipu-bridge.ko>
#
set -euo pipefail

KVER="${1:?usage: gc2607-fix-bridge.sh <kver> <ipu-bridge.ko>}"
KO="${2:?usage: gc2607-fix-bridge.sh <kver> <ipu-bridge.ko>}"

[ -f "$KO" ] || { echo "ERROR: $KO not found" >&2; exit 1; }
[ -d "/lib/modules/$KVER" ] || { echo "ERROR: no modules tree for $KVER" >&2; exit 1; }

# vermagic sanity: refuse to install a module built for a different kernel
VMAGIC=$(modinfo -F vermagic "$KO" | awk '{print $1}')
if [ "$VMAGIC" != "$KVER" ]; then
    echo "ERROR: vermagic $VMAGIC does not match target kernel $KVER" >&2
    exit 1
fi

echo "[fix-bridge] Installing $(basename "$KO") for $KVER"

# depmod override uses the module file stem (dash form); the old conf line
# with an underscore never matched. Ensure the correct line is present.
CONF=/etc/depmod.d/ipu-bridge-gc2607.conf
grep -qxF 'override ipu-bridge * extra' "$CONF" 2>/dev/null || \
    echo 'override ipu-bridge * extra' >> "$CONF"

mkdir -p "/lib/modules/$KVER/extra"
# kernel in-module decompressor requires crc32 + small dict (matches kmod)
xz -c --check=crc32 --lzma2=dict=1MiB "$KO" > "/lib/modules/$KVER/extra/ipu-bridge.ko.xz"
depmod "$KVER"
echo "[fix-bridge] Installed to /lib/modules/$KVER/extra/ipu-bridge.ko.xz, depmod done"

if [ "$KVER" = "$(uname -r)" ]; then
    echo "[fix-bridge] Target is the running kernel — hot-swapping"
    systemctl stop gc2607-camera.service 2>/dev/null || true
    # unload consumers first; tolerate not-loaded
    for m in gc2607 intel_ipu6_isys intel_ipu6 ipu_bridge; do
        modprobe -r "$m" 2>/dev/null || true
    done
    if [ -d /sys/module/ipu_bridge ]; then
        echo "ERROR: ipu_bridge still loaded, cannot swap" >&2
        exit 1
    fi
    RESOLVED=$(modinfo -k "$KVER" -F filename ipu-bridge)
    case "$RESOLVED" in
        */extra/ipu-bridge.ko.xz) echo "[fix-bridge] depmod resolves ipu-bridge -> $RESOLVED" ;;
        *) echo "ERROR: depmod still resolves to $RESOLVED" >&2; exit 1 ;;
    esac
    modprobe ipu-bridge
    [ -d /sys/module/ipu_bridge ] || { echo "ERROR: ipu_bridge did not load" >&2; exit 1; }
    echo "[fix-bridge] Patched ipu_bridge loaded"
    systemctl start gc2607-camera.service
    sleep 4
    if systemctl is-active --quiet gc2607-camera.service; then
        echo "[fix-bridge] OK: gc2607-camera.service active"
    else
        echo "[fix-bridge] WARNING: service not active yet:" >&2
        journalctl -u gc2607-camera.service --no-pager -n 10 >&2
        exit 1
    fi
fi
echo "[fix-bridge] DONE"
