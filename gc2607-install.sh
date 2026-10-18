#!/bin/bash
#
# GC2607 Camera Driver Installer for Huawei MateBook X Pro (VGHH-XX)
#
# Installs:
#   1. Patched ipu_bridge module (adds GCTI2607 sensor recognition)
#   2. gc2607.ko V4L2 sensor driver
#
# Source: https://github.com/abbood/gc2607-v4l2-driver
#
# Usage:
#   sudo ./gc2607-install.sh          # install for current kernel
#   sudo ./gc2607-install.sh revert   # revert to original modules
#

set -euo pipefail

# HISTORICAL. Superseded by DKMS (dkms-setup.sh), which rebuilds both modules on every kernel update; a module
# copied into extra/ by this script is overwritten by DKMS at the next update. Its kernel/v6.x source URLs
# cannot work on 7.x kernels. Kept for reference only.
if [ "${GC2607_HISTORICAL_INSTALL:-}" != 1 ]; then
    echo "gc2607-install.sh is historical: use dkms-setup.sh and gc2607-driver-install.sh" >&2
    echo "(see docs/operations-runbook.md, 'After a kernel update')." >&2
    exit 1
fi

KVER="$(uname -r)"
KVER_SHORT="${KVER%%-*}"
MODULES_DIR="/lib/modules/${KVER}"
IPU_BRIDGE_DIR="${MODULES_DIR}/kernel/drivers/media/pci/intel"
IPU_BRIDGE_FILE="${IPU_BRIDGE_DIR}/ipu-bridge.ko.xz"
EXTRA_DIR="${MODULES_DIR}/extra"
GC2607_SYSTEM="${EXTRA_DIR}/gc2607.ko"
MODULES_LOAD_CONF="/etc/modules-load.d/gc2607.conf"

# Resolve paths relative to this script's location and the invoking user
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_REPO="${SCRIPT_DIR}"
USER_HOME="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
BACKUP_DIR="${USER_HOME}/gc2607-backups"

BUILD_DIR="/tmp/gc2607-build-$$"
LINK_FREQ="336000000"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

cleanup() {
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
}
trap cleanup EXIT

# ── Preflight checks ──────────────────────────────────────────────

preflight() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (sudo)."
    fi

    if [ ! -d "/usr/src/kernels/${KVER}" ]; then
        die "Kernel headers not found for ${KVER}. Install with: dnf install kernel-devel-${KVER}"
    fi

    if [ ! -f "${IPU_BRIDGE_FILE}" ]; then
        die "System ipu-bridge module not found at ${IPU_BRIDGE_FILE}"
    fi

    if [ ! -f "${DRIVER_REPO}/gc2607.c" ]; then
        die "gc2607.c not found in ${DRIVER_REPO}. Run this script from the gc2607-v4l2-driver directory."
    fi

    for cmd in make gcc xz depmod curl; do
        if ! command -v "$cmd" &>/dev/null; then
            die "Required command '${cmd}' not found."
        fi
    done

    if ! curl -sI "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER_SHORT}.tar.xz" | head -1 | grep -q "200"; then
        die "Cannot reach cdn.kernel.org to download kernel source for ${KVER_SHORT}."
    fi
}

# ── Revert ─────────────────────────────────────────────────────────

revert() {
    info "Reverting gc2607 camera driver installation..."

    local latest_backup
    latest_backup="$(ls -t "${BACKUP_DIR}"/ipu-bridge.ko.xz.* 2>/dev/null | head -1)" || true

    if [ -n "$latest_backup" ]; then
        info "Restoring ipu-bridge from: ${latest_backup}"
        cp "$latest_backup" "$IPU_BRIDGE_FILE"
        info "ipu-bridge restored."
    else
        warn "No backup found. Reinstalling stock module with: dnf reinstall kernel-modules-${KVER}"
        dnf reinstall -y "kernel-modules-${KVER}" || die "Failed to reinstall kernel-modules."
    fi

    if [ -f "$GC2607_SYSTEM" ]; then
        rm -f "$GC2607_SYSTEM"
        info "Removed ${GC2607_SYSTEM}"
    fi

    if [ -f "$MODULES_LOAD_CONF" ]; then
        rm -f "$MODULES_LOAD_CONF"
        info "Removed ${MODULES_LOAD_CONF}"
    fi

    depmod -a
    info "Module dependencies updated."
    echo ""
    info "Revert complete. Reboot to apply: sudo reboot"
    exit 0
}

# ── Build gc2607.ko ────────────────────────────────────────────────

build_gc2607() {
    info "Building gc2607.ko from source..."

    cd "$DRIVER_REPO"
    make clean 2>/dev/null || true
    make 2>&1 || die "Failed to build gc2607.ko"

    if [ ! -f "${DRIVER_REPO}/gc2607.ko" ]; then
        die "gc2607.ko was not produced by the build."
    fi

    info "gc2607.ko built successfully."
}

# ── Download, patch, and build ipu-bridge ──────────────────────────

build_ipu_bridge() {
    info "Downloading kernel ${KVER_SHORT} source (ipu-bridge.c only)..."

    mkdir -p "$BUILD_DIR"

    curl -sL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER_SHORT}.tar.xz" \
        | xz -d \
        | tar -xf - -C "$BUILD_DIR" "linux-${KVER_SHORT}/drivers/media/pci/intel/ipu-bridge.c" \
        || die "Failed to download/extract ipu-bridge.c from kernel source."

    local src="${BUILD_DIR}/linux-${KVER_SHORT}/drivers/media/pci/intel/ipu-bridge.c"

    if [ ! -f "$src" ]; then
        die "ipu-bridge.c not found after extraction."
    fi

    # Check if already patched (future kernels may include this)
    if grep -q "GCTI2607" "$src"; then
        info "ipu-bridge.c already contains GCTI2607 support. Skipping patch."
    else
        info "Patching ipu-bridge.c to add GCTI2607 sensor..."

        sed -i '/static const struct ipu_sensor_config ipu_supported_sensors\[\] = {/a\\t/* GalaxyCore GC2607 */\n\tIPU_SENSOR_CONFIG("GCTI2607", 1, '"${LINK_FREQ}"'),' "$src"

        if ! grep -q "GCTI2607" "$src"; then
            die "Patch failed: GCTI2607 not found in patched file."
        fi

        info "Patch applied."
    fi

    local build_path
    build_path="$(dirname "$src")"
    cat > "${build_path}/Makefile" << 'MAKEFILE'
obj-m := ipu-bridge.o
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
MAKEFILE

    info "Building patched ipu-bridge module..."
    make -C "$build_path" 2>&1 || die "Failed to build patched ipu-bridge.ko"

    if [ ! -f "${build_path}/ipu-bridge.ko" ]; then
        die "ipu-bridge.ko was not produced by the build."
    fi

    info "Patched ipu-bridge.ko built successfully."
}

# ── Install ────────────────────────────────────────────────────────

install_modules() {
    local build_path="${BUILD_DIR}/linux-${KVER_SHORT}/drivers/media/pci/intel"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"

    # Back up original ipu-bridge
    mkdir -p "$BACKUP_DIR"
    cp "$IPU_BRIDGE_FILE" "${BACKUP_DIR}/ipu-bridge.ko.xz.${timestamp}"
    info "Original ipu-bridge backed up to: ${BACKUP_DIR}/ipu-bridge.ko.xz.${timestamp}"

    # Compress and install patched ipu-bridge
    # Must use --check=crc32 to match Fedora's kernel module loader expectation
    xz --check=crc32 -f -k "${build_path}/ipu-bridge.ko"
    cp "${build_path}/ipu-bridge.ko.xz" "$IPU_BRIDGE_FILE"
    info "Patched ipu-bridge.ko.xz installed to ${IPU_BRIDGE_FILE}"

    # Install gc2607
    mkdir -p "$EXTRA_DIR"
    cp "${DRIVER_REPO}/gc2607.ko" "$GC2607_SYSTEM"
    info "gc2607.ko installed to ${GC2607_SYSTEM}"

    # Auto-load at boot
    echo "gc2607" > "$MODULES_LOAD_CONF"
    info "gc2607 set to load at boot via ${MODULES_LOAD_CONF}"

    # Update module dependencies
    depmod -a
    info "Module dependencies updated."
}

# ── Verify ─────────────────────────────────────────────────────────

verify() {
    info "Verifying installation..."

    local ok=true

    if modinfo -n ipu_bridge 2>/dev/null | grep -q "ipu-bridge"; then
        info "  ipu_bridge module found: $(modinfo -n ipu_bridge 2>/dev/null)"
    else
        warn "  ipu_bridge module not found by modinfo."
        ok=false
    fi

    if modinfo -n gc2607 2>/dev/null | grep -q "gc2607"; then
        info "  gc2607 module found: $(modinfo -n gc2607 2>/dev/null)"
    else
        warn "  gc2607 module not found by modinfo."
        ok=false
    fi

    if ls "${BACKUP_DIR}"/ipu-bridge.ko.xz.* &>/dev/null; then
        info "  Backup exists in ${BACKUP_DIR}/"
    fi

    if [ "$ok" = true ]; then
        echo ""
        info "Installation complete!"
    else
        echo ""
        warn "Installation finished with warnings. Modules may still work after reboot."
    fi

    echo ""
    info "Reboot to activate: sudo reboot"
    echo ""
    info "After reboot, test with:"
    echo "  v4l2-ctl --list-devices"
    echo "  dmesg | grep -i gc2607"
    echo ""
    info "To revert: sudo $0 revert"
}

# ── Main ───────────────────────────────────────────────────────────

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " GC2607 Camera Driver Installer"
    echo " Kernel: ${KVER}"
    echo " Model:  $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ "${1:-}" = "revert" ]; then
        revert
    fi

    preflight
    build_gc2607
    build_ipu_bridge
    install_modules
    verify
}

main "$@"
