#!/bin/bash
# Install GC2607 HAL config files into the ipu6epmtl camera HAL directory.
# Requires: ipu6-camera-hal, ipu6-camera-bins, akmod-intel-ipu6, gstreamer1-plugins-icamerasrc
# NOTE: As of April 2026, the hardware ISP is BLOCKED (see docs/hardware_isp_investigation.md).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAL_DIR="/usr/share/defaults/etc/camera/ipu6epmtl"

echo "Installing GC2607 HAL config files..."

# Sensor XML
sudo cp "$SCRIPT_DIR/gc2607-uf.xml" "$HAL_DIR/sensors/"

# Graph settings from Windows
sudo cp "$SCRIPT_DIR/tuning/graph_settings_gc2607_gc2607_MTL.xml" "$HAL_DIR/gcss/"

# Tuning file from Windows
sudo cp "$SCRIPT_DIR/tuning/gc2607_gc2607_MTL.aiqb" "$HAL_DIR/"

# CPF calibration from Windows
sudo cp "$SCRIPT_DIR/tuning/gc2607_gc2607_MTL.cpf" "$HAL_DIR/"

# Add gc2607-uf-0 to available sensors in libcamhal_profile.xml
if ! grep -q "gc2607" "$HAL_DIR/libcamhal_profile.xml"; then
    sudo sed -i 's|external_source,ar0234_usb"/>|external_source,ar0234_usb,gc2607-uf-0"/>|' "$HAL_DIR/libcamhal_profile.xml"
    echo "Added gc2607-uf-0 to libcamhal_profile.xml"
else
    echo "gc2607 already in libcamhal_profile.xml"
fi

echo "Done. Files installed to $HAL_DIR"
echo "Verify: ls -la $HAL_DIR/*gc2607* $HAL_DIR/sensors/gc2607* $HAL_DIR/gcss/graph_settings_gc2607*"
