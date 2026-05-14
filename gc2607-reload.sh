#!/bin/bash
#
# GC2607 Camera Driver Hot-Reload
#
# Attempts to reload the IPU6 module stack and load the gc2607 driver
# without a reboot. If modules are in use, reports what's blocking and exits.
#
# Note: Hot-reload can probe the sensor (I2C communication) but the media
# pipeline may not be wired up without a full reboot. If the test script
# reports no sensor in the media topology, a reboot is required.
#
# Usage:
#   sudo ./gc2607-reload.sh          # reload modules
#   sudo ./gc2607-reload.sh unload   # unload gc2607 only
#

set -euo pipefail

KVER="$(uname -r)"
# Fedora compresses installed modules; accept either form.
if [ -f "/lib/modules/${KVER}/extra/gc2607.ko.xz" ]; then
    GC2607_MODULE="/lib/modules/${KVER}/extra/gc2607.ko.xz"
else
    GC2607_MODULE="/lib/modules/${KVER}/extra/gc2607.ko"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (sudo)."
    fi
}

check_kernel() {
    if [ ! -f "$GC2607_MODULE" ]; then
        die "gc2607.ko not found for kernel ${KVER}. Kernel was likely updated.\n  Rebuild with: sudo $(dirname "${BASH_SOURCE[0]}")/gc2607-install.sh"
    fi
}

# Show what's holding a module in use
show_blockers() {
    local mod="$1"
    local holders refcount

    refcount=$(cat "/sys/module/${mod}/refcnt" 2>/dev/null) || return
    holders=$(ls "/sys/module/${mod}/holders/" 2>/dev/null) || true

    if [ -n "$holders" ]; then
        warn "  ${mod} (refcnt=${refcount}) held by: ${holders}"
    else
        warn "  ${mod} (refcnt=${refcount}) may be in use by userspace"
    fi
}

# Try to unload a module, return 0 on success or if not loaded
try_unload() {
    local mod="$1"

    if ! grep -q "^${mod} " /proc/modules; then
        return 0
    fi

    if modprobe -r "$mod" 2>/dev/null; then
        info "Unloaded ${mod}"
        return 0
    else
        error "Cannot unload ${mod}"
        show_blockers "$mod"
        return 1
    fi
}

# Unload gc2607 only
unload_gc2607() {
    info "Unloading gc2607..."
    if try_unload gc2607; then
        info "gc2607 unloaded."
    else
        die "Failed to unload gc2607. Close any application using the camera first."
    fi
}

# Full reload of the IPU6 stack + gc2607
reload_all() {
    info "Attempting hot-reload of camera modules..."
    echo ""

    # Phase 1: Unload in reverse dependency order
    info "Phase 1: Unloading modules..."

    # Unload isys before gc2607: isys holds a v4l2-async reference to
    # gc2607's subdev (refcount appears on gc2607 with no entry in
    # /sys/module/gc2607/holders), so unloading gc2607 first fails with
    # "in use by userspace". Unloading isys first drops the async hold.
    local unload_order=(intel_ipu6_isys gc2607 intel_ipu6 ipu_bridge)
    local failed=false

    for mod in "${unload_order[@]}"; do
        if ! try_unload "$mod"; then
            failed=true
            break
        fi
    done

    if [ "$failed" = true ]; then
        echo ""
        error "Cannot unload module stack cleanly."
        echo ""
        warn "Possible causes:"
        echo "  - An application is using /dev/video* (camera app, browser, OBS)"
        echo "  - A v4l2loopback device is active"
        echo ""
        warn "Try closing camera applications, then run again."
        warn "If that doesn't work, a reboot is required."

        # Try to restore any modules we already unloaded
        info "Restoring previously unloaded modules..."
        modprobe ipu_bridge 2>/dev/null || true
        modprobe intel_ipu6 2>/dev/null || true
        modprobe intel_ipu6_isys 2>/dev/null || true
        exit 1
    fi

    echo ""

    # Phase 2: Reload in dependency order
    info "Phase 2: Loading patched modules..."

    if ! modprobe ipu_bridge; then
        die "Failed to load ipu_bridge."
    fi
    info "Loaded ipu_bridge"

    if ! modprobe intel_ipu6; then
        die "Failed to load intel_ipu6."
    fi
    info "Loaded intel_ipu6"

    if ! modprobe intel_ipu6_isys; then
        die "Failed to load intel_ipu6_isys."
    fi
    info "Loaded intel_ipu6_isys"

    # Small delay for device enumeration
    sleep 1

    if [ ! -f "$GC2607_MODULE" ]; then
        die "gc2607.ko not found at ${GC2607_MODULE}. Run gc2607-install.sh first."
    fi

    if ! modprobe gc2607; then
        die "Failed to load gc2607."
    fi
    info "Loaded gc2607"

    echo ""

    # Phase 3: Verify
    info "Phase 3: Checking results..."

    # Wait for probe to complete
    sleep 2

    # Check module is still loaded
    if ! grep -q "^gc2607 " /proc/modules; then
        error "gc2607 module loaded but did not stay loaded."
        warn "Check dmesg for errors: dmesg | grep -i gc2607"
        exit 1
    fi

    # Check dmesg for probe result
    local gc_dmesg
    gc_dmesg=$(dmesg 2>/dev/null | grep -i gc2607 | tail -10) || true

    if echo "$gc_dmesg" | grep -q "probe successful"; then
        info "gc2607 probe successful!"
        echo ""
        echo "$gc_dmesg" | tail -5
        echo ""

        # Check if sensor appears in media topology
        local sensor_in_topology=false
        for dev in /dev/media*; do
            if media-ctl -d "$dev" --print-topology 2>/dev/null | grep -qi "gc2607"; then
                sensor_in_topology=true
                break
            fi
        done

        if [ "$sensor_in_topology" = true ]; then
            info "Sensor is wired into the media pipeline."
            info "Run gc2607-test.sh to capture an image."
        else
            warn "Sensor probed but is NOT in the media topology."
            warn "The IPU6 bridge wires sensors at boot time only."
            warn "A reboot is required for full camera functionality: sudo reboot"
        fi
    elif echo "$gc_dmesg" | grep -qi "error\|fail"; then
        warn "gc2607 loaded but reported errors:"
        echo "$gc_dmesg"
        echo ""
        warn "A reboot is required."
    else
        warn "gc2607 loaded, no probe message found in dmesg."
        warn "A reboot is likely required."
    fi
}

# ── Main ───────────────────────────────────────────────────────────

check_root
check_kernel

case "${1:-}" in
    unload)
        unload_gc2607
        ;;
    *)
        reload_all
        ;;
esac
