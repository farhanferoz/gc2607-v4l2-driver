#!/bin/bash
#
# Install the locally-built gc2607_isp into /opt/gc2607/, restart the
# service, verify it came up. Used by the dev loop. Requires sudo (covered
# by /etc/sudoers.d/gc2607-dev installed via setup-sudo.sh).
#
set -eu

SRC="/home/ff235/dev/gc2607-v4l2-driver/gc2607_isp"
DST="/opt/gc2607/gc2607_isp"
BAK="${DST}.bak"

if [ ! -x "$SRC" ]; then
    echo "Source binary not found: $SRC — run 'make isp' first" >&2
    exit 1
fi

cp -a "$DST" "$BAK"
install -m 0755 "$SRC" "$DST"
systemctl restart gc2607-camera.service
sleep 2

if systemctl is-active --quiet gc2607-camera.service; then
    echo "[install-isp] OK: $(stat -c '%y %s' $DST)"
    exit 0
fi

echo "[install-isp] FAILED — rolling back to $BAK" >&2
journalctl -u gc2607-camera.service --no-pager -n 30 >&2
install -m 0755 "$BAK" "$DST"
systemctl restart gc2607-camera.service
exit 1
