# Power tuning plan (apply AFTER the freeze verdict)

> Do **not** apply while the Phase-1b freeze soak is running (verdict ~2026-06-13 evening).
> Several levers couple to the freeze fix — see *Coupling* below. This is a post-verdict to-do.

## Baseline — measured 2026-06-12 (on battery, light interactive use)

- **Total system draw: 25.8 W** → 68.6 Wh ÷ 25.8 = **~2.65 h** (matches the lived 2–3 h).
- **CPU/SoC package (RAPL): 17.0 W** with only ~1 core of background load (browser + session),
  because EPP is `balance_performance` (performance-leaning) and the package can't deep-idle.
- Rest of system ~8.8 W (panel at 20%, NVMe, WiFi, RAM, board) — roughly normal.
- **Battery HEALTH is fine: 98%** (68.6 / 70.0 Wh), **48 cycles** → the cell is not the problem.
- Verdict: this is **untuned Linux power management**, not hardware. Same chip family, tuned,
  goes 8–10 W idle → ~3.5 W (ref: blog.fsck.com Meteor Lake power writeup) — i.e. ~2× runtime.
- Note: a measurement taken with a browser + AI session live is **light use, not true idle**;
  true idle reads lower, and **training draws 30–45 W no matter what** (intrinsic, not tunable).

## Plan — highest leverage first

**1. EPP → `power` (native, no install — the dominant lever):**
```
powerprofilesctl get        # confirm the daemon works (came back EMPTY on 06-12 — verify first)
powerprofilesctl list
powerprofilesctl set power-saver
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference   # expect: power
```
GNOME does not auto-switch on battery — select **Power Saver** in the menu (or script it later).

**2. TLP — ONLY if power-profiles-daemon is broken (never run both):**
```
sudo dnf install tlp
sudo systemctl mask power-profiles-daemon
sudo systemctl enable --now tlp
```
`/etc/tlp.conf` (battery side):
```
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_BAT=power
CPU_BOOST_ON_BAT=0
# CPU_MAX_PERF_ON_BAT=<your choice, e.g. 60> — do NOT copy the blog's 30; you run compute on battery
# leave PCIE_ASPM_ON_BAT at default — do NOT force ASPM (see Excluded)
```
then `sudo tlp start`.

**3. Display/GPU (behavioral, cheap):**
```
gsettings set org.gnome.desktop.interface cursor-blink false   # blinking cursor wakes the GPU ~60x/s
gsettings set org.gnome.desktop.interface enable-animations false
```

**4. Re-enable PSR + display power (cmdline → reboot; coordinate with the 7.0.12 migration):**
```
sudo grubby --update-kernel=ALL --remove-args="i915.enable_psr=0"
sudo grubby --update-kernel=ALL --args="i915.enable_psr=2 i915.enable_fbc=1 i915.enable_dc=4"
# reboot, then watch the panel for flicker/artifacts; if any -> revert to i915.enable_psr=0
```
PSR was off since the freeze/camera work ("free, harmless"). Re-enabling unlocks the cursor-blink win (#3).

**5. WiFi + audio autosuspend (modprobe → reboot, or via TLP):**
```
echo 'options iwlwifi power_save=1'     | sudo tee /etc/modprobe.d/iwlwifi-power.conf
echo 'options snd_hda_intel power_save=1' | sudo tee /etc/modprobe.d/audio-power.conf
```

**6. intel-lpmd — ONLY after the freeze is fully resolved:**
It parks idle work onto the LP-E cores (cpu20/21) — the exact pair Phase 1b holds awake. It will
**undo** the freeze mitigation. Do not install until deep sleep on those cores is known-safe.

## Excluded — do NOT add (freeze coupling)

- **`pcie_aspm=force` / any ASPM forcing** — disproven as a freeze fix (#11/#12) and reverted; "do not
  re-stage". Only ~0.5 W; not worth reopening a freeze variable.
- **NVMe APST / nvme power tuning** — the SN740 hung >5 min on a live APST set; off-limits.
- **`nmi_watchdog=0`** (~0.5 W) — blocked while diagnosing; the crash recorder needs `nmi_watchdog=panic`.

## Coupling to the freeze fix (why this waits)

- Phase 1b holds cpu20/21 (LP-E, on the SoC tile) out of C6 → blocks package deep-idle → a permanent
  small idle-power tax while the mitigation stands.
- If the verdict is hardware/warranty and the board is repaired so deep sleep is safe again, that tax
  disappears and the ~3.5 W-class idle becomes reachable.

## Targets

- Light use: ~26 W → **~13–16 W ⇒ ~4.5–5 h** (≈ doubles today).
- True idle, tuned (with the freeze tax): **~7–8 h**.
- Training: unchanged at 30–45 W (intrinsic).
- Last stretch to true Windows parity needs i915 driver work — not worth chasing.

## Verify the improvement

Restore the measurement script from this session's archive and re-run it:
```
tar xzf docs/incidents/gc2607-battery-power-scripts-archive-2026-06-12.tar.gz gc2607-power-measure.sh
sudo bash gc2607-power-measure.sh        # unplugged, idle, ~60 s window
```
Optional, for a per-consumer breakdown: `sudo dnf install powertop`.

## 2026-06-13 — research update + measured results (post-verdict)

Sourced research pass (Intel MTL datasheet, fsck.com Meteor Lake writeup, Phoronix EPP, Arch wiki) +
on-machine measurement. Conclusions that change the plan:

**The freeze fix caps the ceiling.** Package C-state is gated by the *highest* core C-state, so holding
cpu20/21 out of C6 pins the package at **PC2** — the ~3.5 W deep-idle floor of a healthy 185H is
**permanently unreachable**. Realistic floor for this machine: **~6–9 W package / ~7–8 h true idle**.
This is the price of the software fix; not recoverable in software.

**Measured (controlled A/B, same idle load, on battery, 2026-06-13):**
- untuned EPP=`balance_performance`: **25.18 W** (matches the 25.8 W baseline → methodology validated)
- tuned EPP=`balance_power` (stock balanced-battery): **17.51 W**  → **−30 % / −7.67 W from EPP alone**
- a quieter moment earlier read **11.21 W** tuned — absolute draw swings with load; the ~30 % is the robust figure.

**The dominant non-tuning factor is workload.** Idle measurements ran at loadavg ~2 (multiple Claude
sessions, a headless Chrome with ~15 renderers, node/postgres/beam dev services). That background load
dwarfs any kernel knob — the biggest real-world battery lever when unplugged is closing those.

**EPP=`power` + turbo-off on battery — TESTED AND REVERTED (not worth it).** This was the one extra CPU
lever. Implemented as a custom tuned profile mapped into tuned-ppd's `[battery]` section, but **tuned-ppd
applies the `[battery]` mapping only on a power-source *transition*, not on a restart or boot-while-on-
battery** — so the profile strands on the AC `balanced`/`balance_performance` values (i.e. *no* power
saving on battery) until the next plug/unplug. That's a footgun, and the gain is marginal anyway at our
typical load (loadavg ~2; EPP=`power` mostly helps at light idle). **Reverted to stock `balanced-battery`**
(the robust auto-switching ~30 % solution). A non-fragile version would need a `power_supply` udev hook
setting EPP/no_turbo directly (bypassing tuned-ppd) — deferred; not worth the marginal watts.

**Reframed as NOT worth it (was on the old plan):**
- **PCIe ASPM** — its payoff is helping the *package* deep-idle, which the C6 hold already blocks ⇒ <0.5 W
  here, not worth reopening a freeze variable. Leave at BIOS default.
- **USB autosuspend** — ~0.1–0.3 W, real BT/HID dropout risk. Skip.
- **NVMe APST** — the SN740 hung on a live set; off-limits (unchanged).
- **`nmi_watchdog=0`** — ~0.5 W, but the crash recorder still wants `nmi_watchdog=panic`; revisit once the
  cure has soaked a few weeks.

**Optional, user-choice:** panel refresh 60 Hz on battery (0.3–1.5 W; eDP is 3120×2080 high-refresh) —
costs smoothness, so left to preference, not auto-applied.
