#!/bin/bash
# Install ONLY the boot-time triage trigger (gc2607-boot-incident.sh -> /usr/local/sbin), the copy
# gc2607-boot-incident.service runs. Sibling of gc2607-install-sleep-hook.sh, which installs only the sleep hook.
set -eu
[ "$(id -u)" -eq 0 ] || exec sudo -n "$0" "$@"
install -m 0755 "$(dirname "$(readlink -f "$0")")/gc2607-boot-incident.sh" /usr/local/sbin/gc2607-boot-incident.sh
echo "installed /usr/local/sbin/gc2607-boot-incident.sh"
