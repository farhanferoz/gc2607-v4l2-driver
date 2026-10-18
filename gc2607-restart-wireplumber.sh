#!/bin/bash
# ExecStartPost of gc2607-camera.service: restart the desktop user's WirePlumber only when it does not
# list the virtual camera, since a restart cuts audio for a moment.
#
# WirePlumber decides whether /dev/video50 is a camera when it first sees it, and v4l2loopback
# (exclusive_caps=1) announces capture only while the ISP holds its output. Measured 2026-10-18: a
# WirePlumber started while the ISP was down never listed the camera, and at boot WirePlumber starts
# first (09:06:39 vs 09:06:54), so boot needs the restart; across service restarts, with v4l2loopback
# kept loaded, the camera node survived (3 of 3), so those need none.

log() { echo "[gc2607-wireplumber] $*"; }

# Wait (up to 15 s) until the ISP holds the output and the device announces capture.
for _ in $(seq 30); do
    v4l2-ctl -d /dev/video50 --info 2>/dev/null | grep -A1 'Device Caps' | grep -q 'Video Capture' && break
    sleep 0.5
done

# The logged-in desktop user
USER=$(logname 2>/dev/null || who | grep -m1 'tty\|:0' | awk '{print $1}') || true
if [ -z "$USER" ]; then
    USER=$(ls -1 /run/user/ 2>/dev/null | head -1 | xargs -I{} getent passwd {} | cut -d: -f1) || true
fi
if ! UID_NUM=$(id -u "$USER" 2>/dev/null) || [ ! -S "/run/user/${UID_NUM}/bus" ]; then
    log "no user session yet: its WirePlumber will find the camera when it starts"
    exit 0
fi
as_user() {
    runuser -u "$USER" -- env XDG_RUNTIME_DIR="/run/user/${UID_NUM}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" "$@"
}

if as_user pw-cli ls Node 2>/dev/null | grep -qF 'node.name = "v4l2_input._sys_devices_virtual_video4linux_video50"'; then
    log "WirePlumber already lists the camera; not restarting it"
elif as_user systemctl --user restart wireplumber; then
    log "WirePlumber did not list the camera; restarted it"
else
    log "WirePlumber did not list the camera and restarting it FAILED"
fi
exit 0
