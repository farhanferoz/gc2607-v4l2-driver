#!/usr/bin/env bash
#
# gc2607-sleep-postmortem.sh  — after a lid-close/sleep that ended in a COLD BOOT,
# answer the one question the journal cannot: did the last sleep FREEZE (wedged in
# s2idle, RAM lost, forced power-off) or DRAIN (battery to 0)?  Read-only. NEVER sleeps.
#
# WHY: 2026-07-02 a lid-close on AC ran PLAIN s2idle (HandleLidSwitchExternalPower=suspend,
# by design) and never resumed -> cold boot. The journal ends at "PM: suspend entry (s2idle)"
# for BOTH a freeze and a drain, so we need pstore/ramoops + the battery curve + ASPM/AER
# to tell them apart. The answer decides the fix (short hibernate delay / hibernate-direct
# if freeze; 90 min is fine if pure drain).
#
# USAGE:  sudo bash gc2607-sleep-postmortem.sh
#
set +e
h(){ printf '\n========== %s ==========\n' "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }
[ "$(id -u)" -eq 0 ] || { echo "Needs root (pstore, upower history, AER). Re-run: sudo bash $0"; exit 1; }

BAT=/sys/class/power_supply/BAT0

h "0. BOOT BOUNDARY (was the previous shutdown clean?)"
journalctl --list-boots -o short 2>/dev/null | tail -4
echo "-- previous boot (-1) last 3 lines before it went dark --"
journalctl -b -1 -o short-precise 2>/dev/null | tail -3
echo "-- this boot: unclean-shutdown / journal-corruption marker --"
journalctl -b 0 2>/dev/null | grep -iE 'corrupted or uncleanly|Image not found|hibernate' | head -4

h "1. FREEZE EVIDENCE — pstore / ramoops (a captured panic/oops => it crashed, not drained)"
echo "-- live /sys/fs/pstore --"
ls -la /sys/fs/pstore/ 2>&1
for f in /sys/fs/pstore/dmesg-* /sys/fs/pstore/console-*; do
  [ -f "$f" ] || continue
  echo "---- $f (head) ----"; head -40 "$f" 2>/dev/null
done
echo "-- persisted /var/lib/systemd/pstore --"
ls -la /var/lib/systemd/pstore/ 2>&1 | tail -15
echo "-- this morning's boot-incident triage capture --"
LATEST_TRIAGE=$(ls -1dt /var/log/gc2607-crash-triage/*/ 2>/dev/null | head -1)
echo "  latest: ${LATEST_TRIAGE:-none}"
[ -n "$LATEST_TRIAGE" ] && { ls -la "$LATEST_TRIAGE"; echo "---- contents ----"; sed 's/^/   /' "$LATEST_TRIAGE"*.txt 2>/dev/null | head -60; }

h "2. DRAIN EVIDENCE — was it on AC or battery overnight, and did charge collapse?"
echo "battery now : $(cat $BAT/status 2>/dev/null)  $(cat $BAT/capacity 2>/dev/null)%   energy_now=$(awk '{printf "%.1f", $1/1e6}' $BAT/energy_now 2>/dev/null)Wh / full=$(awk '{printf "%.1f", $1/1e6}' $BAT/energy_full 2>/dev/null)Wh"
echo "AC online now: $(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1)   (1=plugged)"
echo "charge cap  : end_threshold=$(cat $BAT/charge_control_end_threshold 2>/dev/null || echo n/a)  (Huawei 80% limit => 'Not charging' at 80 is normal)"
echo "-- upower CHARGE history, overnight window (ts -> BST, %, state) --"
for f in /var/lib/upower/history-charge-*.dat; do
  [ -f "$f" ] || continue
  echo "  [$f]"
  awk '{ printf "   %s  %5s%%  %s\n", strftime("%m-%d %H:%M:%S", $1), $2, $3 }' "$f" 2>/dev/null | tail -40
done
echo "-- upower RATE history (state charging/discharging tells us AC vs battery) --"
for f in /var/lib/upower/history-rate-*.dat; do
  [ -f "$f" ] || continue
  echo "  [$f]"
  awk '{ printf "   %s  %6sW  %s\n", strftime("%m-%d %H:%M:%S", $1), $2, $3 }' "$f" 2>/dev/null | tail -25
done

h "3. SILENT-FREEZE MITIGATION HEALTH (NVMe ASPM disable + AER)"
echo "gc2607-nvme-aspm.service : $(systemctl is-active gc2607-nvme-aspm 2>/dev/null)  ($(systemctl is-enabled gc2607-nvme-aspm 2>/dev/null))"
journalctl -u gc2607-nvme-aspm -b 0 -o short 2>/dev/null | tail -3
echo "-- NVMe link ASPM state (want L1 DISABLED on the SN740) --"
for d in /sys/bus/pci/devices/*; do
  cls=$(cat "$d/class" 2>/dev/null)
  [ "$cls" = "0x010802" ] || continue   # NVMe controller
  pci=$(basename "$d")
  echo "  $pci  $(lspci -s "${pci#0000:}" 2>/dev/null | cut -d: -f3-)"
  echo "     l1_aspm=$(cat "$d/link/l1_aspm" 2>/dev/null || echo n/a)  (0 = L1 ASPM disabled = the fix)"
  have lspci && lspci -vvs "${pci#0000:}" 2>/dev/null | grep -iE 'LnkCtl:|ASPM' | sed 's/^/     /'
done
echo "-- AER errors this boot (any => PCIe link trouble, the freeze fingerprint) --"
journalctl -k -b 0 2>/dev/null | grep -iE 'AER|corrected error|Malformed|pcie.*error' | tail -8 || echo "  (none this boot)"

h "4. CONFIG STATE (what lid-close will do next time)"
for p in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
  printf '  %s = %s\n' "$p" "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$p" 2>/dev/null | awk '{print $2}')"
done
echo "  HibernateDelaySec (effective): $(systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | grep -iE 'HibernateDelaySec' | grep -v '^#' | tail -1 || echo '(battery-estimated default — may never fire on the ~2.2W floor)')"
echo "  mem_sleep : $(cat /sys/power/mem_sleep 2>/dev/null)"

h "VERDICT HEURISTIC"
cat <<'EOF'
  * pstore/ramoops HAS a panic/oops (section 1)        -> FREEZE (crash captured).
  * pstore EMPTY but overnight state=discharging and
    charge% collapsed toward 0 (section 2)             -> DRAIN.
  * pstore EMPTY, overnight on AC / charge flat, cold
    boot anyway                                        -> FREEZE (silent wedge; NMI never fires,
                                                          empty pstore is EXPECTED for this class).
  * AER / NVMe ASPM not disabled (section 3)           -> ASPM-L1 freeze regression; re-check gc2607-nvme-aspm.
EOF
echo
echo "Read sections 1-3, then tell me which pattern matches — I'll pick the fix (delay length / hibernate-direct) from that."
