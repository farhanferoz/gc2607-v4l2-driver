#!/bin/bash
# Install ONLY the system-sleep hook (gc2607-resume), nothing else; `repair` also rewrites sleep/lid config.
set -eu
[ "$(id -u)" -eq 0 ] || exec sudo -n "$0" "$@"
install -m 0755 "$(dirname "$(readlink -f "$0")")/gc2607-resume" /usr/lib/systemd/system-sleep/gc2607-resume
echo "installed /usr/lib/systemd/system-sleep/gc2607-resume"
