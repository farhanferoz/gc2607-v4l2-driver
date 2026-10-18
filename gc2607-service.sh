#!/bin/bash
#
# GC2607 Camera Service Script
# Called by systemd gc2607-camera.service at boot.
# Sets up the full pipeline and starts the Python virtualcam.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"

log() { echo "[gc2607] $*"; }
die() { echo "[gc2607] ERROR: $*" >&2; exit 1; }

# ── Load Modules ────────────────────────────────────────────────────

log "Loading kernel modules..."
for mod in videodev v4l2-async ipu_bridge intel-ipu6 intel-ipu6-isys; do
    modprobe "$mod" 2>/dev/null || true
done
sleep 1

# Load gc2607
if ! grep -q "^gc2607 " /proc/modules; then
    if [ -f "/lib/modules/${KVER}/extra/gc2607.ko" ] || [ -f "/lib/modules/${KVER}/extra/gc2607.ko.xz" ]; then
        modprobe gc2607
    elif [ -f "${SCRIPT_DIR}/gc2607.ko" ]; then
        insmod "${SCRIPT_DIR}/gc2607.ko"
    else
        die "gc2607.ko not found"
    fi
fi
sleep 2

# ── Verify Sensor ───────────────────────────────────────────────────

if ! grep -q "^gc2607 " /proc/modules; then
    die "gc2607 module not loaded"
fi

MEDIA_DEV=""
for dev in /dev/media*; do
    if media-ctl -d "$dev" --print-topology 2>/dev/null | grep -qi "gc2607"; then
        MEDIA_DEV="$dev"
        break
    fi
done

if [ -z "$MEDIA_DEV" ]; then
    die "GC2607 not in media topology"
fi
log "Sensor on $MEDIA_DEV"

# ── Configure Pipeline ──────────────────────────────────────────────

CAPTURE_DEV=$(media-ctl -d "$MEDIA_DEV" --print-topology 2>/dev/null \
    | grep -A3 "Intel IPU6 ISYS Capture 0" \
    | grep -o "/dev/video[0-9]*" | head -1) || true

if [ -z "$CAPTURE_DEV" ]; then
    die "Could not find capture device"
fi
log "Capture device: $CAPTURE_DEV"

media-ctl -d "$MEDIA_DEV" -V '"Intel IPU6 CSI2 0":0 [fmt:SGRBG10_1X10/1920x1080]'
media-ctl -d "$MEDIA_DEV" -V '"Intel IPU6 CSI2 0":1 [fmt:SGRBG10_1X10/1920x1080]'
media-ctl -d "$MEDIA_DEV" -l '"Intel IPU6 CSI2 0":1 -> "Intel IPU6 ISYS Capture 0":0[1]' 2>/dev/null
v4l2-ctl -d "$CAPTURE_DEV" --set-fmt-video=width=1920,height=1080,pixelformat=BA10

log "Pipeline configured"

# ── v4l2loopback ────────────────────────────────────────────────────
# Loaded once per boot (/etc/modules-load.d) with its options from /etc/modprobe.d, both written by
# `gc2607-setup-service.sh loopback`, and kept across service restarts so the camera node PipeWire
# already has survives them; only after boot does WirePlumber need a restart (gc2607-restart-wireplumber.sh).

modprobe v4l2loopback
if [ "$(cat /sys/class/video4linux/video50/name 2>/dev/null)" != "GC2607 Camera" ]; then
    die "/dev/video50 is not the GC2607 loopback: run 'sudo ./gc2607-setup-service.sh loopback', then reboot or unload v4l2loopback"
fi
log "v4l2loopback ready on /dev/video50"

# ── Start C ISP (or fallback to Python virtualcam) ─────────────────

log "Starting ISP (capture=$CAPTURE_DEV output=/dev/video50)..."
if [ -x "${SCRIPT_DIR}/gc2607_isp" ]; then
    exec "${SCRIPT_DIR}/gc2607_isp" "$CAPTURE_DEV" /dev/video50
else
    # Fallback to Python virtualcam
    log "gc2607_isp not found, falling back to Python virtualcam"
    if [ -f "${SCRIPT_DIR}/.python-path" ]; then
        PYTHON="$(cat "${SCRIPT_DIR}/.python-path")"
    else
        PYTHON="python3"
    fi
    exec "$PYTHON" "${SCRIPT_DIR}/gc2607_virtualcam.py" "$CAPTURE_DEV" /dev/video50
fi
