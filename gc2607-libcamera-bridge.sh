#!/bin/bash
#
# libcamera → /dev/video51 bridge using PipeWire + GStreamer.
#
# Lets V4L2-only apps (Chrome, Meet, Zoom, OBS) test libcamera's soft IPA
# output by exposing it as a second virtual camera alongside our daemon's
# /dev/video50.
#
# First run patches the camera service script to load v4l2loopback with
# two devices, then restarts the service. Subsequent runs just start
# the gstreamer pipeline.
#
# Usage:
#   sudo gc2607-libcamera-bridge.sh start   # patch + start bridge
#   sudo gc2607-libcamera-bridge.sh stop    # stop bridge (leaves /dev/video51)
#   sudo gc2607-libcamera-bridge.sh status  # show bridge state
#

set -euo pipefail

SERVICE_SH="/opt/gc2607/gc2607-service.sh"
PIDFILE="/run/gc2607-libcamera-bridge.pid"
LOGFILE="/var/log/gc2607-libcamera-bridge.log"

log() { echo "[bridge] $*"; }
die() { echo "[bridge] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

patch_service_script_if_needed() {
    if grep -q 'devices=2' "$SERVICE_SH" 2>/dev/null; then
        log "service script already configured for 2 loopback devices"
        return 0
    fi

    log "patching $SERVICE_SH to expose /dev/video50 + /dev/video51..."
    cp -f "$SERVICE_SH" "${SERVICE_SH}.pre-libcamera-bridge.bak"

    # Replace the devices=1 / video_nr=50 / card_label block with a
    # two-device variant. Keep exclusive_caps and max_buffers unchanged
    # (those are scalars that apply to all devices when single-valued).
    sed -i \
        -e 's|devices=1|devices=2|' \
        -e 's|video_nr=50|video_nr=50,51|' \
        -e 's|card_label="GC2607 Camera"|card_label="GC2607 Camera","GC2607 libcamera"|' \
        -e 's|v4l2loopback loaded on /dev/video50|v4l2loopback loaded on /dev/video50 + /dev/video51|' \
        "$SERVICE_SH"

    log "restarting gc2607-camera.service to apply..."
    systemctl restart gc2607-camera.service
    sleep 3
    systemctl is-active --quiet gc2607-camera.service \
        || die "service failed to restart after patch (backup at ${SERVICE_SH}.pre-libcamera-bridge.bak)"
}

resolve_libcamera_node_name() {
    # PipeWire is a per-user daemon; pw-dump must run as the seat user
    # to connect to its socket.
    local invoker="${SUDO_USER:-ff235}"
    local uid
    uid="$(id -u "$invoker")"
    sudo -u "$invoker" \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        PIPEWIRE_RUNTIME_DIR="/run/user/$uid" \
        pw-dump 2>/dev/null | python3 -c "
import json, sys
for o in json.load(sys.stdin):
    if o.get('type') != 'PipeWire:Interface:Node': continue
    p = o.get('info', {}).get('props', {})
    if 'libcamera' in p.get('node.name', ''):
        print(p['node.name'])
        break
"
}

start_bridge() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        log "bridge already running (pid $(cat "$PIDFILE"))"
        return 0
    fi

    patch_service_script_if_needed

    if [ ! -e /dev/video51 ]; then
        die "/dev/video51 not present after service restart (loopback config didn't take?)"
    fi

    local node
    node="$(resolve_libcamera_node_name)"
    [ -n "$node" ] || die "could not find libcamera node in pipewire"
    log "libcamera node: $node"

    # gst-launch as the invoking user (libcamera/pipewire bind to seat
    # session). videoconvert + caps coerce libcamera's output (likely
    # YUV420 or RGB888) into YUY2 which v4l2sink and downstream apps
    # handle well.
    local invoker="${SUDO_USER:-ff235}"
    local uid
    uid="$(id -u "$invoker")"
    # pipewiresrc inherits whatever resolution PipeWire's libcamera node
    # offers (currently 640x480; raising it is upstream configuration
    # work in libcamera, not in this script). videoflip handles the 180°
    # rotation from the upside-down sensor mount.
    log "starting gstreamer pipeline as $invoker..."
    sudo -u "$invoker" env \
        "XDG_RUNTIME_DIR=/run/user/$uid" \
        "PIPEWIRE_RUNTIME_DIR=/run/user/$uid" \
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
        gst-launch-1.0 \
            pipewiresrc "target-object=$node" \
            ! videoconvert \
            ! videoflip method=rotate-180 \
            ! videoconvert \
            ! "video/x-raw,format=YUY2" \
            ! v4l2sink device=/dev/video51 sync=false \
        > "$LOGFILE" 2>&1 &

    local pid=$!
    echo "$pid" > "$PIDFILE"
    sleep 2

    if ! kill -0 "$pid" 2>/dev/null; then
        log "gstreamer died immediately; last log lines:"
        tail -10 "$LOGFILE" 2>&1 || true
        rm -f "$PIDFILE"
        die "bridge failed to start"
    fi

    log "OK: bridge running pid=$pid → /dev/video51"
    log "test with: pick 'GC2607 libcamera' in any V4L2 app (Chrome/Meet/OBS)"
    log "stop with: sudo $0 stop"
}

stop_bridge() {
    if [ ! -f "$PIDFILE" ]; then
        log "no pidfile; nothing to stop"
        return 0
    fi
    local pid
    pid="$(cat "$PIDFILE")"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" || true
        log "stopped pid=$pid"
    else
        log "pid $pid not running"
    fi
    rm -f "$PIDFILE"
}

status_bridge() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "bridge: running (pid $(cat "$PIDFILE"))"
    else
        echo "bridge: stopped"
    fi
    [ -e /dev/video51 ] && echo "/dev/video51: present" || echo "/dev/video51: missing (service restart needed)"
    echo "log: $LOGFILE"
}

case "${1:-start}" in
    start) start_bridge ;;
    stop)  stop_bridge ;;
    status) status_bridge ;;
    *) die "usage: $0 {start|stop|status}" ;;
esac
