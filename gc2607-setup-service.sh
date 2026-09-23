#!/bin/bash
# Install and enable the GC2607 camera systemd service.
# Usage: sudo ./gc2607-setup-service.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/gc2607"

# `unit`: install gc2607-camera.service only and reload systemd. The running service is not
# restarted; the new unit applies from its next start.
if [ "${1:-}" = unit ]; then
    install -m 0644 "${SCRIPT_DIR}/gc2607-camera.service" /etc/systemd/system/gc2607-camera.service
    systemctl daemon-reload
    echo "Installed gc2607-camera.service (effective from the next start)."
    exit 0
fi
USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
USER_HOME=$(getent passwd "$USER" | cut -d: -f6)

# Find python3 with required packages (used as fallback if C ISP not available)
find_python() {
    for p in /usr/bin/python3 /usr/local/bin/python3; do
        if "$p" -c "import numpy, pyfakewebcam" 2>/dev/null; then
            echo "$p"; return
        fi
    done
    for p in "${USER_HOME}/miniconda3/bin/python3" "${USER_HOME}/.conda/bin/python3" "${USER_HOME}/.local/bin/python3"; do
        if [ -x "$p" ] && "$p" -c "import numpy, pyfakewebcam" 2>/dev/null; then
            echo "$p"; return
        fi
    done
    echo "python3"
}
PYTHON="$(find_python)"
echo "User: ${USER}"

echo "=== Installing GC2607 Camera Service ==="

# Stop existing instances
echo "Stopping any running instances..."
systemctl stop gc2607-camera.service 2>/dev/null || true
kill $(pgrep -f gc2607_isp) 2>/dev/null || true
kill $(pgrep -f gc2607_virtualcam) 2>/dev/null || true
sleep 1

# Build the C ISP if not already built
if [ ! -f "${SCRIPT_DIR}/gc2607_isp" ]; then
    echo "Building gc2607_isp..."
    if command -v gcc &>/dev/null; then
        gcc -O2 -Wall -march=native -o "${SCRIPT_DIR}/gc2607_isp" "${SCRIPT_DIR}/gc2607_isp.c" -lm
    else
        echo "Warning: gcc not found, will use Python virtualcam fallback"
    fi
fi

# Copy scripts and binary to /opt where systemd can access them
echo "Installing to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
cp "${SCRIPT_DIR}/gc2607_virtualcam.py" "$INSTALL_DIR/"
cp "${SCRIPT_DIR}/gc2607-service.sh" "$INSTALL_DIR/"
cp "${SCRIPT_DIR}/gc2607-restart-wireplumber.sh" "$INSTALL_DIR/"
[ -f "${SCRIPT_DIR}/gc2607_isp" ] && cp "${SCRIPT_DIR}/gc2607_isp" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/*.sh "$INSTALL_DIR"/*.py
[ -f "$INSTALL_DIR/gc2607_isp" ] && chmod +x "$INSTALL_DIR/gc2607_isp"

# Update service script to use /opt paths
sed -i "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"${INSTALL_DIR}\"|" "$INSTALL_DIR/gc2607-service.sh"

# Save the detected Python path so the service can find it at boot
echo "$PYTHON" > "$INSTALL_DIR/.python-path"
echo "Saved Python path: ${PYTHON}"

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

# Install systemd service
echo "Installing systemd service..."
install -m 0644 "${SCRIPT_DIR}/gc2607-camera.service" /etc/systemd/system/gc2607-camera.service
[Unit]
Description=GC2607 Camera Virtual Webcam
After=multi-user.target graphical.target
Wants=multi-user.target
Conflicts=sleep.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/gc2607-service.sh
ExecStartPost=${INSTALL_DIR}/gc2607-restart-wireplumber.sh
Restart=on-abnormal
RestartSec=5
TimeoutStopSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable gc2607-camera.service

# Start now
echo "Starting service..."
systemctl start gc2607-camera.service
sleep 8

# Manually restart wireplumber now (service ExecStartPost may still be waiting)
su - "$USER" -c "systemctl --user restart wireplumber" 2>/dev/null || true
sleep 2

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
