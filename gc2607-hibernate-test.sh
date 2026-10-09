#!/usr/bin/env bash
#
# gc2607-hibernate-test.sh {step1|step2-prep|step2-run|step3-shutdown|cleanup|status}
#   Automate the root-cause test plan for the hibernate resume hang (2026-09-22).
#   Documented in: docs/hibernate-resume-root-cause-test.md
#
# SUBCOMMANDS:
#   step1           Execute Step 1: in-kernel test_resume (no power-cycle, ~15-30s).
#                   Isolates whether the kernel/driver restore path works.
#   step2-prep      Prepare Step 2: enable hibernate drop-ins, set no_console_suspend
#                   via grubby, and prompt for reboot.
#   step2-run [ac|battery]  Execute Step 2: re-apply debug switches and run systemctl hibernate.
#                   `battery` requires the charger OUT (2026-10-09: every cold resume on AC worked,
#                   both on battery hung; every earlier test had run on AC only).
#   step3-shutdown  Force HibernateMode=shutdown (bypasses firmware S4).
#   probe [ARGS]    Read-only: gc2607-hib-image-probe.py as root (ARGS: releases/strings to find, --all).
#   cleanup         Revert grubby console args, remove sleep overrides, unpause Docker.
#   status          Read-only check of power, resume targets, and debug switches.
#
# SAFETY:
#   - NEVER restart systemd-logind on a live desktop.
#   - Docker containers are paused during direct sysfs writes and unpaused after.
#   - Refuses to run if AC power is disconnected.
#

set -euo pipefail

CMD="${1:-status}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHUTDOWN_CONF="/etc/systemd/sleep.conf.d/96-gc2607-hibernate-shutdown-mode.conf"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root: sudo bash $0 $*" >&2
    exit 1
  fi
}

check_ac() {
  local ac_online=0
  for f in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online; do
    if [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "1" ]; then
      ac_online=1
      break
    fi
  done
  if [ "$ac_online" -ne 1 ]; then
    echo "ERROR: Laptop is not plugged into AC power. Plug in AC before testing." >&2
    exit 1
  fi
}

check_on_battery() {
  local f
  for f in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online; do
    if [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "1" ]; then
      echo "ERROR: the charger is connected. Unplug it for the battery test." >&2
      exit 1
    fi
  done
}

check_resume_targets() {
  local r ro
  r="$(cat /sys/power/resume 2>/dev/null || true)"
  ro="$(cat /sys/power/resume_offset 2>/dev/null || true)"
  echo "Resume target: /sys/power/resume=$r, /sys/power/resume_offset=$ro"
  if [ "$r" != "259:8" ] || [ "$ro" != "22100502" ]; then
    echo "WARNING: Resume target ($r:$ro) differs from expected (259:8:22100502)." >&2
  fi
}

arm_debug_switches() {
  echo "Arming verbose kernel power management debug switches..."
  echo 0 > /sys/power/pm_async
  echo 1 > /sys/power/pm_print_times
  echo 1 > /sys/power/pm_debug_messages
  dmesg -n 8
  echo "  pm_async=0, pm_print_times=1, pm_debug_messages=1, dmesg -n 8 armed."
}

pause_docker() {
  if command -v docker >/dev/null 2>&1; then
    local running
    running="$(docker ps -q --filter status=running 2>/dev/null || true)"
    if [ -n "$running" ]; then
      echo "Pausing running Docker containers..."
      echo "$running" | xargs -r docker pause || true
    fi
  fi
}

unpause_docker() {
  if command -v docker >/dev/null 2>&1; then
    local paused
    paused="$(docker ps -q --filter status=paused 2>/dev/null || true)"
    if [ -n "$paused" ]; then
      echo "Unpausing Docker containers..."
      echo "$paused" | xargs -r docker unpause || true
    fi
  fi
}

case "$CMD" in
  status)
    echo "=== Hibernate Test Readiness Status ==="
    check_resume_targets
    echo "AC Power: $(cat /sys/class/power_supply/AC*/online 2>/dev/null || echo unknown)"
    echo "/sys/power/disk: $(cat /sys/power/disk 2>/dev/null || echo missing)"
    echo "pm_async: $(cat /sys/power/pm_async 2>/dev/null || echo missing)"
    echo "pm_print_times: $(cat /sys/power/pm_print_times 2>/dev/null || echo missing)"
    echo "pm_debug_messages: $(cat /sys/power/pm_debug_messages 2>/dev/null || echo missing)"
    # The kernel that LOADS the image is a fresh boot running only the initramfs: settings applied
    # later in boot (sysctl.d, gc2607-nvme-aspm.service) do not reach it unless the initramfs has them.
    echo "--- image-loading kernel (initramfs of $(uname -r)) ---"
    echo "panic= on cmdline: $(grep -oE '(^| )panic=[0-9]+' /proc/cmdline || echo 'none -> CONFIG_PANIC_TIMEOUT')  ($(grep -h '^CONFIG_PANIC_TIMEOUT' "/boot/config-$(uname -r)"))"
    if [ "$(id -u)" -eq 0 ] && command -v lsinitrd >/dev/null 2>&1; then
      INITRD_LIST=$(lsinitrd "/boot/initramfs-$(uname -r).img" 2>&1)
      echo "  listing: $(wc -l <<< "$INITRD_LIST") lines"
      # usr/lib/systemd/systemd is a CONTROL: it must read present, or the listing itself failed. Match with
      # a here-string: piping into grep -q made printf take SIGPIPE, and pipefail turned every hit ABSENT.
      for f in usr/lib/systemd/systemd etc/sysctl.d/99-crash-debug.conf usr/lib/systemd/systemd-sysctl etc/udev/rules.d/05-gc2607-sn740-aspm.rules usr/bin/sh usr/bin/cat; do
        printf '  %-40s %s\n' "$f" "$(grep -qE " $f( -> .*)?\$" <<< "$INITRD_LIST" && echo present || echo ABSENT)"
      done
    else
      echo "  (run as root to list the initramfs)"
    fi
    if command -v docker >/dev/null 2>&1; then
      echo "Docker containers:"
      docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
    fi
    ;;

  step1)
    need_root "$@"
    check_ac
    check_resume_targets

    echo
    echo "=== STEP 1: Kernel-Only Restore (test_resume) ==="
    echo "This test writes the hibernate image to swap and restores from it immediately"
    echo "without powering off or going through firmware. It will freeze for ~15-30s."
    echo
    read -r -p "Press Enter to proceed with Step 1 (or Ctrl+C to cancel)..."

    pause_docker
    arm_debug_switches

    echo "Setting /sys/power/disk to test_resume..."
    echo test_resume > /sys/power/disk

    echo "Triggering test_resume via /sys/power/state disk..."
    echo disk > /sys/power/state

    echo
    echo "Session resumed successfully!"
    unpause_docker

    echo
    echo "------------------------------------------------------------------------"
    echo "RESULT: Step 1 PASSED."
    echo "The kernel and driver restore path is working properly."
    echo "The freeze fault lies in the cold-boot path (firmware re-init or initrd)."
    echo "Next: run 'sudo bash $0 step2-prep' to set up Step 2 (cold boot test)."
    echo "------------------------------------------------------------------------"
    ;;

  step2-prep)
    need_root "$@"
    check_ac
    echo "=== Preparing Step 2: Real Cold-Boot Resume ==="

    echo "1. Re-enabling hibernate drop-ins via gc2607-suspend-hibernate.sh enable..."
    bash "$SCRIPT_DIR/gc2607-suspend-hibernate.sh" enable

    echo "2. Setting kernel console visibility arguments via grubby..."
    grubby --update-kernel=ALL --remove-args="rhgb quiet" --args="no_console_suspend"

    echo
    echo "Step 2 preparation complete."
    echo "Please REBOOT now so the kernel picks up the boot parameters."
    echo "After rebooting, run: sudo bash $0 step2-run"
    ;;

  step2-run)
    need_root "$@"
    if [ "${2:-ac}" = battery ]; then check_on_battery; else check_ac; fi
    logger -t gc2607-hibernate-test "step2-run power=${2:-ac} disk_mode=$(cat /sys/power/disk)"
    check_resume_targets
    arm_debug_switches

    echo "=== Executing Step 2: Real Hibernate Cycle ==="
    echo "The laptop will now hibernate and power completely off."
    echo "After it powers off, press the power button to wake it."
    echo "  - If it resumes: repeat 2-3 more times to confirm."
    echo "  - If it hangs: take a photo of the screen, hold the power button,"
    echo "    and run 'sudo python3 gc2607-hib-image-probe.py' on reboot."
    echo
    read -r -p "Press Enter to hibernate now (or Ctrl+C to abort)..."
    systemctl hibernate
    ;;

  step3-shutdown)
    need_root "$@"
    echo "=== Step 3: Forcing HibernateMode=shutdown (Bypassing ACPI S4) ==="
    mkdir -p /etc/systemd/sleep.conf.d
    printf '[Sleep]\nHibernateMode=shutdown\n' > "$SHUTDOWN_CONF"
    echo "Created $SHUTDOWN_CONF"
    echo "Now test with: sudo bash $0 step2-run"
    ;;

  probe)
    need_root "$@"
    shift
    exec python3 -I "$(dirname "$(readlink -f "$0")")/gc2607-hib-image-probe.py" "$@"
    ;;

  cleanup)
    need_root "$@"
    echo "=== Cleaning Up Test Configurations ==="
    echo "Restoring default GRUB arguments (rhgb quiet)..."
    grubby --update-kernel=ALL --remove-args="no_console_suspend" --args="rhgb quiet" 2>/dev/null || true

    if [ -f "$SHUTDOWN_CONF" ]; then
      echo "Removing $SHUTDOWN_CONF..."
      rm -f "$SHUTDOWN_CONF"
    fi

    unpause_docker
    # Hibernate stays OFF unless the owner turns it on (workspace-sync D134); step2-prep turned it on.
    echo "Turning hibernate back OFF (lid -> plain suspend); turn on deliberately with: gc2607-suspend-hibernate.sh enable"
    bash "$SCRIPT_DIR/gc2607-suspend-hibernate.sh" disable
    echo "Cleanup complete."
    ;;

  *)
    echo "Usage: sudo bash $0 {step1|step2-prep|step2-run|step3-shutdown|probe|cleanup|status}" >&2
    exit 2
    ;;
esac
