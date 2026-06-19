#!/bin/bash
#
# gc2607-recorder-test.sh - the keystone diagnostic: does the in-memory crash
# recorder's reserved RAM (ramoops/pstore) actually SURVIVE a reboot on THIS
# laptop? Every real silent-freeze has left pstore empty and we have never once
# confirmed the recorder works here (docs/incidents/2026-05-silent-freezes.md).
#
# Why it matters: a panic dump (dmesg-ramoops) needs the panic path to run - a
# total SoC wedge never gets there, so it can't help. But a *continuous* per-core
# ftrace-to-ramoops is written as code executes, so it can capture the last thing
# each core did even in a total wedge - PROVIDED the reserved RAM survives the
# reboot. This test validates exactly that prerequisite by forcing a known panic
# and checking whether the record is still there after the machine comes back.
#
#   status            - show recorder config + current pstore contents (safe)
#   crash --confirm   - pin GRUB default to the running kernel, write a marker,
#                       clear pstore for a clean baseline, sync, then DELIBERATELY
#                       PANIC (sysrq-c). Machine hard-reboots in ~10 s.
#                       *** KILLS EVERYTHING RUNNING, INCLUDING TRAINING ***
#   check             - after the reboot: did a record survive?  PASS / FAIL.
#
# Runs via the gc2607-*.sh sudo trampoline.
#
set -u
MODE="${1:-status}"
MARKER=/var/lib/gc2607/recorder-test.marker
PSTORE_LIVE=/sys/fs/pstore
PSTORE_ARCHIVE=/var/lib/systemd/pstore

if [ "$(id -u)" -ne 0 ]; then
    echo "re-exec as root via trampoline..." >&2
    exec sudo -n "$0" "$@"
fi

show_config() {
    echo "ramoops/panic cmdline:"
    tr ' ' '\n' < /proc/cmdline | grep -E 'ramoops|nmi_watchdog|^panic|watchdog_thresh' | sed 's/^/  /'
    echo "  kernel.panic          = $(sysctl -n kernel.panic 2>/dev/null)   (must be >0 to auto-reboot)"
    echo "  kernel.panic_on_oops  = $(sysctl -n kernel.panic_on_oops 2>/dev/null)"
    echo "  kernel.sysrq          = $(sysctl -n kernel.sysrq 2>/dev/null)   (need 1, or the 'c' bit)"
    echo "  kdump kexec_loaded    = $(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)   (MUST be 0 - kdump starves ramoops)"
    echo "  systemd-pstore        = $(systemctl is-enabled systemd-pstore 2>/dev/null)  (archives pstore at boot)"
    echo "  ftrace_size (per-core)= $(cat /sys/module/ramoops/parameters/ftrace_size 2>/dev/null)   (0/empty = continuous trace NOT yet on)"
}

list_records() {
    echo "  live  $PSTORE_LIVE:";    ls -1 "$PSTORE_LIVE" 2>/dev/null | sed 's/^/    /' | grep . || echo "    (empty)"
    echo "  saved $PSTORE_ARCHIVE:"; ls -1 "$PSTORE_ARCHIVE" 2>/dev/null | sed 's/^/    /' | grep . || echo "    (none)"
}

case "$MODE" in
  status)
    echo "=== recorder config ==="; show_config
    echo "=== current records ==="; list_records
    ;;

  crash)
    [ "${2:-}" = "--confirm" ] || {
        echo "REFUSING: 'crash' DELIBERATELY PANICS the machine (hard reboot, kills training)."
        echo "When ready:  sudo $0 crash --confirm"
        exit 2
    }
    # Preconditions
    [ "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)" = "0" ] || {
        echo "ABORT: kdump is loaded - it would steal the recorder. Disable kdump first."; exit 1; }
    [ "$(sysctl -n kernel.panic 2>/dev/null)" -gt 0 ] 2>/dev/null || sysctl -w kernel.panic=10 >/dev/null
    sysctl -w kernel.sysrq=1 >/dev/null

    # Reboot back into the SAME kernel we are testing (and finally pin the default).
    RK="/boot/vmlinuz-$(uname -r)"
    grubby --set-default="$RK" >/dev/null 2>&1 && echo "Pinned GRUB default -> $(basename "$RK")"

    mkdir -p "$(dirname "$MARKER")"
    {
        echo "armed_epoch=$(date +%s 2>/dev/null)"
        echo "armed_date=$(date 2>/dev/null)"
        echo "kernel=$(uname -r)"
        echo "uptime=$(cat /proc/uptime)"
        echo "pstore_before=$(ls -1 "$PSTORE_LIVE" 2>/dev/null | tr '\n' ',')"
    } > "$MARKER"

    rm -f "$PSTORE_LIVE"/* 2>/dev/null   # clean baseline: any record found later is ours
    sync; sync
    logger -t gc2607-recorder-test "ARMED: deliberate panic to validate ramoops survival"
    echo "Marker written, pstore cleared, disk synced."
    echo "Triggering panic NOW - machine hard-reboots in ~$(sysctl -n kernel.panic)s."
    echo "After it returns:  sudo $0 check"
    sync
    echo c > /proc/sysrq-trigger
    echo "(if you can still read this, the crash trigger did not fire)"
    ;;

  arm-noreboot)
    # CRASH-FREE survival test. Make the kernel dump its log to ramoops on every
    # clean shutdown/reboot: printk.always_kmsg_dump=1 + ramoops.max_reason=0
    # (=> KMSG_DUMP_MAX, which includes SHUTDOWN). Applies to ALL kernel entries,
    # effective on next boot. Then ANY normal reboot leaves a record for 'check' -
    # no crash. Ref: pstore/ram "dump kmesg during regular reboot" (Tatashin, v5.8+).
    grubby --update-kernel=ALL --remove-args="ramoops.max_reason printk.always_kmsg_dump" >/dev/null 2>&1
    grubby --update-kernel=ALL --args="ramoops.max_reason=0 printk.always_kmsg_dump=1"
    echo "Armed crash-free test on ALL kernel entries (effective on next boot)."
    echo "After that boot, do ONE normal reboot, then:  sudo $0 check"
    echo "Disarm: sudo $0 disarm-noreboot"
    ;;

  disarm-noreboot)
    grubby --update-kernel=ALL --remove-args="printk.always_kmsg_dump ramoops.max_reason" >/dev/null 2>&1
    grubby --update-kernel=ALL --args="ramoops.max_reason=2"
    echo "Disarmed: ramoops.max_reason restored to 2, always_kmsg_dump removed."
    ;;

  check)
    echo "=== marker (when the test was armed) ==="
    if [ -f "$MARKER" ]; then sed 's/^/  /' "$MARKER"; else
        echo "  NO marker found - was 'crash --confirm' actually run before the reboot?"; fi
    echo "=== records after reboot ==="; list_records

    armed=$(sed -n 's/^armed_epoch=//p' "$MARKER" 2>/dev/null)
    found=$(find "$PSTORE_LIVE" "$PSTORE_ARCHIVE" -name 'dmesg-*' \
                 ${armed:+-newermt "@$armed"} 2>/dev/null)
    echo
    if [ -n "$found" ]; then
        echo "VERDICT: PASS - a kernel-log record survived the reboot:"
        echo "$found" | sed 's/^/    /'
        echo "  => the recorder's RAM survives a reboot on this laptop."
        echo "  => NEXT: turn on the continuous per-core trace (add ramoops.ftrace_size) so the"
        echo "          real freeze leaves the last actions of every core - even a total wedge."
    else
        echo "VERDICT: FAIL - no panic record survived."
        echo "  => the recorder's RAM does NOT survive a reboot here. This alone explains every"
        echo "     empty log from the real freezes, and means in-memory capture is impossible."
        echo "  => pivot to the cheap discriminating experiments and/or hardware-debugger/warranty."
    fi
    ;;

  *)
    echo "usage: $0 {status | crash --confirm | arm-noreboot | disarm-noreboot | check}"; exit 2
    ;;
esac
