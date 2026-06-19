#!/usr/bin/env bash
#
# gc2607-nvme-aspm.sh - disable/enable PCIe ASPM L1 for the WD SN740 (15b7:5017) ONLY.
#
# TESTS the documented SN740 "ASPM L1 -> full silent freeze (no AER), minutes-to-days"
# bug (esc.sh; LKML SN740 ASPM L1 quirk). Per-drive: WiFi etc. keep ASPM. This is the
# proper test the old `pcie_aspm=off` never did (that does NOT clear BIOS-enabled L1.2).
#
#   status     - show the drive's ASPM substate + link + nvme state
#   off        - disable L1 ASPM for the drive NOW (runtime, reversible)
#   on         - re-enable (revert)
#   install    - persist `off` across boots (systemd oneshot)
#   uninstall  - remove the persistence
#
set -u
VEN=0x15b7; DEVID=0x5017
PCI=/sys/bus/pci/devices
SVC=/etc/systemd/system/gc2607-nvme-aspm.service
SELF=$(readlink -f "$0")

find_dev() {
  local d
  for d in "$PCI"/*/; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = "$VEN" ] && [ "$(cat "$d/device" 2>/dev/null)" = "$DEVID" ] \
      && { basename "$d"; return; }
  done
}
DEV=$(find_dev)

status() {
  echo "SN740 device : ${DEV:-NOT FOUND}"
  [ -n "$DEV" ] || return
  local f v
  for f in l1_aspm l1_1_aspm l1_2_aspm l1_1_pcipm l1_2_pcipm; do
    v=$(cat "$PCI/$DEV/link/$f" 2>/dev/null); [ -n "$v" ] && printf "  link/%-11s = %s\n" "$f" "$v"
  done
  echo "  link         = $(cat "$PCI/$DEV/current_link_speed" 2>/dev/null) x$(cat "$PCI/$DEV/current_link_width" 2>/dev/null)"
  echo "  nvme state   = $(cat /sys/class/nvme/nvme0/state 2>/dev/null)"
  echo "  persisted    = $(systemctl is-enabled gc2607-nvme-aspm.service 2>/dev/null || echo no)"
}

need_root() { [ "$(id -u)" -eq 0 ] || exec sudo "$SELF" "$@"; }

set_l1() {  # $1 = 0 (off) | 1 (on)
  [ -n "$DEV" ] || { echo "SN740 (15b7:5017) not found"; exit 1; }
  echo "$1" > "$PCI/$DEV/link/l1_aspm" \
    && echo "l1_aspm -> $(cat "$PCI/$DEV/link/l1_aspm") on $DEV"
}

case "${1:-status}" in
  status) status ;;
  off) need_root off; DEV=$(find_dev); set_l1 0; echo; status ;;
  on)  need_root on;  DEV=$(find_dev); set_l1 1; echo; status ;;
  install) need_root install
    # systemd can't exec a script from /home under SELinux (203/EXEC) -> install a
    # system-context helper in /usr/local/sbin and point the service at that.
    cat > /usr/local/sbin/gc2607-aspm-off <<'HELP'
#!/bin/bash
# disable PCIe ASPM L1 on the WD SN740 (15b7:5017) only
for d in /sys/bus/pci/devices/*/; do
  [ "$(cat "$d/vendor" 2>/dev/null)" = 0x15b7 ] && [ "$(cat "$d/device" 2>/dev/null)" = 0x5017 ] \
    && echo 0 > "$d/link/l1_aspm" 2>/dev/null
done
exit 0
HELP
    chmod +x /usr/local/sbin/gc2607-aspm-off
    command -v restorecon >/dev/null 2>&1 && restorecon -F /usr/local/sbin/gc2607-aspm-off 2>/dev/null
    cat > "$SVC" <<'SVCEOF'
[Unit]
Description=gc2607 - disable PCIe ASPM L1 on the WD SN740 (silent-freeze ASPM test)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gc2607-aspm-off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload; systemctl reset-failed gc2607-nvme-aspm.service 2>/dev/null
    systemctl enable --now gc2607-nvme-aspm.service \
      && echo "installed + enabled via /usr/local/sbin/gc2607-aspm-off (ASPM L1 stays OFF across boots)" \
      || echo "FAILED - run: systemctl status gc2607-nvme-aspm.service" ;;
  uninstall) need_root uninstall
    systemctl disable --now gc2607-nvme-aspm.service 2>/dev/null
    rm -f "$SVC" /usr/local/sbin/gc2607-aspm-off; systemctl daemon-reload
    echo "persistence removed (run 'on' to re-enable ASPM now)" ;;
  *) echo "usage: $0 {status|off|on|install|uninstall}"; exit 2 ;;
esac
