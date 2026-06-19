#!/bin/bash
#
# GC2607 Camera — Start
#
# Thin wrapper around the gc2607-camera systemd service. Auto-elevates to root
# via sudo, refuses to be sourced, and prints errors instead of killing the
# terminal. Safe to run from any shell.
#
# Usage:
#   ./gc2607-start.sh              # start the camera service
#   ./gc2607-start.sh --stop       # stop it
#   ./gc2607-start.sh --restart    # restart it
#   ./gc2607-start.sh --status     # show current unit state
#

# Refuse to be sourced. With `set -e` or an explicit exit, a sourced script
# can kill the parent shell on failure — exactly the "killed the terminal"
# symptom. Force the script to run as a child process.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "[gc2607-start] Do not 'source' this script — run it: ./gc2607-start.sh" >&2
    return 1 2>/dev/null || exit 1
fi

# Intentionally no `set -e` / `set -u`. Every failure path is checked and
# printed explicitly, so the script never disappears silently.

SERVICE=gc2607-camera.service

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

info()  { printf '%s[INFO]%s  %s\n'  "$GREEN"  "$NC" "$*"; }
warn()  { printf '%s[WARN]%s  %s\n'  "$YELLOW" "$NC" "$*"; }
error() { printf '%s[ERROR]%s %s\n'  "$RED"    "$NC" "$*" >&2; }

action="${1:-start}"

# Read-only actions don't need root; everything else does.
case "$action" in
    --status|--help|-h)
        ;;
    *)
        if [ "$(id -u)" -ne 0 ]; then
            exec sudo --preserve-env=TERM -- "$0" "$@"
        fi
        ;;
esac

verify_unit() {
    if ! systemctl list-unit-files "$SERVICE" --no-legend --no-pager 2>/dev/null \
         | grep -q "$SERVICE"; then
        error "$SERVICE is not installed."
        error "Install it with: sudo ./gc2607-driver-install.sh"
        return 1
    fi
}

# Wait up to ~10s for the unit to reach active state.
wait_active() {
    for _ in $(seq 1 20); do
        systemctl is-active --quiet "$SERVICE" && return 0
        sleep 0.5
    done
    return 1
}

dump_recent_logs() {
    journalctl -u "$SERVICE" --no-pager -n 20 2>&1 || true
}

do_start() {
    verify_unit || return 1

    if systemctl is-active --quiet "$SERVICE"; then
        info "$SERVICE is already active."
        info "Virtual camera: /dev/video50 (lazy — opens on first consumer)."
        return 0
    fi

    info "Starting $SERVICE..."
    if ! systemctl start "$SERVICE"; then
        error "systemctl start failed. Recent logs:"
        dump_recent_logs
        return 1
    fi

    if ! wait_active; then
        error "$SERVICE did not become active within 10s. Recent logs:"
        dump_recent_logs
        return 1
    fi

    info "$SERVICE is active."
    info "Virtual camera: /dev/video50 (lazy — opens on first consumer)."
    info "Stop with: $0 --stop"
}

do_stop() {
    if ! systemctl is-active --quiet "$SERVICE"; then
        info "$SERVICE is already stopped."
        return 0
    fi
    info "Stopping $SERVICE..."
    systemctl stop "$SERVICE"
    info "Stopped."
}

do_restart() {
    verify_unit || return 1
    info "Restarting $SERVICE..."
    if ! systemctl restart "$SERVICE"; then
        error "systemctl restart failed. Recent logs:"
        dump_recent_logs
        return 1
    fi
    if ! wait_active; then
        error "$SERVICE did not become active within 10s. Recent logs:"
        dump_recent_logs
        return 1
    fi
    info "$SERVICE is active."
}

do_status() {
    systemctl status "$SERVICE" --no-pager
}

print_help() {
    cat <<'EOF'
gc2607-start.sh — start the GC2607 camera service

Usage:
  ./gc2607-start.sh              # start the camera service
  ./gc2607-start.sh --stop       # stop it
  ./gc2607-start.sh --restart    # restart it
  ./gc2607-start.sh --status     # show current unit state

The script delegates to the gc2607-camera systemd unit, which runs the
software ISP (/opt/gc2607/gc2607_isp) in lazy-activation mode on
/dev/video50. It auto-elevates with sudo and is safe to run from any
shell — it will never kill the terminal.
EOF
}

case "$action" in
    start)     do_start ;;
    --stop)    do_stop ;;
    --restart) do_restart ;;
    --status)  do_status ;;
    --help|-h) print_help ;;
    *)
        error "Unknown option: $action"
        print_help >&2
        exit 2
        ;;
esac
