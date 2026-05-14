#!/bin/bash
#
# Capture frames through libcamera's simple pipeline + soft IPA, for
# comparison against our hand-rolled gc2607_isp.c daemon.
#
# Stops the gc2607-camera.service first (it holds /dev/video0; libcamera
# needs exclusive access through the same path), runs `cam` for a few
# frames, then restarts the service.
#
# Usage: sudo /home/ff235/dev/gc2607-v4l2-driver/gc2607-libcamera-snap.sh
#

set -euo pipefail

OUT_DIR="/tmp/libcamera-snap"
USER_HOME="$(getent passwd "${SUDO_USER:-ff235}" | cut -d: -f6)"
RUN_AS_USER="${SUDO_USER:-ff235}"
NFRAMES=60

log() { echo "[libcamera-snap] $*"; }

log "stopping gc2607-camera.service to release /dev/video0..."
systemctl stop gc2607-camera.service || true
sleep 1

mkdir -p "$OUT_DIR"
chown "$RUN_AS_USER" "$OUT_DIR"
rm -f "$OUT_DIR"/frame-*.ppm "$OUT_DIR"/cam.log

log "running cam (capturing $NFRAMES frames; AGC settles in the last few)..."
# Run as the regular user (cam binds to seat session for libcamera).
# Camera index 1 (per `cam --list`); PPM output is RGB and viewable.
sudo -u "$RUN_AS_USER" timeout 15 cam -c 1 \
    -o rot180 \
    "-C${NFRAMES}" \
    "-F${OUT_DIR}/frame-#.ppm" \
    > "${OUT_DIR}/cam.log" 2>&1 || true

log "captured frames:"
ls -la "$OUT_DIR"/frame-*.ppm 2>&1 | tail -5 || log "no frames captured"

log "last 5 lines of cam log:"
tail -5 "${OUT_DIR}/cam.log" 2>&1 || true

log "restarting gc2607-camera.service..."
systemctl start gc2607-camera.service
sleep 2
systemctl is-active --quiet gc2607-camera.service \
    && log "service: active" \
    || log "service: NOT ACTIVE"

log "output dir: $OUT_DIR"
