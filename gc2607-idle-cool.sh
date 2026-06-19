#!/bin/bash
#
# gc2607-idle-cool.sh - Reclaim idle quiet WITHOUT re-enabling deep sleep.
#
# Context: deep sleep (C6) must stay OFF as the only software mitigation for
# the MTL066 silent-lockup erratum (gc2607-cstate-fix.sh). With C6 off, cores
# idle in the shallow C1E state, so idle HEAT is dominated by core FREQUENCY,
# not C-states. This script biases the HWP energy policy toward low idle
# frequency (and optionally caps turbo) to cut the fan noise/heat - while
# leaving C6 off, so crash protection is untouched.
#
# It does NOT touch C-states. It is orthogonal to gc2607-deep-sleep.sh:
#   keep C6 OFF (protected) + run this ON (cool)  =  the recommended combo.
#
# Trade-off: cooler/quieter idle costs a little idle responsiveness; under real
# load HWP still ramps (turbo stays on unless you pass 'max'). Fully reverts.
#
# Usage:
#   sudo ./gc2607-idle-cool.sh on        # EPP=power on all cores (turbo kept)
#   sudo ./gc2607-idle-cool.sh max       # EPP=power + turbo OFF (coolest)
#   sudo ./gc2607-idle-cool.sh off       # restore EPP=balance_performance + turbo on
#   sudo ./gc2607-idle-cool.sh status    # show EPP / turbo / freq / temp
#
set -u

if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

EPP_COOL="power"
EPP_DEFAULT="balance_performance"
NO_TURBO=/sys/devices/system/cpu/intel_pstate/no_turbo

set_epp() {  # $1 = epp string
    local v="$1" n=0 f
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
        [ -w "$f" ] && echo "$v" > "$f" && n=$((n+1))
    done
    echo "epp: set '$v' on $n cores"
}

set_turbo() {  # $1 = 0 (turbo ON) or 1 (turbo OFF, no_turbo=1)
    if [ -w "$NO_TURBO" ]; then
        echo "$1" > "$NO_TURBO" && echo "turbo: no_turbo=$1 ($([ "$1" = 1 ] && echo DISABLED || echo enabled))"
    else
        echo "turbo: $NO_TURBO not writable (skipped)" >&2
    fi
}

show_status() {
    echo "=== idle-heat policy ==="
    echo "  EPP (cpu0)   : $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)"
    echo "  EPP available: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_available_preferences 2>/dev/null)"
    echo "  governor     : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
    echo "  no_turbo     : $(cat "$NO_TURBO" 2>/dev/null)"
    echo "  cpu0 cur kHz : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)"
    echo "=== deep sleep (must stay BLOCKED for crash protection) ==="
    for d in /sys/devices/system/cpu/cpu0/cpuidle/state*/; do
        nm=$(cat "$d/name" 2>/dev/null); [ "$nm" = C6 ] || [ "$nm" = C10 ] || continue
        echo "  cpu0 $nm disable=$(cat "${d}disable" 2>/dev/null)"
    done
    grep -q 'intel_idle.max_cstate=1' /proc/cmdline && echo "  cmdline: C1E-capped (C6/C10 absent) — protected" || echo "  cmdline: NOT capped"
    echo "=== now ==="
    sensors 2>/dev/null | grep -iE 'Package id 0|fan1:' | sed 's/^/  /'
}

case "${1:-status}" in
  on)
    echo ">> idle-cool ON: low idle frequency, turbo kept for load"
    set_epp "$EPP_COOL"; set_turbo 0; echo; show_status ;;
  max)
    echo ">> idle-cool MAX: low idle frequency + turbo OFF (coolest, caps peak speed)"
    set_epp "$EPP_COOL"; set_turbo 1; echo; show_status ;;
  off)
    echo ">> idle-cool OFF: restoring default performance bias"
    set_epp "$EPP_DEFAULT"; set_turbo 0; echo; show_status ;;
  status) show_status ;;
  install)
    # persist EPP=power across boot + resume + AC<->battery switch. systemd/udev can't
    # exec a script from /home under SELinux (203/EXEC) -> use a /usr/local/sbin helper.
    cat > /usr/local/sbin/gc2607-epp-power <<'HELP'
#!/bin/bash
# bias all cores to EPP=power (low idle heat; turbo still ramps for real load)
for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
  [ -w "$f" ] && echo power > "$f"
done
exit 0
HELP
    chmod +x /usr/local/sbin/gc2607-epp-power
    command -v restorecon >/dev/null 2>&1 && restorecon -F /usr/local/sbin/gc2607-epp-power 2>/dev/null
    cat > /etc/systemd/system/gc2607-idle-cool.service <<'SVCEOF'
[Unit]
Description=gc2607 idle-cool (EPP=power) - low idle heat, turbo kept for load
After=tuned.service
Wants=tuned.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gc2607-epp-power
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
    cat > /usr/lib/systemd/system-sleep/gc2607-idle-cool <<'HOOKEOF'
#!/bin/bash
[ "$1" = post ] && /usr/local/sbin/gc2607-epp-power
exit 0
HOOKEOF
    chmod +x /usr/lib/systemd/system-sleep/gc2607-idle-cool
    printf '%s\n' 'SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", RUN+="/usr/bin/systemctl --no-block restart gc2607-idle-cool.service"' > /etc/udev/rules.d/99-gc2607-idle-cool.rules
    systemctl daemon-reload; systemctl enable --now gc2607-idle-cool.service; udevadm control --reload
    echo ">> persisted via /usr/local/sbin/gc2607-epp-power: boot svc (after tuned) + resume hook + AC-change udev rule" ;;
  uninstall)
    rm -f /etc/systemd/system/gc2607-idle-cool.service /usr/lib/systemd/system-sleep/gc2607-idle-cool /etc/udev/rules.d/99-gc2607-idle-cool.rules /usr/local/sbin/gc2607-epp-power
    systemctl disable gc2607-idle-cool.service 2>/dev/null; systemctl daemon-reload; udevadm control --reload 2>/dev/null
    echo ">> idle-cool persistence removed (runtime EPP unchanged; run 'off' to restore default)" ;;
  *) echo "usage: $0 [on|max|off|status|install|uninstall]" >&2; exit 1 ;;
esac
