#!/bin/bash
#
# Install the repo's gc2607.c THROUGH DKMS and reload it in place.
#
# Through DKMS, not by copying a local build into extra/: DKMS rebuilds its own source copy
# (/usr/src/gc2607-1.0) on every kernel update, so a module installed around it lasts only
# until the next update. That is how the January driver silently replaced the May one on
# 7.2.5, 7.2.6 and 7.2.7 (found 2026-09-23). The source copy is now written here, every time.
# Only
# touches the two modules that need to move: intel_ipu6_isys (which
# holds the v4l2-async reference to gc2607's subdev) and gc2607 itself.
# Leaves intel_ipu6 / intel_ipu6_psys / ipu_bridge alone — those don't
# need to be torn down to swap the sensor driver.
#
# Stops and restarts gc2607-camera.service around the reload, with
# auto-rollback if anything fails.
#
# Usage:  sudo /home/ff235/dev/gc2607-v4l2-driver/gc2607-driver-install.sh
#

set -euo pipefail

KVER="$(uname -r)"
EXTRA="/lib/modules/${KVER}/extra"
REPO_C="/home/ff235/dev/gc2607-v4l2-driver/gc2607.c"
DKMS_VER="gc2607/1.0"
DKMS_SRC="/usr/src/gc2607-1.0"
TARGET="${EXTRA}/gc2607.ko.xz"
BACKUP="${TARGET}.bak"

log() { echo "[driver-install] $*"; }
die() { echo "[driver-install] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$REPO_C" ]     || die "driver source not found: $REPO_C"
[ -d "$DKMS_SRC" ]   || die "no DKMS package at $DKMS_SRC (run dkms-setup.sh once)"

# Every kernel that has build headers, so a fallback kernel boots the same driver.
kernels_with_headers() {
    local k
    for k in $(ls /lib/modules); do [ -d "/lib/modules/$k/build" ] && echo "$k"; done
}

# Roll back every kernel, not just the running one: the new source was built for all of them.
# The running kernel then gets its exact previous binary back from BACKUP.
restore_prev() {
    local k
    [ -f "$DKMS_SRC/gc2607.c.prev" ] && cp -f "$DKMS_SRC/gc2607.c.prev" "$DKMS_SRC/gc2607.c"
    for k in $(kernels_with_headers); do
        { dkms build "$DKMS_VER" -k "$k" --force && dkms install "$DKMS_VER" -k "$k" --force; } >/dev/null 2>&1 || true
    done
    [ -f "$BACKUP" ] && cp -f "$BACKUP" "$TARGET"
    depmod -a
}

rebind_stack() {
    # If isys was loaded, removing it drops the async ref on gc2607.
    # If it wasn't loaded, the modprobe -r is a no-op.
    modprobe -r intel_ipu6_isys 2>/dev/null || true
    modprobe -r gc2607 2>/dev/null || true
    # Now reload in dependency order. modprobe gc2607 only registers
    # the i2c_driver — matching i2c_clients are auto-bound by the bus,
    # but on stale state the existing GCTI2607 client may not get a
    # fresh probe call. Force it via sysfs unbind/bind so any new
    # control-init code paths actually run.
    modprobe gc2607 || return 1
    if [ -e /sys/bus/i2c/devices/i2c-GCTI2607:00/driver ]; then
        echo i2c-GCTI2607:00 > /sys/bus/i2c/drivers/gc2607/unbind 2>/dev/null || true
    fi
    if [ -e /sys/bus/i2c/devices/i2c-GCTI2607:00 ]; then
        echo i2c-GCTI2607:00 > /sys/bus/i2c/drivers/gc2607/bind 2>/dev/null || true
    fi
    modprobe intel_ipu6_isys || return 1
}

log "stopping camera service..."
systemctl stop gc2607-camera.service || true

log "backing up current module and DKMS source..."
mkdir -p "$EXTRA"
[ -f "$TARGET" ] && cp -f "$TARGET" "$BACKUP"
cp -f "$DKMS_SRC/gc2607.c" "$DKMS_SRC/gc2607.c.prev"

log "installing $REPO_C through DKMS..."
cp -f "$REPO_C" "$DKMS_SRC/gc2607.c"
for k in $(kernels_with_headers); do
    if ! { dkms build "$DKMS_VER" -k "$k" --force && dkms install "$DKMS_VER" -k "$k" --force; } >/dev/null; then
        restore_prev
        die "DKMS build/install failed for $k; previous source and module restored"
    fi
    log "  built and installed for $k"
done
cmp -s "$REPO_C" "$DKMS_SRC/gc2607.c" || die "DKMS source does not match the repo after install"

log "reloading gc2607 + intel_ipu6_isys..."
if ! rebind_stack; then
    log "reload failed; restoring backup..."
    restore_prev
    rebind_stack || true
    die "module reload failed; previous module restored"
fi

# Probe should complete within ~2s
sleep 2

if ! grep -q '^gc2607 ' /proc/modules; then
    log "gc2607 module is not loaded after reload; restoring..."
    restore_prev
    rebind_stack || true
    die "new module failed to stay loaded; backup restored"
fi

log "verifying media topology..."
if ! media-ctl -d /dev/media0 -p 2>/dev/null | grep -q 'gc2607 5-0037'; then
    log "gc2607 not in media topology; restoring backup..."
    restore_prev
    rebind_stack || true
    die "gc2607 loaded but not in media graph; backup restored"
fi

log "starting camera service..."
systemctl start gc2607-camera.service
sleep 2

if ! systemctl is-active --quiet gc2607-camera.service; then
    log "service failed; restoring backup..."
    systemctl stop gc2607-camera.service || true
    restore_prev
    rebind_stack || true
    systemctl start gc2607-camera.service || true
    die "new module installed but camera service unhealthy; backup restored"
fi

log "OK: $(date) $(stat -c '%s' "$TARGET") bytes"
