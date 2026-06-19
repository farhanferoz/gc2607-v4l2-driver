#!/usr/bin/env bash
#
# gc2607-cstate-clear.sh - retire the Phase-1b 'test1b' C-state experiment and
# return all 22 cores to stock deep sleep, leaving the SN740 ASPM-L1 freeze fix
# as the ONLY active mitigation (clean single variable for the ongoing soak).
#
# WHY: the SN740 ASPM-L1 fix (gc2607-nvme-aspm) has held ~69 h clean on 7.0.12
#   (vs 1.5-7.5 h without it). test1b (holding LP-E cores 20/21 out of C6) was
#   FALSIFIED by crash #18 -- the crash run held them out perfectly and still
#   froze, and a 64 h survivor let them sleep 616x -- so it is dead weight.
#
# WHAT (one-shot, idempotent, reversible):
#   1. log a timestamped BASELINE-CHANGE marker to the journal -> NAS stream
#      (so a post-change freeze is diagnosable: when the baseline moved);
#   2. deploy the updated tool to /usr/local/sbin (SELinux bin_t via restorecon);
#   3. gc2607-cstate-test.sh 'stock' -> re-enable C6/C10 on ALL cores, marker=off;
#   4. systemctl disable --now the boot service so test1b never re-applies;
#   5. VERIFY cpu20/21 are deep-sleeping again, and the capture stack is armed.
#
# REVERSE: re-running test1b is `sudo /usr/local/sbin/gc2607-cstate-test.sh test1b`
#   then `sudo systemctl enable gc2607-cstate-test` + set /etc/gc2607-cstate-mode.
#   Emergency global C6-off (unrelated bail): `... gc2607-cstate-test.sh protect-now`.
#
# JOB INTERFERENCE: none. Only writes cpuidle 'disable' files for cpu20/21 and
#   disables a Type=oneshot service. No camera / telemetry / XPU / drive impact.
#   The SN740 ASPM-L1 fix and all freeze watchers are left untouched.
#
# Usage: sudo /home/ff235/dev/gc2607-v4l2-driver/gc2607-cstate-clear.sh
#
set -u
REPO=/home/ff235/dev/gc2607-v4l2-driver
TOOL_SRC="$REPO/gc2607-cstate-test.sh"
TOOL_DST=/usr/local/sbin/gc2607-cstate-test.sh
SVC=gc2607-cstate-test.service
TAG=gc2607-cstate-test
USER_NAME=ff235
RUN_USER() { sudo -u "$USER_NAME" -H XDG_RUNTIME_DIR=/run/user/1000 "$@"; }
NAS_LOG="/share/homes/$USER_NAME/freeze-capture/$(hostname)-journal-$(date +%F).log"

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
say() { printf '\n=== %s ===\n' "$*"; }

say "BEFORE (cpu20/21 held out of C6 by test1b)"
for c in 20 21; do printf 'cpu%s: C6 disable=%s C10 disable=%s\n' "$c" \
  "$(cat /sys/devices/system/cpu/cpu$c/cpuidle/state2/disable)" \
  "$(cat /sys/devices/system/cpu/cpu$c/cpuidle/state3/disable)"; done
b20=$(cat /sys/devices/system/cpu/cpu20/cpuidle/state2/usage 2>/dev/null || echo 0)
b21=$(cat /sys/devices/system/cpu/cpu21/cpuidle/state2/usage 2>/dev/null || echo 0)

logger -t "$TAG" "BASELINE-CHANGE start $(date -Is): retiring test1b -> re-enabling C6/C10 on cpu20/21 (full deep sleep on ALL 22 cores); SN740 ASPM-L1 fix STAYS active; disabling $SVC. Diagnose a future freeze via telemetry 'c6cores' (now should include 20,21) + link-telem drive-vs-CPU."

say "DEPLOY updated tool -> $TOOL_DST"
install -m 0755 "$TOOL_SRC" "$TOOL_DST" && echo "installed"
command -v restorecon >/dev/null && restorecon -v "$TOOL_DST"

say "APPLY stock (full deep sleep + marker=off)"
"$TOOL_DST" stock | sed -n '1,3p;/cpu2[01]/p'

say "DISABLE boot service so test1b cannot re-apply next boot"
systemctl disable --now "$SVC" 2>&1 | sed 's/^/  /' || true
printf '  is-enabled=%s is-active=%s\n' "$(systemctl is-enabled $SVC 2>/dev/null)" "$(systemctl is-active $SVC 2>/dev/null)"

say "VERIFY cpu20/21 now deep-sleeping (3 s window)"
sleep 3
for c in 20 21; do printf 'cpu%s: C6 disable=%s usage=%s | C10 disable=%s usage=%s\n' "$c" \
  "$(cat /sys/devices/system/cpu/cpu$c/cpuidle/state2/disable)" \
  "$(cat /sys/devices/system/cpu/cpu$c/cpuidle/state2/usage)" \
  "$(cat /sys/devices/system/cpu/cpu$c/cpuidle/state3/disable)" \
  "$(cat /sys/devices/system/cpu/cpu$c/cpuidle/state3/usage)"; done
a20=$(cat /sys/devices/system/cpu/cpu20/cpuidle/state2/usage 2>/dev/null || echo 0)
a21=$(cat /sys/devices/system/cpu/cpu21/cpuidle/state2/usage 2>/dev/null || echo 0)
echo "cpu20 C6 delta=$((a20-b20))  cpu21 C6 delta=$((a21-b21))   (>0 => deep sleep is active again)"

say "DIAGNOSTIC STACK must be armed to catch a post-change freeze"
printf 'SN740 l1_aspm = %s   (0 = ASPM-L1 freeze fix ACTIVE)\n' "$(cat /sys/bus/pci/devices/0000:01:00.0/link/l1_aspm)"
for u in gc2607-nvme-aspm gc2607-idle-cool; do printf 'system %-20s %s / %s\n' "$u" "$(systemctl is-active $u)" "$(systemctl is-enabled $u 2>/dev/null)"; done
for u in gc2607-telemetry gc2607-link-telem journal-capture-nas nvme-temp-watch; do
  printf 'user   %-20s %s\n' "$u" "$(RUN_USER systemctl --user is-active $u 2>/dev/null || echo '??')"; done

say "OFF-BOX capture reachable? (NAS journal log present + last line)"
RUN_USER ssh -o BatchMode=yes -o ConnectTimeout=10 nasff235 "ls -l '$NAS_LOG' && tail -1 '$NAS_LOG'" 2>&1 | tail -3 \
  || echo "WARN: ssh to NAS as $USER_NAME failed here -- check 'systemctl --user status journal-capture-nas' in the user session"

logger -t "$TAG" "BASELINE-CHANGE done $(date -Is): cpu20 C6 delta=$((a20-b20)) cpu21 delta=$((a21-b21)); $SVC disabled; marker=off; SN740 l1_aspm=$(cat /sys/bus/pci/devices/0000:01:00.0/link/l1_aspm). Baseline now = stock deep sleep + SN740 ASPM-L1 fix ONLY."

say "DONE"
echo "test1b retired; all 22 cores idle stock. Only active freeze fix = SN740 ASPM-L1 off."
echo "If it freezes after this: the NAS journal tail's last 'gc2607-telem ... c6cores=[...]' shows whether"
echo "cpu20/21 were sleeping at death; 'gc2607-link ...' shows drive-drop vs CPU-wedge; then run:"
echo "  sudo $REPO/gc2607-crash-triage.sh"
