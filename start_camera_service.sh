#!/bin/bash
#
# Camera recovery script. Run when /dev/video50 is missing or apps don't see
# "GC2607 Camera". Idempotent — safe to run repeatedly.
#
#   sudo ./start_camera_service.sh
#
# What it does, in order:
#   1. Diagnose the current state (service / module / device).
#   2. Stop anything stuck and clear failures.
#   3. Reset v4l2loopback if /dev/video50 is missing.
#   4. Start gc2607-camera.service.
#   5. Verify /dev/video50 is alive and ISP is streaming.
#   6. Restart wireplumber so PipeWire/Cheese/Chrome see the new device.
#

set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[*]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*" >&2; }

SERVICE=gc2607-camera.service

# ── 1. Diagnose ─────────────────────────────────────────────────────
info "Current state:"
echo "    service:       $(systemctl is-active $SERVICE 2>/dev/null) / $(systemctl is-failed $SERVICE 2>/dev/null)"
echo "    gc2607 module: $(grep -q '^gc2607 ' /proc/modules && echo loaded || echo NOT-loaded)"
echo "    v4l2loopback:  $(grep -q '^v4l2loopback ' /proc/modules && echo loaded || echo NOT-loaded)"
echo "    /dev/video50:  $([ -e /dev/video50 ] && echo present || echo MISSING)"
echo "    /dev/video0:   $([ -e /dev/video0 ] && echo present || echo MISSING)"

# ── 2. Stop cleanly ─────────────────────────────────────────────────
if systemctl is-active --quiet "$SERVICE"; then
    info "Stopping $SERVICE..."
    systemctl stop "$SERVICE" || true
fi
systemctl reset-failed "$SERVICE" 2>/dev/null || true

# Cancel any stuck pending start jobs
if systemctl list-jobs --no-legend 2>/dev/null | grep -q "$SERVICE"; then
    warn "Pending job for $SERVICE — cancelling"
    systemctl cancel "$SERVICE" 2>/dev/null || true
fi

# Make sure no stray gc2607_isp is hanging around
pkill -f /opt/gc2607/gc2607_isp 2>/dev/null || true
sleep 1

# ── 3. Reset v4l2loopback if device is missing ──────────────────────
if [ ! -e /dev/video50 ] && grep -q '^v4l2loopback ' /proc/modules; then
    info "v4l2loopback loaded but /dev/video50 missing — reloading module"
    modprobe -r v4l2loopback 2>/dev/null || warn "rmmod v4l2loopback failed (something is holding it)"
fi

# ── 4. Start service ────────────────────────────────────────────────
info "Starting $SERVICE..."
if ! systemctl start "$SERVICE"; then
    error "systemctl start failed"
    journalctl -u "$SERVICE" --no-pager -n 30
    exit 1
fi

# ── 5. Verify ───────────────────────────────────────────────────────
info "Waiting for /dev/video50..."
for i in $(seq 1 15); do
    [ -e /dev/video50 ] && break
    sleep 1
done

if [ ! -e /dev/video50 ]; then
    error "/dev/video50 never appeared after 15s. Recent service logs:"
    journalctl -u "$SERVICE" --no-pager -n 30
    exit 1
fi

if ! systemctl is-active --quiet "$SERVICE"; then
    error "Service did not become active. Logs:"
    journalctl -u "$SERVICE" --no-pager -n 30
    exit 1
fi

# Confirm gc2607_isp is the main process
isp_pid=$(systemctl show -p MainPID --value "$SERVICE")
if [ "$isp_pid" = "0" ] || ! kill -0 "$isp_pid" 2>/dev/null; then
    error "gc2607_isp main process is not alive (PID=$isp_pid)"
    journalctl -u "$SERVICE" --no-pager -n 30
    exit 1
fi

# ── 6. Restart wireplumber for the desktop user ─────────────────────
info "Restarting wireplumber so apps see the new camera..."
desktop_user="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [ -n "$desktop_user" ] && [ "$desktop_user" != "root" ]; then
    uid=$(id -u "$desktop_user" 2>/dev/null || true)
    if [ -n "$uid" ] && [ -S "/run/user/$uid/bus" ]; then
        sudo -u "$desktop_user" \
            XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            systemctl --user restart wireplumber 2>/dev/null \
            && info "wireplumber restarted for $desktop_user" \
            || warn "wireplumber restart failed (you may need to log out/in)"
    else
        warn "No user session bus found at /run/user/$uid/bus"
    fi
else
    warn "Could not determine desktop user — skipping wireplumber restart"
fi

echo
info "Camera ready:"
echo "    service:      $(systemctl is-active $SERVICE) (PID $isp_pid)"
echo "    /dev/video50: present"
echo "    Open Cheese / Chrome / OBS and pick \"GC2607 Camera\"."
