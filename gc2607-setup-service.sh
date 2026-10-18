#!/bin/bash
# Install and enable the GC2607 camera systemd service.
# Usage: sudo ./gc2607-setup-service.sh [unit|scripts|loopback]   (no argument: full install)

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/gc2607"

# `unit`: install gc2607-camera.service only and reload systemd. The running service is not
# restarted; the new unit applies from its next start.
install_unit() {
    install -m 0644 "${SCRIPT_DIR}/gc2607-camera.service" /etc/systemd/system/gc2607-camera.service
    systemctl daemon-reload
}

# `scripts`: copy the service's scripts to /opt/gc2607, with gc2607-service.sh pointed at it. They apply
# from the next service start (the ISP binary has its own installer, gc2607-install-isp.sh).
install_scripts() {
    mkdir -p "$INSTALL_DIR"
    install -m 0755 "${SCRIPT_DIR}/gc2607-service.sh" "${SCRIPT_DIR}/gc2607-media.sh" \
        "${SCRIPT_DIR}/gc2607-restart-wireplumber.sh" "$INSTALL_DIR/"
    rm -f "$INSTALL_DIR/gc2607_virtualcam.py" "$INSTALL_DIR/.python-path"   # retired Python fallback
    sed -i "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"${INSTALL_DIR}\"|" "$INSTALL_DIR/gc2607-service.sh"
}

# `loopback`: have v4l2loopback loaded once at boot with the camera's options, so gc2607-service.sh
# keeps the module across restarts instead of reloading it. A module already loaded is left alone.
install_loopback() {
    printf '# Written by gc2607-setup-service.sh loopback.\n%s\n' \
        'options v4l2loopback devices=1 video_nr=50 card_label="GC2607 Camera" exclusive_caps=1 max_buffers=2' \
        > /etc/modprobe.d/gc2607-v4l2loopback.conf
    printf '# Written by gc2607-setup-service.sh loopback.\nv4l2loopback\n' > /etc/modules-load.d/gc2607-v4l2loopback.conf
    modprobe v4l2loopback
    echo "Installed v4l2loopback options and boot load; /dev/video50 is '$(cat /sys/class/video4linux/video50/name 2>/dev/null)'."
}

case "${1:-}" in
    unit) install_unit; echo "Installed gc2607-camera.service (effective from the next start)."; exit 0 ;;
    scripts) install_scripts; echo "Installed the service scripts to ${INSTALL_DIR} (effective from the next start)."; exit 0 ;;
    loopback) install_loopback; exit 0 ;;
    "") ;;
    *) echo "Usage: sudo $0 [unit|scripts|loopback]" >&2; exit 1 ;;
esac

USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
USER_HOME=$(getent passwd "$USER" | cut -d: -f6)

echo "User: ${USER}"
# Built as the user, not here: a root-owned build in the synced tree breaks Syncthing on other machines.
[ -x "${SCRIPT_DIR}/gc2607_isp" ] || { echo "Build the ISP first, as yourself: make isp" >&2; exit 1; }

echo "=== Installing GC2607 Camera Service ==="

# Stop existing instances
echo "Stopping any running instances..."
systemctl stop gc2607-camera.service 2>/dev/null || true
kill $(pgrep -f gc2607_isp) 2>/dev/null || true
sleep 1


# Copy scripts and binary to /opt where systemd can access them
echo "Installing to ${INSTALL_DIR}..."
install_scripts
install -m 0755 "${SCRIPT_DIR}/gc2607_isp" "$INSTALL_DIR/"

# Install wireplumber config to hide raw IPU6 nodes
echo "Installing wireplumber config..."
WPDIR="${USER_HOME}/.config/wireplumber/wireplumber.conf.d"
mkdir -p "$WPDIR"
cat > "$WPDIR/50-hide-ipu6-raw.conf" << 'EOF'
# Hide the IPU6 raw V4L2 capture nodes (they are not usable cameras).
#
# MEASURED 2026-09-18: doing this at DEVICE level (device.disabled = true) breaks
# ALL audio under wireplumber 0.5.17 -- every ALSA node comes up with no ports, so
# nothing links and both capture and playback hang with no error. Disabling the
# NODE leaves device enumeration intact.
monitor.v4l2.rules = [
  {
    matches = [
      {
        node.name = "~v4l2_input.pci-.*"
      }
    ]
    actions = {
      update-props = {
        node.disabled = true
      }
    }
  }
]
EOF
chown -R "${USER}:${USER}" "${USER_HOME}/.config/wireplumber"

install_loopback

# Install systemd service
echo "Installing systemd service..."
install_unit
systemctl enable gc2607-camera.service

# Start now; the start job includes ExecStartPost, which restarts WirePlumber if it misses the camera.
echo "Starting service..."
systemctl start gc2607-camera.service

# Check status
if systemctl is-active --quiet gc2607-camera.service; then
    echo ""
    echo "=== Camera service is running ==="
    echo "Open your camera app — select 'GC2607 Camera'"
    echo ""
    echo "Commands:"
    echo "  sudo systemctl status gc2607-camera.service   # check status"
    echo "  sudo systemctl restart gc2607-camera.service   # restart"
    echo "  sudo systemctl stop gc2607-camera.service      # stop"
    echo "  journalctl -u gc2607-camera.service            # view logs"
else
    echo ""
    echo "=== Service failed to start ==="
    echo "Check logs: journalctl -u gc2607-camera.service -n 30"
fi
