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
#   - Close lid on AC      -> logind -> suspend-then-hibernate with HibernateOnACPower=no: stays suspended
#     while plugged in, hibernates DELAY after being unplugged. It was plain suspend until 2026-09-25, and
#     closing the lid on AC then unplugging drained 80% -> 42% over one night (systemd v259 sleep.c
#     custom_timer_suspend re-arms the deadline on every wake that finds AC, so the delay counts from unplug).
#   - Idle 15 min / power-menu "Suspend" -> GNOME calls plain Suspend(), bypassing s-t-h  ✗  (see NOTE)
#   NOTE: GNOME has no native suspend-then-hibernate action, so its idle/menu suspends stay plain. To also
#   cover idle, either lower GNOME's idle drain risk (Settings > Power) or suspend via the LID. The lid
#   path covers the overnight-unplugged scenario, which is the actual problem.
#
# WHAT IT WRITES (additive drop-ins; uninstall = delete them; main confs untouched):
#   /etc/systemd/sleep.conf.d/90-gc2607-hibernate.conf   -> [Sleep] HibernateDelaySec=DELAY
#                                                                    HibernateOnACPower=no
#   /etc/systemd/logind.conf.d/90-gc2607-hibernate.conf  -> [Login] HandleLidSwitch=suspend-then-hibernate
#                                                                    HandleLidSwitchExternalPower=suspend-then-hibernate
#   sleep.conf takes effect on the NEXT suspend (read at sleep time). The logind lid change goes live with
#   `systemctl reload systemd-logind`, which install/repair run: a SIGHUP to the SAME process, which only
#   re-parses logind.conf (v259 logind.c manager_dispatch_reload_signal; SIGHUP reload since systemd 230).
#   This header used to say the lid change needed a REBOOT; none came, so the 2026-09-23 install never took
#   effect and lid-close stayed plain suspend until 2026-09-25.
#   NEVER `systemctl RESTART systemd-logind` on a live GNOME session: gnome-shell loses control of every
#   input device ("NotInControl") and the only way out is a forced power-off. Happened 2026-06-25 and again
#   2026-09-22 08:40:46, the second time because this header used to claim sessions survive it.
#
# disable / enable (added 2026-09-22): RESUME from hibernate is unreliable on this machine. 2026-09-21 the
#   image was written completely (chain walked, 91,123 chunks framed OK, header marked) and the machine
#   powered off; the morning resume hung and needed a power-button hold. 2026-09-11 a resumed session died
#   64 s later. `disable` turns hibernate off at the source (logind then reports CanHibernate=no, so
#   suspend-then-hibernate and hybrid-sleep go too) and makes UPower power off cleanly at critical battery
#   instead of calling logind Sleep(), which would otherwise fall back to a plain suspend that runs the
#   battery flat. `enable` deletes both files.
#   2026-10-09: `disable` also sets the lid to plain `suspend` and `enable` restores suspend-then-hibernate.
#   logind.conf(5) documents no fallback when the configured lid action is unavailable, so the lid must not
#   be left pointing at an action AllowHibernation=no forbids. Resume record by then: 2026-09-11 and
#   10-08/10-09 died ~1-2 min after resume ("Unknown NMI after S4 resume", LKML 2024-07, made fatal by
#   kernel.unknown_nmi_panic=1 in /etc/sysctl.d/99-crash-debug.conf); 09-21 and 10-09 19:51 never resumed.
#   The hibernate self-test (workspace-sync monitoring/agents/laptop/hibernate_selftest.sh) runs a
#   ROOT-OWNED COPY of this script at /usr/local/sbin; after changing disable/enable, re-run
#   install_hibernate_selftest.sh or the self-test keeps using the old copy.
#
# PRECHECK: hibernate must be available + swap >= RAM. install WARNS (does not block — user said "assume it
#   works, will verify"). Verify once with:  sudo bash THIS test   (it hibernates now; power on to confirm).
#
set -e
CMD="${1:-status}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLEEP_D=/etc/systemd/sleep.conf.d/90-gc2607-hibernate.conf
LOGIN_D=/etc/systemd/logind.conf.d/90-gc2607-hibernate.conf
NOHIB_D=/etc/systemd/sleep.conf.d/95-gc2607-no-hibernate.conf
UPOWER_D=/etc/UPower/UPower.conf.d/90-gc2607-critical-poweroff.conf
HOOK_SRC="$SCRIPT_DIR/gc2607-resume"
HOOK_DST=/usr/lib/systemd/system-sleep/gc2607-resume

need_root(){ [ "$(id -u)" -eq 0 ] || { echo "Needs root: sudo bash $0 $*"; exit 1; }; }
ram_kb(){ awk '/MemTotal/{print $2}' /proc/meminfo; }
swap_kb(){ awk 'NR>1 && $2=="file"||$2=="partition"{s+=$3} END{print s+0}' /proc/swaps; }
diskswap_kb(){ awk 'NR>1 && $2=="file"{s+=$3} END{print s+0}' /proc/swaps; }  # zram can't hold a hibernate image

# write_lid_conf [ACTION]: writes the logind lid drop-in (default suspend-then-hibernate) and makes it
# live. reload = SIGHUP, never restart (header).
write_lid_conf(){
  local action="${1:-suspend-then-hibernate}"
  cat > "$LOGIN_D" <<EOF
# gc2607: lid-close -> $action, on battery AND on AC. suspend-then-hibernate stays suspended on AC
# (HibernateOnACPower=no in sleep.conf.d) and hibernates HibernateDelaySec after being unplugged;
# plain suspend is what \`disable\` writes (header).
[Login]
HandleLidSwitch=$action
HandleLidSwitchExternalPower=$action
EOF
  systemctl reload systemd-logind
  local p
  for p in HandleLidSwitch HandleLidSwitchExternalPower; do
    printf '  live %s = %s\n' "$p" "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$p" | awk '{print $2}')"
  done
}

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
HibernateOnACPower=no
EOF
    write_lid_conf
    echo "wrote and made live:"
    echo "  $SLEEP_D   (HibernateDelaySec=$DELAY, HibernateOnACPower=no)"
    echo "  $LOGIN_D   (lid -> suspend-then-hibernate on battery and AC; logind reloaded, not restarted)"
    echo
    echo "Then test the WHOLE chain WITHOUT waiting 90 min — unplug and run:"
    echo "    sudo bash $0 test                          # verifies hibernate resumes"
    echo "    sudo systemctl suspend-then-hibernate      # uses the $DELAY delay; or close the lid"
    ;;

  uninstall)
    need_root "$@"
    rm -fv "$SLEEP_D" "$LOGIN_D"
    systemctl reload systemd-logind
    echo "removed drop-ins; logind reloaded (not restarted), lid handling back to the default."
    ;;

  disable)
    need_root "$@"
    mkdir -p "$(dirname "$NOHIB_D")" "$(dirname "$UPOWER_D")"
    cat > "$NOHIB_D" <<EOF
# gc2607: hibernate OFF. Resume from S4 hung 2026-09-22 after a complete image write; see header of
# gc2607-suspend-hibernate.sh. AllowHibernation=no also implies no suspend-then-hibernate / hybrid-sleep.
[Sleep]
AllowHibernation=no
EOF
    cat > "$UPOWER_D" <<EOF
# gc2607: with hibernate off, CriticalPowerAction=Auto resolves to logind Sleep() -> plain suspend,
# which would drain the battery flat in s2idle (~2.2 W). Power off cleanly instead.
[UPower]
CriticalPowerAction=PowerOff
EOF
    echo "wrote $NOHIB_D and $UPOWER_D"
    write_lid_conf suspend
    echo "logind: live now (verify: busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate)."
    echo "upower: verify after the next reboot with GetCriticalAction == PowerOff (not restarted here on purpose)."
    ;;

  enable)
    need_root "$@"
    rm -fv "$NOHIB_D" "$UPOWER_D"
    write_lid_conf suspend-then-hibernate
    ;;

  selftest-install)
    # Installs the automatic hibernate resume self-test (header of the installer below). It lives in
    # workspace-sync; this is the laptop's sudo-able entry point for hibernate management.
    need_root "$@"
    exec bash /home/ff235/dev/workspace-sync/monitoring/agents/laptop/install_hibernate_selftest.sh
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
    systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | grep -iE 'HibernateDelaySec|HibernateOnACPower|HibernateMode|HibernateState' | grep -v '^#' || echo "  (none set -> battery-estimated delay: may never fire on this ~2.2 W board)"
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
    # restarts NO daemon (logind is RELOADED, which is SIGHUP to the same process;
    # sleep.conf is read at sleep time). Fixes: (1) hibernate not firing [HibernateDelaySec], (2) resume
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
HibernateOnACPower=no
EOF
    write_lid_conf
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

  *) echo "usage: sudo bash $0 {status|diag|install [DELAY]|repair [DELAY]|uninstall|disable|enable|test|selftest-install}"; exit 2 ;;
esac
