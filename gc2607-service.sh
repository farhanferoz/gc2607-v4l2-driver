#!/bin/bash
#
# GC2607 Camera Service Script
# Called by systemd gc2607-camera.service at boot.
# Sets up the pipeline and v4l2loopback, then runs the ISP (or the Python fallback).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[gc2607] $*"; }
die() { echo "[gc2607] ERROR: $*" >&2; exit 1; }

# ── Load Modules ────────────────────────────────────────────────────

log "Loading kernel modules..."
for mod in videodev v4l2-async ipu_bridge intel-ipu6 intel-ipu6-isys; do
    modprobe "$mod" 2>/dev/null || true
done
# Built for each kernel by DKMS; /etc/modules-load.d/gc2607.conf normally loads it at boot already.
modprobe gc2607 || die "the gc2607 module would not load (check: dkms status | grep gc2607)"

# ── Find and Configure the Pipeline ─────────────────────────────────

# shellcheck source=gc2607-media.sh
source "${SCRIPT_DIR}/gc2607-media.sh"
media_discover 20 || die "no GC2607 pipeline in the media graph after 20 s"
log "Sensor '$SENSOR' on $MEDIA_DEV -> '$CSI' -> '$CAPTURE' ($CAPTURE_DEV)"
media_configure || die "could not configure the pipeline"
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
