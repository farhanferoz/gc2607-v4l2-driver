# GC2607 machine — operations runbook

Reusable, documented procedures for this laptop (camera + silent-freeze fix + power). The point of this
file: **don't reinvent these — run the named script.** All scripts live in the repo root unless noted.
Most need `sudo`; a scoped passwordless trampoline (`/etc/sudoers.d/gc2607-dev`, installed by
`setup-sudo.sh`) lets any `gc2607-*.sh` run via `sudo -n` without a password.

## The standing state (verdict 2026-06-13)

The silent-freeze saga is **closed: software fix, no warranty.** Holding the two LP-E cores
(`cpu20`/`cpu21`) out of C6 is the cure ("Phase 1b"). It is applied every boot, kernel-agnostically, by
the marker `/etc/gc2607-cstate-mode=test1b` + `gc2607-cstate-test.service`. Running kernel: **7.0.12**;
**7.0.11** is kept as a pristine fallback. Full history: `docs/incidents/2026-05-silent-freezes.md`,
live state: `RESUME.md`.

## Tools

| Script | What it does | Run |
|---|---|---|
| `gc2607-health.sh` | Read-only health check: freeze fix engaged, camera up, power state, no crash last boot. Run anytime. | `bash gc2607-health.sh` |
| `gc2607-power-status.sh` | Read-only power/thermal **posture audit + verdict** (EPP, turbo headroom, tuned, charge cap, intel_lpmd, radios, PSR, freeze fix) — flags any drift from the tuned baseline. `perf` mode measures the EPP=power CPU cost vs `balance_performance`. Run after reboot/kernel-update/suspend. | `bash gc2607-power-status.sh [perf]` |
| `gc2607-power-measure.sh` | Measure power draw; logs each run to `docs/power-measurements.log` for comparison. **Unplug first** for the real number. | `sudo bash gc2607-power-measure.sh [secs] [note]` |
| `gc2607-power-ab.sh` | Controlled back-to-back A/B of the EPP lever at constant load (untuned vs tuned), on battery. | `sudo bash gc2607-power-ab.sh [secs]` |
| `gc2607-cable-charge.sh` | USB-C **cable & coupler tester**: `measure LABEL` (charge W a cable delivers → `docs/cable-charge-measurements.log`), `report` (diff cables), `watch` (flag PD dropouts on a flaky/coupler link), `status`, `guide` (full A/B + coupler-orientation protocol). `measure` briefly lifts the 80% charge cap to force charging, then restores it. | `bash gc2607-cable-charge.sh guide` |
| `gc2607-kernel-cleanup.sh` | Remove one installed kernel (RPMs + boot entry + modules). Refuses the running/default kernel. | `sudo bash gc2607-kernel-cleanup.sh <version>` |
| `gc2607-fix-bridge.sh` | Build/install the patched `ipu-bridge.ko` into a kernel's `extra/` (+ hot-swap if it's running). | `sudo bash gc2607-fix-bridge.sh <kver> <ipu-bridge.ko>` |
| `gc2607-cstate-test.sh` (in `/usr/local/sbin`) | C-state controller: `status` / `stock` (full deep sleep, the current baseline) / `test1b` (retired 06-18) / `protect-now` (emergency global C6-off). Boot service **disabled** since the C-state theory was retired. | `sudo /usr/local/sbin/gc2607-cstate-test.sh status` |
| `gc2607-cstate-clear.sh` | One-shot that retired `test1b`: re-enabled deep sleep on all cores, disabled the boot service, logged a `BASELINE-CHANGE` marker to the NAS stream. Idempotent/reversible. | `sudo bash gc2607-cstate-clear.sh` |
| `gc2607-idle-cool.sh` | Comfort: bias HWP to low idle frequency (quiet/cool) without touching the C6 fix. `on`/`max`/`off`. | `sudo bash gc2607-idle-cool.sh on` |
| `gc2607-telemetry.sh` | 2 s per-core C6 + GPU-IRQ telemetry → journal → NAS (freeze forensics; retire once cure is trusted). | user service `gc2607-telemetry.service` |
| `gc2607-finalize.sh` | (Historical) the one-shot 7.0.11→7.0.12 migration + battery tuning. Kept for reference/re-run. | `sudo bash gc2607-finalize.sh` |

## Procedures

### Is everything OK? (after reboot, or any time)
```
bash gc2607-health.sh
```
Want: kernel as expected, `cpu20=1 cpu21=1` (rest 0), IRQ200@cpu2, camera service active, no crash last boot.

### Measure battery / power
The number that matters (total system draw) is the battery discharge rate, so it needs the charger out.
```
# 1. UNPLUG the charger,  2. stop touching the machine,  3.
sudo bash gc2607-power-measure.sh 60 "what you're testing"
```
Each run appends to `docs/power-measurements.log`. Baseline (untuned, 2026-06-12): ~25.8 W (~2.65 h).
Target after tuning: ~13–16 W (~4.5–5 h light use).

### After a kernel update (rebuild the patched camera BEFORE booting the new kernel)
The stock akmods build is NOT our patched camera path; every kernel update breaks the camera until rebuilt.
```
K=<new-kver e.g. 7.0.13-200.fc44.x86_64>
# 1. patched ipu-bridge:
cp ipu-bridge-oot/7.0.12/ipu-bridge.c ipu-bridge-oot/7.0.12/Makefile ipu-bridge-oot/$K_DIR/   # new dir per kver
make -C ipu-bridge-oot/<dir> KDIR=/usr/src/kernels/$K
sudo bash gc2607-fix-bridge.sh $K ipu-bridge-oot/<dir>/ipu-bridge.ko
# 2. gc2607 sensor module:
make -C /lib/modules/$K/build M="$PWD" modules
sudo install -d /lib/modules/$K/extra
sudo bash -c "xz -c --check=crc32 --lzma2=dict=1MiB gc2607.ko > /lib/modules/$K/extra/gc2607.ko.xz && depmod $K"
# 3. ensure the new boot entry has NO intel_idle.max_cstate cap (marker drives Phase-1b) and keep i915.enable_psr=2.
# 4. reboot, then: bash gc2607-health.sh
```

### Trim the boot menu (too many kernel options)
```
rpm -q kernel-core                                   # list installed
sudo bash gc2607-kernel-cleanup.sh <oldest-version>  # e.g. 7.0.11-200.fc44.x86_64
```
Keep at least one previous kernel as a fallback for a few days after any migration.

### Emergency: freeze comes back (it shouldn't)
```
sudo /usr/local/sbin/gc2607-cstate-test.sh protect-now   # live global C6-off (max protection)
```
or reboot and pick the 7.0.11 fallback entry.

## Build/packaging gotchas (don't re-learn)
- Kernel-loadable module compression **must** be `xz --check=crc32 --lzma2=dict=1MiB` (plain `xz -9` fails at insmod).
- depmod `override` lines key on the **dash** form: `override ipu-bridge * extra`.
- `rpm -qa "glob"` matches package **names** (no version) — to match a full NVRA, filter: `rpm -qa | grep -F "$ver"`.
- The `gc2607-*.sh` sudoers glob runs those scripts passwordless via `sudo -n`; a plain `sudo -n true` still prompts.
