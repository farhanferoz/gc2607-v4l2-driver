#!/usr/bin/env bash
#
# gc2607-link-telem.sh - PCIe/NVMe link telemetry to DISCRIMINATE the silent-freeze
# leading edge. The open question: at the wedge, does the WD SN740 / PCIe link degrade
# FIRST (drive/ASPM story) or does the CPU wedge first (C6 story)? Our deaths are
# "disk-first" — the local journal stops ~25-30 s before the SoC fully wedges — so during
# that window the CPU + network are still alive and CAN ship the drive's link state
# off-box. This logs (tag gc2607-link, every INTERVAL s) onto the existing journal->NAS
# stream, so the last samples before the gap reveal which subsystem died first:
#   * AER counts tick / link speed|width drop / nvme state != live  -> DRIVE/PCIe (ASPM)
#   * link stays pristine and telemetry just stops                  -> CPU/SoC wedge (C6)
#
# Read-only sysfs; NO root (runs as a --user service like the other watchers).
#
INTERVAL="${1:-1}"
TAG=gc2607-link
DEV="${DEV:-0000:01:00.0}"      # WD SN740 (15b7:5017)
RP="${RP:-0000:00:06.0}"        # its PCIe root port
NVME="${NVME:-/sys/class/nvme/nvme0}"
PCI=/sys/bus/pci/devices

aer_sum() {  # $1=pci-addr $2=aer file -> summed count across all error types (0 if none)
  local s=0 name n
  [ -r "$PCI/$1/$2" ] || { echo 0; return; }
  while read -r name n; do case "$n" in ''|*[!0-9]*) ;; *) s=$((s+n));; esac; done < "$PCI/$1/$2"
  echo "$s"
}
spd() { local v; v=$(cat "$PCI/$1/current_link_speed" 2>/dev/null); echo "${v%% *}"; }
wid() { cat "$PCI/$1/current_link_width" 2>/dev/null; }

logger -t "$TAG" "started interval=${INTERVAL}s dev=$DEV rootport=$RP"
while :; do
  logger -t "$TAG" "nvme=$(cat "$NVME/state" 2>/dev/null || echo '?')" \
    "l1aspm=$(cat "$PCI/$DEV/link/l1_aspm" 2>/dev/null || echo '?')" \
    "dev_link=$(spd "$DEV")x$(wid "$DEV")" \
    "rp_link=$(spd "$RP")x$(wid "$RP")" \
    "aer_dev=c$(aer_sum "$DEV" aer_dev_correctable)/n$(aer_sum "$DEV" aer_dev_nonfatal)/f$(aer_sum "$DEV" aer_dev_fatal)" \
    "aer_rp=c$(aer_sum "$RP" aer_dev_correctable)/n$(aer_sum "$RP" aer_dev_nonfatal)/f$(aer_sum "$RP" aer_dev_fatal)"
  sleep "$INTERVAL"
done
