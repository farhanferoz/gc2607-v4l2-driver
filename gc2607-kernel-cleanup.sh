#!/bin/bash
#
# gc2607-kernel-cleanup.sh <version> — remove one installed kernel (RPMs + BLS entry + /lib/modules).
# Guards: refuses to remove the RUNNING kernel or the DEFAULT boot entry.
#
#   sudo bash gc2607-kernel-cleanup.sh 7.0.10-201.fc44.x86_64
#
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo bash $0 <version>" >&2; exit 1; }
KV="${1:?usage: gc2607-kernel-cleanup.sh <version e.g. 7.0.10-201.fc44.x86_64>}"

RUN=$(uname -r)
[ "$KV" = "$RUN" ] && { echo "REFUSING: $KV is the running kernel." >&2; exit 1; }
DEF=$(grubby --default-kernel 2>/dev/null)
case "$DEF" in *"$KV"*) echo "REFUSING: $KV is the default boot entry ($DEF)." >&2; exit 1 ;; esac

# rpm -qa glob matches NAMES (no version), so match the full NVRA by filtering instead.
PKGS=$(rpm -qa | grep -F -- "$KV" | grep -E '^kernel')
[ -n "$PKGS" ] || { echo "No installed kernel packages contain version ${KV}" >&2; exit 1; }
echo "Removing kernel $KV — packages:"; echo "$PKGS" | sed 's/^/    /'
dnf -y remove $PKGS 2>&1 | tail -15

echo
echo "--- kernels still installed ---"; rpm -q kernel-core | sed 's/^/    /'
echo "--- default boot entry ---"; grubby --default-kernel
