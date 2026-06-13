#!/bin/bash
#
# Grants scoped passwordless sudo for gc2607 camera development.
# Only allows specific commands needed for driver testing.
#
# Usage:
#   sudo ./setup-sudo.sh          # install sudoers rules
#   sudo ./setup-sudo.sh remove   # remove sudoers rules
#

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/gc2607-dev"
TARGET_USER="${SUDO_USER:-$USER}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

if [ "${1:-}" = "remove" ]; then
    rm -f "$SUDOERS_FILE"
    echo "Removed ${SUDOERS_FILE}"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cat > "$SUDOERS_FILE" << EOF
# gc2607 camera driver development - scoped sudo access
# Remove with: sudo rm ${SUDOERS_FILE}

# Driver scripts
${TARGET_USER} ALL=(ALL) NOPASSWD: ${SCRIPT_DIR}/gc2607-*.sh

# Module management
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/modprobe *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/rmmod *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/insmod *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/depmod *

# Diagnostics
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/dmesg *

# Media tools
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/media-ctl *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/v4l2-ctl *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/v4l2-ctl *
EOF

chmod 440 "$SUDOERS_FILE"

if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
    echo "Installed ${SUDOERS_FILE} for user '${TARGET_USER}'"
    echo "Remove with: sudo $0 remove"
else
    rm -f "$SUDOERS_FILE"
    echo "Syntax error in sudoers file, removed." >&2
    exit 1
fi
