#!/usr/bin/env bash
#
# gc2607-suspend-hibernate.sh {status|install [DELAY]|uninstall|test}
#   Configure suspend-then-hibernate so an UNPLUGGED suspend rolls to 0 W hibernate after DELAY (default
#   90min) instead of bleeding ~2.2 W forever. ~2.2 W is this board's hard s2idle floor: the Meteor Lake
#   IOE-die / Thunderbolt (TCSS) power-gating never completes so S0ix is unreachable — proven by
#   gc2607-suspend-{ab,ec-test,pmc-probe,ltr-test,crashfix-test}.sh (5 software levers eliminated incl. the
#   silent-freeze fix, which is exonerated). Since deep S3 is gone on MTL, hibernate (S4) is the only escape.
#
# COVERAGE (from this machine's inhibitor map, 2026-06-25):
#   - Close lid on battery -> logind -> suspend-then-hibernate  ✓  (the "left it suspended unplugged" case)
#   - Close lid on AC      -> logind -> plain suspend           (kept; it's plugged in, no drain concern)
#   - Idle 15 min / power-menu "Suspend" -> GNOME calls plain Suspend(), bypassing s-t-h  ✗  (see NOTE)
#   NOTE: GNOME has no native suspend-then-hibernate action, so its idle/menu suspends stay plain. To also
#   cover idle, either lower GNOME's idle drain risk (Settings > Power) or suspend via the LID. The lid
#   path covers the overnight-unplugged scenario, which is the actual problem.
#
# WHAT IT WRITES (additive drop-ins; uninstall = delete them; main confs untouched):
#   /etc/systemd/sleep.conf.d/90-gc2607-hibernate.conf   -> [Sleep] HibernateDelaySec=DELAY
#   /etc/systemd/logind.conf.d/90-gc2607-hibernate.conf  -> [Login] HandleLidSwitch=suspend-then-hibernate
#                                                                    HandleLidSwitchExternalPower=suspend
#   sleep.conf takes effect on the NEXT suspend (read at sleep time). The logind lid change needs a
#   `systemctl restart systemd-logind` (sessions survive it on systemd>=255) OR a reboot — install prints this.
#
# PRECHECK: hibernate must be available + swap >= RAM. install WARNS (does not block — user said "assume it
#   works, will verify"). Verify once with:  sudo bash THIS test   (it hibernates now; power on to confirm).
#
set -e
CMD="${1:-status}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLEEP_D=/etc/systemd/sleep.conf.d/90-gc2607-hibernate.conf
LOGIN_D=/etc/systemd/logind.conf.d/90-gc2607-hibernate.conf
HOOK_SRC="$SCRIPT_DIR/gc2607-resume"
HOOK_DST=/usr/lib/systemd/system-sleep/gc2607-resume

need_root(){ [ "$(id -u)" -eq 0 ] || { echo "Needs root: sudo bash $0 $*"; exit 1; }; }
ram_kb(){ awk '/MemTotal/{print $2}' /proc/meminfo; }
swap_kb(){ awk 'NR>1 && $2=="file"||$2=="partition"{s+=$3} END{print s+0}' /proc/swaps; }
diskswap_kb(){ awk 'NR>1 && $2=="file"{s+=$3} END{print s+0}' /proc/swaps; }  # zram can't hold a hibernate image

precheck(){
  echo "--- hibernate readiness ---"
  echo "  /sys/power/state : $(cat /sys/power/state 2>/dev/null)   (must contain 'disk')"
  echo "  /sys/power/disk  : $(cat /sys/power/disk 2>/dev/null)"
  echo "  resume cmdline   : $(grep -o 'resume=[^ ]*' /proc/cmdline) $(grep -o 'resume_offset=[^ ]*' /proc/cmdline)"
  local r d; r=$(ram_kb); d=$(diskswap_kb)
  awk -v r="$r" -v d="$d" 'BEGIN{printf "  RAM %.1f GiB  vs  disk-swap %.1f GiB  -> %s\n", r/1048576, d/1048576, (d>=r?"image fits OK":"TOO SMALL (image may not fit!)")}'
  grep -qi 'disk' /sys/power/state 2>/dev/null || echo "  !! 'disk' not in /sys/power/state — hibernate UNAVAILABLE (kernel lockdown / Secure Boot?)."
}

case "$CMD" in
  status)
    echo "===== gc2607 suspend-then-hibernate status ====="
    precheck
    echo "--- installed? ---"
    for f in "$SLEEP_D" "$LOGIN_D"; do [ -f "$f" ] && { echo "  PRESENT $f"; sed 's/^/      /' "$f"; } || echo "  absent  $f"; done
    echo "--- effective HibernateDelaySec ---"
    systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | grep -iE 'HibernateDelaySec' | grep -v '^#' || echo "  (battery-estimated default)"
    echo "--- lid handling (logind, live) ---"
    for p in HandleLidSwitch HandleLidSwitchExternalPower; do
      printf '  %s = %s\n' "$p" "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$p" 2>/dev/null | awk '{print $2}')"
    done
    echo "--- GNOME idle policy (its idle/menu suspends stay PLAIN — see NOTE in header) ---"
    sudo -u "${SUDO_USER:-$USER}" gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 2>/dev/null | sed 's/^/  battery idle action: /'
    ;;

  install)
    need_root "$@"
    DELAY="${2:-90min}"
    precheck
    echo
    mkdir -p "$(dirname "$SLEEP_D")" "$(dirname "$LOGIN_D")"
    cat > "$SLEEP_D" <<EOF
# gc2607: roll an unplugged suspend into 0 W hibernate after this long in s2idle.
# Rationale: MTL IOE/Thunderbolt S0ix is unreachable here (~2.2 W floor) — see gc2607-suspend-* tools.
[Sleep]
HibernateDelaySec=$DELAY
EOF
    cat > "$LOGIN_D" <<EOF
# gc2607: lid-close on battery -> suspend-then-hibernate (covers the overnight-unplugged case).
# Lid-close on AC stays plain suspend (plugged in, no drain concern).
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend
EOF
    echo "wrote:"
    echo "  $SLEEP_D   (HibernateDelaySec=$DELAY)"
    echo "  $LOGIN_D   (HandleLidSwitch=suspend-then-hibernate)"
    echo
    echo "ACTIVATE the lid change (sleep.conf is already live on next suspend):"
    echo "    sudo systemctl restart systemd-logind     # sessions survive on systemd>=255; or just reboot"
    echo
    echo "Then test the WHOLE chain WITHOUT waiting 90 min — unplug and run:"
    echo "    sudo bash $0 test                          # verifies hibernate resumes"
    echo "    sudo systemctl suspend-then-hibernate      # uses the $DELAY delay; or close the lid"
    ;;

  uninstall)
    need_root "$@"
    rm -fv "$SLEEP_D" "$LOGIN_D"
    echo "removed drop-ins. Run: sudo systemctl restart systemd-logind   (or reboot) to revert lid handling."
    ;;

  test)
    need_root "$@"
    echo "This HIBERNATES the machine NOW (full power-off; RAM written to swap). Save your work."
    echo "After it powers off, press POWER to resume and confirm your session returns intact."
    read -r -p "Hibernate now? [y/N] " a; [ "$a" = y ] || { echo "aborted."; exit 0; }
    systemctl hibernate
    ;;

  diag)
    # Root-only ground truth for hibernate health. Read-only; NEVER sleeps.
    need_root "$@"
    echo "===== gc2607 hibernate DIAG (read-only) ====="
    precheck
    echo "--- drop-ins (as root) ---"
    for f in "$SLEEP_D" "$LOGIN_D"; do [ -f "$f" ] && { echo "  PRESENT $f"; sed 's/^/      /' "$f"; } || echo "  MISSING $f"; done
    echo "--- effective [Sleep] config systemd will use at hibernate time ---"
    systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | grep -iE 'HibernateDelaySec|HibernateMode|HibernateState' | grep -v '^#' || echo "  (none set -> battery-estimated delay: may never fire on this ~2.2 W board)"
    echo "--- resume hook installed? ---"
    if [ -f "$HOOK_DST" ]; then
      cmp -s "$HOOK_SRC" "$HOOK_DST" 2>/dev/null && echo "  UP-TO-DATE $HOOK_DST" || echo "  STALE      $HOOK_DST  (differs from repo gc2607-resume — run: repair)"
    else echo "  MISSING    $HOOK_DST  (camera won't restart on resume — run: repair)"; fi
    echo "--- swap headroom: does the image fit RIGHT NOW? ---"
    awk 'NR>1 && $1 !~ /zram/ {free += $3 - $4} END{printf "  disk-swap free: %.1f GiB\n", free/1048576}' /proc/swaps
    awk -v img="$(cat /sys/power/image_size 2>/dev/null)" 'BEGIN{printf "  image_size cap: %.1f GiB (kernel shrinks image toward this; must fit disk-swap free)\n", img/1073741824}'
    echo "  swapfile nocow (needs 'C'): $(lsattr /var/swap/swapfile 2>/dev/null | awk '{print $1}')"
    echo "--- last hibernate attempt outcome (journal) ---"
    journalctl -k --grep 'hibernation|No space left|Image not found' -o short-iso 2>/dev/null | tail -4 || true
    ;;

  repair)
    # Live-safe: rewrites config + installs the hardened hook. Triggers NO sleep,
    # restarts NO daemon (logind lid routing is read live; sleep.conf is read at
    # sleep time). Fixes: (1) hibernate not firing [HibernateDelaySec], (2) resume
    # wedge [hardened hook], (3) ENOSPC best-effort [hook caps image_size]. The
    # swapfile enlargement + the one real hibernate test stay manual (safe window).
    need_root "$@"
    DELAY="${2:-90min}"
    [ -f "$HOOK_SRC" ] || { echo "!! hook source missing: $HOOK_SRC"; exit 1; }
    mkdir -p "$(dirname "$SLEEP_D")" "$(dirname "$LOGIN_D")"
    cat > "$SLEEP_D" <<EOF
# gc2607: roll an unplugged suspend into 0 W hibernate after this long in s2idle.
# A FIXED delay — without it, systemd battery-estimates and on this ~2.2 W board
# may never hibernate (observed 2026-07-01: sat in s2idle 3 h, never fired).
[Sleep]
HibernateDelaySec=$DELAY
EOF
    cat > "$LOGIN_D" <<EOF
# gc2607: lid-close on battery -> suspend-then-hibernate; on AC -> plain suspend.
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend
EOF
    install -m 0755 "$HOOK_SRC" "$HOOK_DST"
    echo "repaired:"
    echo "  $SLEEP_D            (HibernateDelaySec=$DELAY)"
    echo "  $LOGIN_D            (lid routing)"
    echo "  $HOOK_DST   (image_size ENOSPC guard + gated camera restart)"
    echo
    echo "No sleep was triggered and no daemon was restarted."
    echo "Verify config now:   sudo bash $0 diag"
    echo
    echo "STILL NEEDED at a SAFE window (jobs stopped, on AC — NOT now):"
    echo "  1. Enlarge /var/swap/swapfile so the ~12 GiB image always fits even after"
    echo "     long uptime (the hook's image_size cap is only best-effort). Needs a"
    echo "     swapoff/recreate — unsafe under memory pressure."
    echo "  2. One real cycle:   sudo bash $0 test   (hibernates now; power on to confirm)."
    echo "  3. Docker/runc can refuse to freeze (stuck container exec / CIFS mount) and"
    echo "     stall suspend 20 s — stop heavy containers before a lid-close hibernate."
    ;;

  *) echo "usage: sudo bash $0 {status|diag|install [DELAY]|repair [DELAY]|uninstall|test}"; exit 2 ;;
esac
