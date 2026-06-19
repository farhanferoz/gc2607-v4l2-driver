#!/bin/bash
#
# gc2607-crash-triage.sh - PERMANENT one-shot crash triage for the
# silent-freeze incident (docs/incidents/2026-05-silent-freezes.md).
#
# Run after any suspected crash:   sudo ./gc2607-crash-triage.sh
# Optional: pass a boot offset (default -1 = previous boot crashed):
#                                  sudo ./gc2607-crash-triage.sh -2
#
# Collects in <30s everything that took hours by hand, writes an evidence
# pack to /var/log/gc2607-crash-triage/<timestamp>/, and prints a VERDICT
# block with the key discriminator: which channel died first.
#   disk-first (NAS outlives local journal)  -> drive story
#   net-first  (local journal outlives NAS)  -> platform story
#
set -u
BOOT="${1:--1}"
TS=$(date +%Y%m%d-%H%M%S)
EV=/var/log/gc2607-crash-triage/$TS
mkdir -p "$EV"
NAS_USER="${SUDO_USER:-ff235}"
NAS_DIR=/share/homes/ff235/freeze-capture

j() { journalctl -b "$BOOT" --no-pager "$@" 2>/dev/null; }

{
echo "=== $(date -Is) crash triage (boot $BOOT) ==="

# --- 1. boot timeline ---------------------------------------------------
echo "--- boots ---"
journalctl --list-boots --no-pager | tail -6
CRASH_END=$(j -n 1 -o short-iso | tail -1 | awk '{print $1}')
echo "crashed boot last local entry: $CRASH_END"

# --- 2. what config was the crashed boot running ------------------------
echo "--- crashed boot cmdline ---"
j -o cat _TRANSPORT=kernel | grep -m1 "Command line"
echo "HMB arg present: $(j -o cat _TRANSPORT=kernel | grep -m1 'Command line' | grep -c max_host_mem_size_mb)"

# --- 3. final 40 lines of the crashed boot -------------------------------
echo "--- crashed boot tail (last 40) ---"
j -n 40 -o short-precise | tee "$EV/local-tail.txt"

# --- 4. kernel errors anywhere in the crashed boot's last 10 min ---------
echo "--- kernel error grep, last 10 min of crashed boot ---"
j -o short-precise _TRANSPORT=kernel | tail -600 | \
  grep -iE 'nvme|timeout|abort|controller|blk_|aer|mce|hung|lockup|oops|panic|BUG|Call Trace|watchdog|iwlwifi.*(error|time out)' \
  | grep -v 'Command line' | tail -20
echo "(empty = kernel printed no errors before death - matches all prior crashes)"

# --- 5. NAS divergence: THE discriminator --------------------------------
if [ -n "$CRASH_END" ]; then
    DAY=$(echo "$CRASH_END" | cut -dT -f1)
    HOUR_PAT=$(echo "$CRASH_END" | cut -dT -f2 | cut -d: -f1)
    echo "--- NAS stream around local death ($CRASH_END) ---"
    # Pull a generous raw window (the crash hour), then find the dying boot's
    # true last line: the entry just before the first >20s timestamp jump
    # (= the reboot gap). Without this, post-reboot lines pollute the verdict.
    runuser -u "$NAS_USER" -- ssh -o BatchMode=yes -o ConnectTimeout=10 nasff235 \
        "grep '^${DAY}T${HOUR_PAT}' $NAS_DIR/fedora-journal-${DAY}.log" \
        > "$EV/nas-window-raw.txt" 2>&1
    LOCAL_EPOCH=$(date -d "$CRASH_END" +%s 2>/dev/null || echo 0)
    NAS_END=$(awk -v anchor="$LOCAL_EPOCH" '
        {
            ts=$1; gsub(/[+-][0-9]{2}:[0-9]{2}$/,"",ts)
            split(ts,a,/[-T:]/)
            t=mktime(a[1]" "a[2]" "a[3]" "a[4]" "a[5]" "a[6])
            # only consider gaps near the local death (within +/-10 min)
            if (prev && t-prev>20 && prev>anchor-600 && prev<anchor+600) { print prevline; exit }
            prev=t; prevline=$1
        }
        END { if (prevline) print prevline }' "$EV/nas-window-raw.txt" | head -1)
    grep -B6 -m1 "^${NAS_END}" "$EV/nas-window-raw.txt" | tee "$EV/nas-window.txt"
    echo "NAS last entry from dying boot: $NAS_END   local last: $CRASH_END"

    # --- 5b. MECHANISM telemetry around death (per-core C6 + GPU IRQ) ----
    # gc2607-telem + i915-watch lines ride the same NAS journal file, so they
    # are already in nas-window-raw.txt. The last samples before the gap show
    # which CPUs were entering C6 and where the GPU interrupt sat at death --
    # the discriminator between the GPU-IRQ (software) and any-core-C6
    # (hardware) hypotheses.
    echo "--- last 20 mechanism-telemetry samples before death ---"
    grep -E 'gc2607-telem|i915-watch' "$EV/nas-window-raw.txt" 2>/dev/null \
        | tail -20 | tee "$EV/telemetry-window.txt"
    echo "(look at the FINAL line: c6cores=[..] = which CPUs entered C6; irq200=cpuN = GPU IRQ location)"
fi

# --- 6. pstore: live + durable archive -----------------------------------
echo "--- /sys/fs/pstore ---";        ls -la /sys/fs/pstore/
echo "--- /var/lib/systemd/pstore ---"; ls -laR /var/lib/systemd/pstore/ 2>/dev/null | head -20
for f in /sys/fs/pstore/* /var/lib/systemd/pstore/*/*; do
    [ -f "$f" ] && cp -a "$f" "$EV/" && echo "ARCHIVED: $f"
done
echo "--- ramoops address parity (must match across boots for records to survive) ---"
for b in "$BOOT" 0; do
    echo "boot $b: $(journalctl -b $b --no-pager -o cat _TRANSPORT=kernel 2>/dev/null | grep -oE 'ramoops: using 0x[0-9a-f]+@0x[0-9a-f]+')"
done

# --- 7. drive state -------------------------------------------------------
echo "--- nvme smart (watch unsafe_shutdowns) ---"
nvme smart-log /dev/nvme0 | grep -E 'unsafe_shutdowns|temperature|percentage_used|media_errors|num_err_log'
echo "--- error-log entry0 (always pristine so far) ---"
nvme error-log /dev/nvme0 -e 1 | grep -E 'error_count|status_field'
echo "--- firmware + HMB state ---"
nvme id-ctrl /dev/nvme0 | grep -E '^fr '
nvme get-feature /dev/nvme0 -f 0x0d -H | grep -E 'EHM|HSIZE'

# --- 8. platform ----------------------------------------------------------
echo "--- BIOS ---"
dmidecode -s bios-version; dmidecode -s bios-release-date
echo "--- watchers this boot ---"
for u in gc2607-camera i915-watch; do echo "$u: $(systemctl is-active $u 2>&1)"; done
for u in nvme-temp-watch journal-capture-nas; do
    echo "$u: $(runuser -u "$NAS_USER" -- env XDG_RUNTIME_DIR=/run/user/$(id -u "$NAS_USER") systemctl --user is-active $u 2>&1)"
done

# --- 8.5 crash class: userspace-hang vs silent-freeze --------------------
# A genuine silent freeze is a total SoC wedge: logging stops INSTANTLY, no
# degradation, no OOM, NMI watchdog never fires. A userspace hang (e.g. a dev
# build/app exhausting memory) looks the opposite and must NOT be counted as a
# freeze. We mined a 7-min event as "silent-freeze" once when it was really a
# StratSense global-OOM + stuck Docker container (2026-06-14) -- this catches it.
# Search BOTH the local boot journal and the NAS raw window (same events; the
# local journal may hold a few extra seconds past the NAS gap).
echo "--- crash class discriminators (userspace-hang vs silent-freeze) ---"
# Only weigh markers in the ~20 min BEFORE death. A real OOM/overload hang fires its
# markers AT the hang; an unrelated boot-time blip must not flip the verdict.
# (2026-06-15: a libinput "system too slow" at boot - 75 min before a genuine freeze -
#  wrongly tipped the class to USERSPACE-HANG, which would UNDERCOUNT a real freeze.
#  The NAS raw window is already hour-bounded; this bounds the local journal to match.)
CWIN_START=$(date -d "@$(( $(date -d "${CRASH_END:-}" +%s 2>/dev/null || echo 0) - 1200 ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
ALLSRC() { { j -o short-precise ${CWIN_START:+--since "$CWIN_START"}; cat "$EV/nas-window-raw.txt" 2>/dev/null; }; }
SRC_OOM=$(ALLSRC | grep -iE 'oom-kill|out of memory|invoked oom-killer|killed process [0-9]' | tail -5)
SRC_SLOW=$(ALLSRC | grep -iE 'your system is too slow|expiry is in the past|lagging behind' | tail -3)
SRC_DOCK=$(ALLSRC | grep -iE 'could not send kill signal' | tail -3)
PEAK_LOAD=$(grep -oE 'load=[0-9]+\.[0-9]+' "$EV/nas-window-raw.txt" 2>/dev/null | sed 's/load=//' | sort -gr | head -1)

report_marker() { # $1=label  $2=hits
    if [ -n "$2" ]; then echo "$1: FOUND"; echo "$2" | sed 's/^/    /'; else echo "$1: not found"; fi
}
report_marker "OOM kill        " "$SRC_OOM"
report_marker "user 'too slow' " "$SRC_SLOW"
report_marker "stuck container " "$SRC_DOCK"
echo "peak telemetry load= ${PEAK_LOAD:-unknown}  (info only - training legitimately runs high here, so load alone is NOT a hang)"

CLASS="SILENT-FREEZE  (no userspace-hang markers - instant silence, the real signature)"
if [ -n "$SRC_OOM" ]; then
    CLASS="USERSPACE-HANG  (global OOM / memory exhaustion -> NOT a silent freeze; EXCLUDE from dataset)"
elif [ -n "$SRC_SLOW" ] || [ -n "$SRC_DOCK" ]; then
    CLASS="LIKELY USERSPACE-HANG  (overload markers: 'system too slow'/stuck container -> review before counting)"
fi

# --- 9. verdict -----------------------------------------------------------
echo
echo "================= VERDICT ================="
echo "CLASSIFICATION    : $CLASS"
echo "local journal end : $CRASH_END"
echo "NAS stream end    : ${NAS_END:-unknown}"
if [ -n "${NAS_END:-}" ] && [ -n "$CRASH_END" ]; then
    if [[ "$NAS_END" > "$CRASH_END" ]]; then
        echo "DIRECTION: DISK-FIRST (NAS outlived local) -> drive-stall story"
    elif [[ "$NAS_END" < "$CRASH_END" ]]; then
        echo "DIRECTION: NET-FIRST (local outlived NAS) -> platform story"
    else
        echo "DIRECTION: SIMULTANEOUS"
    fi
    [ "${CLASS#SILENT-FREEZE}" = "$CLASS" ] && echo "  (DIRECTION is only meaningful for a true freeze - see CLASSIFICATION above)"
fi
echo "pstore records    : $(ls /sys/fs/pstore/ /var/lib/systemd/pstore/ 2>/dev/null | grep -vcE '^$|:')"
echo "evidence pack     : $EV"
echo "==========================================="
} 2>&1 | tee "$EV/triage-report.txt"

chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$EV" 2>/dev/null || true
