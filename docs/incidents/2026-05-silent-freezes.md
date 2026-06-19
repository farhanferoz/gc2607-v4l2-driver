# Silent Kernel Freezes (May 2026)

**Date opened:** 2026-05-21
**Trigger:** Recurring in-use hard freezes after F44 upgrade (kernel 7.0.x), distinct from the May 2 deep-S3 suspend hang

> **🟢 2026-06-18 — FIX HOLDING (~69 h clean on 7.0.12) + BASELINE CLEANED: retired the falsified `test1b` C-state experiment so the SN740 ASPM-L1 fix is the only active mitigation.**
>
> The WD SN740 **ASPM-L1-off** fix (`gc2607-nvme-aspm`, `link/l1_aspm=0`, live since 06-15 11:06:50) has now held **~69 h clean on 7.0.12** — the *implicated* kernel — vs 1.5 / 2 / 7.5 h survival on the same kernel **without** the fix (#20/#19/#18). Live ground truth at 07:58 BST: PCIe **AER counters all zero** on both the drive (`0000:01:00.0`) and its root port (`0000:00:06.0`) — not one recoverable error; link pristine 16.0 GT/s ×4; nvme `live`; **zero crash-triage runs since the fix**; unbroken ~70 h uptime (a total wedge needs a power-cycle, which resets uptime). Under the old ~5 h MTBF a 69 h clean run by chance ≈ e⁻¹³·⁸ ≈ 1e-6. **The mitigation is empirically effective; not a warranty case.** Honest caveat unchanged: this proves the *mitigation*, not the exact mechanism — the 7.0.11→7.0.12 changelog still has no PCI/ASPM commit (two-layer model), now academic since the vulnerability is neutralised regardless.
>
> **Baseline cleanup (this entry's action):** `test1b` (holding LP-E cores cpu20/21 out of C6) was **falsified by crash #18** — the crash run held them out *perfectly* (0/12,299 telem samples) and froze at 7.5 h, while a 64 h survivor let them sleep 616×. It was dead weight and made the surviving config dishonest ("stock + ASPM fix + a disproved C-state hack"). Cleared it via the new `gc2607-cstate-test.sh stock` mode + `gc2607-cstate-clear.sh`: **C6/C10 re-enabled on cpu20/21 → all 22 cores idle stock**, `/etc/gc2607-cstate-mode=off`, `gc2607-cstate-test.service` **disabled** (won't re-apply at boot). The SN740 ASPM-L1 fix, EPP=power thermal fix, and all freeze watchers are untouched. **Deep sleep is now confirmed running full-tilt on every core** (cpu0/4/12/19 deep-sleep thousands of times/s; cpu20/21 rejoin them) and the machine stays clean — an independent, live exoneration of the C6/deep-sleep theory (the chip-erratum trigger condition, "other cores sleeping," is fully present with no freeze).
>
> **Diagnosability preserved (the point of doing it carefully):** the change emits a timestamped `BASELINE-CHANGE` marker via `logger` into the journal, which `journal-capture-nas` streams off-box to `nasff235:/share/homes/ff235/freeze-capture/`. `gc2607-telemetry` logs per-core `c6cores=[...]` every 2 s, so cpu20/21 now appear there and a post-change freeze's last NAS line will show whether they were sleeping at death; `gc2607-link-telem` still discriminates drive-drop vs CPU-wedge. So if a freeze *does* recur, we can tell immediately whether re-enabling cpu20/21 deep sleep was implicated (it should not be) vs an ASPM-fix gap. New tool: `gc2607-cstate-clear.sh` (one-shot, idempotent, reversible — header documents the revert).
>
> — The CRASH #19 discriminator block (kernel implicated) follows.

> **✅ DISCRIMINATOR FIRED — CRASH #19 (2026-06-13 20:25:44 BST, kernel 7.0.12-201, 2 h 05 m uptime) — the PSR-off re-soak crashed ⇒ the morning's PSR/FBC/DC re-enable is EXONERATED; the 7.0.11→7.0.12 kernel bump is the implicated delta. Pre-registered call: revert to 7.0.11 and re-soak.**
>
> The crash #18 discriminator ran exactly as designed: 7.0.12 with display PM reverted to the 64 h survivor's value (`i915.enable_psr=0`, no `enable_fbc`/`enable_dc`), cstate marker `test1b`, no `max_cstate` cap — leaving the **kernel version as the only remaining difference from the survivor**. It silently froze after **2 h 05 m** (boot 18:20:21 → last local entry 20:25:44; auto-reboot 20:26:47). **Same family signature:** DISK-FIRST (NAS journal-capture healthy to **20:26:14 = +30 s** past the local journal), **zero kernel errors** across the whole crash boot (triage grep empty bar normal boot lines + a clean 20:02:53 s2idle resume), **pstore empty** with `nmi_watchdog=panic` + ramoops armed and address-parity matched (`0x200000@0x85f600000`), `unsafe_shutdowns` 44→**45** (exactly one unclean shutdown since #18; the 17:28→18:20 reboot to start the soak was clean). Evidence pack `/var/log/gc2607-crash-triage/20260613-202717`.
>
> **What it proves (single-variable, by construction):** PSR-off did **not** prevent the freeze, so **display PM (PSR2/FBC/DC9) is exonerated** as the cause of #18. The only config delta left between this 2 h crash and the 64 h survivor is **kernel `7.0.11-200` → `7.0.12-201`** — the pre-registered "crash ⇒ it's the kernel, revert to 7.0.11" branch (`gc2607-psr-experiment.sh` header; #18 block).
> - **cpu20/21-C6 cure stays falsified:** the final telem sample before death is `c6cores=[0..19]` (cpu20/21 held OUT of C6 the whole soak — `test1b` engaged) and it died anyway, exactly as #18.
> - **Thermal not it:** pkg cycled 73–102 °C under the same XPU `cal_study/mvou` training as the survivor (GPU IRQ on cpu2 throughout) — common stressor, not a differentiator.
> - **Suspend not it:** one clean s2idle resume at 20:02:53, then ~23 min of normal operation before the wedge — not a resume hang.
>
> **Tally on the `test1b` cstate config:** 7.0.11 = **1/1 survived** (64 h); 7.0.12 = **0/2** (#18 7.5 h with PSR on, #19 2 h with PSR off). Two-for-two crashes on 7.0.12 vs a 64 h clean stretch on 7.0.11 is a real signal — but still **n=1 per cell** on a high-variance failure (family range 52 min–7.7 h crashes, one 64 h survival), so this is *consistent with* the kernel being the trigger, not yet proof.
>
> **NEXT (pre-registered): boot 7.0.11 and re-soak.** 7.0.11 is the pristine Phase-1b fallback (already `psr=0`, `test1b`, no cap — `gc2607-psr-experiment.sh` refuses to touch it), so reverting the kernel is the **only** change vs the crashed soak → a clean single-variable test of the kernel hypothesis. **Set 7.0.11 as the GRUB default** (not just pick-at-menu) so a crash+auto-reboot during the soak can't silently bounce back to 7.0.12 and contaminate the run: `sudo grubby --set-default=/boot/vmlinuz-7.0.11-200.fc44.x86_64 && systemctl reboot`. Decision fork: **7.0.11 goes long again (days)** ⇒ the 7.0.11→7.0.12 bump is a real regression — stay on 7.0.11, and the kernel changelog becomes worth diffing/bisecting; warranty can stay parked. **7.0.11 also freezes at ~hours** ⇒ the 64 h was a lucky tail, software is exhausted, and the DISK-FIRST / zero-error / empty-pstore signature on a part with `unsafe_shutdowns` 45 / `percentage_used` 1 % is **hardware ⇒ Huawei warranty** with the full dossier. Warranty branch stays OPEN until this resolves; instrumentation stays up.
>
> — The CRASH #18 block (the discriminator setup, now resolved above) follows.

> **⚠️ CRASH #18 (2026-06-13 ~17:27:44 BST, kernel 7.0.12-201, 7 h 32 m uptime) — THE "CASE CLOSED" VERDICT BELOW IS FALSIFIED. The cpu20/21-C6 "cure" is refuted from BOTH directions; the only survive-vs-crash deltas are the kernel bump + PSR/FBC/DC re-enable, NOT C-states. No guess as to which of those two — n=1, confounded.**
>
> Same family signature: silent freeze, **DISK-FIRST** (local journal ends 17:27:44, NAS journal-capture stream healthy to **17:28:11 = +27 s**, `gc2607-telem` still sampling `load=0.56 pkg=75C` at the NAS tail), **zero kernel errors** (triage section-4 grep empty; no nvme/blk/ata/timeout lines anywhere in boot -1), no shutdown sequence, **pstore empty** despite `nmi_watchdog=panic` + ramoops both armed and address-parity matched across boots (`0x200000@0x85f600000`). `unsafe_shutdowns` 43→**44**. Auto-reboot 17:28:43. Evidence pack `/var/log/gc2607-crash-triage/20260613-175924`.
>
> **Why this falsifies the cpu20/21-C6 cure (telemetry, not theory):**
> 1. **The crash run (boot -1) held cpu20/21 OUT of C6 *perfectly*** — 0 of **12,299** `gc2607-telem` samples show cpu20/21 in `c6cores` — and it crashed at 7.5 h.
> 2. **The 64 h "clean" run (boot -2, 7.0.11) did NOT hold them out** — cpu20/21 appear in `c6cores` **616 times** (all 06-10 evening) — and it survived.
> ⇒ cpu20/21-C6 is **neither necessary nor sufficient** for the freeze. The 06-13 "Phase-1b is the cure" verdict rested on a point-in-time `cstate` check at apply time, not the run's telemetry distribution; the soak that "proved" it actually ran with cpu20/21 entering C6.
>
> **Thermal load is NOT the differentiator:** the 64 h survivor ran *hotter* (pkg 100 °C ×1806, 103 °C ×76, 104 °C ×25, **105 °C ×3**; 269 k+ throttle events) than the crash run (100 °C ×534, 104 °C ×5). Heavy XPU training (`cal_study/mvou`; syncthing shipping `last.ckpt` confirms it ran) was present in **both** runs — so the user's "jobs that were running" is a real stressor but is common to survivor and crash, so it does not explain the crash.
>
> **The ONLY config deltas between survive (boot -2) and crash (boot -1)** — full `/proc/cmdline` token diff:
>
> | | survived 64 h (boot -2) | crashed 7.5 h (boot -1) |
> |---|---|---|
> | kernel | `7.0.11-200` | **`7.0.12-201`** |
> | display PM | `i915.enable_psr=0` | **`enable_psr=2 enable_fbc=1 enable_dc=4`** |
>
> Everything else identical (`mem_sleep_default=s2idle`, `nmi_watchdog=panic`, `watchdog_thresh=10`, ramoops, `nvme.max_host_mem_size_mb=0`, **same cstate marker `test1b`, no `max_cstate` cap** → the C-state setup was UNCHANGED across survivor and crash). The PSR/FBC/DC re-enable was a *post-verdict battery-tuning change made the morning of 06-13* (`gc2607-finalize.sh`, "re-enables PSR on 7.0.12 only"), hours before the crash; `i915-watch` was the **last subsystem still logging** before the wedge (limped 17:27:34/:39/:44 alone after gc2607-telem stopped at :29).
>
> **VERDICT: REOPENED.** Proven: cpu20/21-C6 cure falsified (both directions); thermal not the differentiator. Uneliminated & confounded (n=1): **{kernel 7.0.11→7.0.12, PSR/FBC/DC re-enable}** — no guess which. Clean discriminator (both kernels already installed): boot **7.0.12 with PSR/FBC/DC OFF** (`i915.enable_psr=0`, drop `enable_fbc=1`/`enable_dc=4`) and re-soak — isolates display-PM from the kernel bump (survive ⇒ PSR/DC was it, keep 7.0.12 minus deep PSR; crash ⇒ it's the kernel, revert to 7.0.11). Booting 7.0.11 alone re-confounds (reverts BOTH variables). **The "no warranty / hardware-branch-closed" conclusion is NOT re-closable** — it was downstream of the now-falsified cure.
>
> — The (now SUPERSEDED) 06-13 "CASE CLOSED" verdict follows. ⚠️ Its *causal* claim is refuted by the block above; its *factual* migration + battery notes still hold.

> **VERDICT 2026-06-13 — CASE CLOSED [⚠️ SUPERSEDED — causal claim FALSIFIED by CRASH #18 above]. Phase 1b SURVIVED ⇒ SOFTWARE fix, no warranty.** Phase 1b (C6-off on the LP-E cluster cpu20/21 only, C6 on for the other 20 cores) ran **~64 h clean on 7.0.11** from the 06-10 17:24 boot, uninterrupted across **three clean overnight s2idle suspend/resume cycles** (06-10→11, 11→12, 12→13, each ~10–12 h, all `PM: suspend exit` clean). That is **~8× past Phase-1's 8h18m wedge** and past the shortest-ever survival in the family (7.7 h) and every one of the 17 prior crashes. The user called the soak at the ~64 h mark ("close enough"; it was already far past any reasonable survival bar). **Conclusion: deep-sleep C6 on the two low-power-island cores (cpu20/21) was the trigger; holding just those two cores out of C6 is the cure — a 2-core C-state config, not a board fault.** No Huawei warranty, no mainboard swap, no drive wipe; Phase 2 (hardware) is not reached. The standing fix is the marker `/etc/gc2607-cstate-mode=test1b` + `gc2607-cstate-test.service` (re-applies Phase-1b every boot, kernel-agnostic; the cmdline cap `intel_idle.max_cstate=1` still overrides it to full global-off = the 7.0.10 PROTECT fallback).
>
> **Post-verdict actions (2026-06-13):** (1) **Migrated 7.0.11 → 7.0.12-201.** Rebuilt the *patched* `ipu-bridge.ko` (carries `GCTI2607`/`gc2607`, byte-size-identical to the 7.0.11 build) and `gc2607.ko` for 7.0.12 (both vermagic-verified) — `ipu-bridge-oot/7.0.12/`, repo-root `gc2607.ko`. One idempotent sudo step `gc2607-finalize.sh` installs both into `/lib/modules/7.0.12-201.fc44.x86_64/extra/`, removes the global C6 cap from the **7.0.12 entry only** (so the marker drives Phase-1b), re-enables **PSR on 7.0.12 only** (`i915.enable_psr=2 enable_fbc=1 enable_dc=4`), and sets 7.0.12 default. **7.0.11 is kept as a pristine Phase-1b fallback** (psr=0, no cap). Post-reboot check: `gc2607-verify-712.sh`. (2) **Battery tuning** (the 2–3 h runtime was untuned Linux power mgmt, 98 % cell health): `tuned-adm profile balanced-battery`, `cursor-blink`/`enable-animations` off (gsettings, live), iwlwifi/audio `power_save=1`. Because the verdict is *software*, the cpu20/21-held-awake deep-idle tax is **permanent** ⇒ realistic **~4.5–5 h light use (≈2×)**, not the ~7–8 h true-idle that a board repair would have unlocked. **Do NOT install `intel-lpmd`** — it parks work onto cpu20/21 and would undo the cure. (3) **Closed:** the Huawei warranty thread and the pending Windows/HWiNFO LP-E check (both were hardware-branch artifacts).
>
> — The CRASH #17 block (the discriminator that sent us to Phase 1b) follows.

> **CRASH #17 (2026-06-10 ~17:23:37 BST, kernel 7.0.11) — PHASE 1 WEDGED: the GPU-interrupt (software) hypothesis is REFUTED on-machine; the surviving signature is MTL066 cross-core (hardware). Climbed to Phase 1b.** The 09:05:35 boot ran the pre-registered **Phase-1 TEST1** config correctly — boot-service log `TEST1 applied: i915 IRQ=200 pinned cpu2 (got cpu2); C6 OFF on cpu2; C6 ON on all other cores` — and died at **17:23:37** (`last`=crash; **8 h 18 m** uptime, in family — the shortest-ever survival was 7.7 h). **The discriminator is clean and decisive.** The off-box telemetry (`gc2607-telem`, 2 s cadence, on the NAS) ran healthy to the wedge; its final samples show the GPU interrupt on cpu2 the whole time and **cpu2 never once in C6** (capped, `disable=1`), while the **other 21 cores were actively entering C6 right up to death**: last sample `2026-06-10T17:23:36 irq200=cpu2 d=412 c6cores=[0,1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21] pkg=102C f=400-4100MHz load=4.30`. So **parking the i915 interrupt on an always-awake P-core did NOT prevent the freeze** ⇒ the "GPU interrupt parked on a low-power core that then enters C6" mechanism (Arch BBS 308313, the centerpiece of the 06-09 reopening) is **dead for this machine**; what remains is **MTL066** — a core encountering incorrect data when *other* cores enter C6. Disk-vs-net was **~simultaneous** (local journal ends 17:23:37, last NAS telem 17:23:36 — within one 2 s sample), consistent with an all-at-once platform wedge rather than a peripheral dying first. **pstore empty again** (17/17), `nmi_watchdog=panic` never fired; the on-boot auto-triage (`gc2607-boot-incident.service`) fired at 17:25:05 → evidence pack `/var/log/gc2607-crash-triage/20260610-172505`. TEST1 was confirmed genuinely armed (not a launch-failure like the 06-10 08:38 boot) by the boot-service log and the live config.
>
> **Phase-1 verdict (pre-registered): wedge ⇒ Phase 1b — no improvisation.** **PHASE 1b APPLIED LIVE 2026-06-10 ~17:5x (`gc2607-arm-phase1b.sh`):** C6/C10 disabled on the **LP-E cluster cpu20/21 ONLY** (confirmed LP-E = the two cores capped at 2.5 GHz / `cluster_id=64`; cpu0–11 = P @ 4.8–5.1 GHz, cpu12–19 = E @ 3.8 GHz), C6 **ON** on the other 20, GPU IRQ still pinned cpu2, irqbalance masked. Tooling: `gc2607-cstate-test.sh` gained a `test1b` mode selected by the marker `/etc/gc2607-cstate-mode=test1b` (the cmdline cap `intel_idle.max_cstate=1` still wins → PROTECT, so the 7.0.10 fallback boots fully protected). Verified live: cpu20/21 `C6=1`, cpu0–19 `C6=0`, IRQ @ cpu2. This tests whether the SoC low-power-island's C6 is the specific trigger (the LP-E tile has its own power domain). **Verdict ~06-13 evening (72 h):** survive ⇒ LP-E C6 was the culprit = a free permanent **2-core** fix (no warranty; most battery/quiet recovered vs global-off); wedge ⇒ **Phase 2 = HARDWARE** ⇒ Huawei warranty, now with on-machine proof that selective C6-off cannot save it (strengthens the MTL066-defect dossier). Bail: `sudo /usr/local/sbin/gc2607-cstate-test.sh protect-now` (live global C6-off) or boot the 7.0.10 entry.
>
> — The CRASH #15 block follows.

> **CRASH #15 (2026-06-08 ~14:18, kernel 6.19.14) — Rung 0 FAILED; climbed to Rung 1 (global C6-off), now LIVE. Research corrected our own ladder: the arg is `intel_idle.max_cstate=1`, NOT `=2`.** Boot −1 (2026-06-07 19:22 → 2026-06-08 14:18, ~19 h) ran the full Rung-0 config — **HMB-off live** (`nvme.max_host_mem_size_mb=0`, cmdline-confirmed) + **BIOS 1.31** — on **6.19.14** (the holdback kernel; the 7.0.11 default only took effect on the post-crash boot 0). It died after ~19 h, squarely in the old ~daily cadence ⇒ **HMB-off + BIOS 1.31 are eliminated together** (and 6.19.14 re-confirmed non-immune, cf. #13). `gc2607-crash-triage.sh` verdict: **DISK-FIRST** — local journal ends **14:18:04** (`nvme-watch composite=57`), NAS stream carries a healthy system (`nvme-watch composite=58` at 14:18:35, `i915-watch pipeA 810000/4-lane` at 14:18:36) to **14:18:40**, **36 s past** the local death; the drive answered its own temp and the display link was full-HBR3 well after the journal froze. Zero kernel errors. `unsafe_shutdowns` 40→**41**. **pstore empty again** despite identical ramoops region across boots (`0x200000@0x85f600000`) and `nmi_watchdog=panic` armed — i.e. no oops path ran (silent wedge) or MTL032 warm→cold reset wiped it. **New visual symptom (user): a diagonal-pixelated frozen image at the black screen** — not in any log, and the display was healthy to the last second, so it is the **corrupting frozen scanout of a wedged SoC** (the display PHY keeps autonomously scanning out rotting framebuffer memory), which *corroborates* the platform-lockup diagnosis and is NOT an i915 software fault (those log `Atomic update failure`/`c10pll 61440`; none here). Evidence pack: `/var/log/gc2607-crash-triage/`.
>
> **Research pass (2026-06-08, two sourced briefs — user mandate "working fix, no guessing, research it"):**
> 1. **The arg in the old Rung-1 note (`intel_idle.max_cstate=2`-equivalent) was WRONG — it leaves C6 ON.** Verified against the kernel source `mtl_l_cstates[]` (`drivers/idle/intel_idle.c`: index 0=C1E, 1=C6, 2=C10) and the limiter `if (cstate + 1 > max_cstate) break;`, **and** this machine's live table (`state1=C1E state2=C6 state3=C10`): `=1` keeps C1E only (kills C6+C10); `=2` keeps C1E+C6. The correct global-C6-off arg is **`intel_idle.max_cstate=1`**. (Booting `=2` would have given a false-negative on the whole MTL066 hypothesis.) Sources: github.com/torvalds/linux/blob/master/drivers/idle/intel_idle.c; docs.kernel.org/admin-guide/pm/intel_idle.html; kernel-parameters.txt.
> 2. **Microcode is a dead end** — sig 06-aa-04 is at **0x28** (newest public, `microcode-20251111`); 2026 releases carry no MTL entry; no MTL erratum has ever shipped a microcode fix. We already run 0x28. Source: github.com/intel/Intel-Linux-Processor-Microcode-Data-Files/releasenote.md.
> 3. **MTL066 verbatim on-point:** *"Unpredictable System Behavior May Occur When C6 or Deeper Sleep States Are Used … a core may encounter incorrect data when other cores are entering Core C6 or deeper."* Workaround is BIOS-resident only; no "Fixed" status (Intel observed only in synthetic test). Source: Intel EDC spec-update 792254. C6 was **never globally disabled** in #1–#15 (crash #9 disabled it on the GPU-IRQ core only).
> 4. **Drive-side software is fully exhausted.** The LKML SN740 ASPM-L1 quirk targets device `15b7:5015` (ours is `15b7:5017`), is gated to a Qualcomm X1E devicetree, is still unmerged, and we already crashed ASPM-off (#12). No firmware channel for OEM `74117000` (live WD Dashboard catalog fetch: SN770/SN580 listed, zero SN740). The only public *silent* full-system SN740 wedge (Packett, lore linux-pci) is X1E and explicitly "not specific to any SSD model" — a PCIe-link/fabric issue, reproduced with a non-WD drive. AER blindness (`_OSC: no [AER]`, Huawei fw) is why our fabric faults log nothing. ⇒ a drive swap can't fix a host-side cause; the platform lever (C6-off) must be tried first.
> 5. **One free platform lever held for the next BIOS visit: disable Intel VMD in BIOS** — fixed a Meteor Lake freeze for one Arch user (BBS 308313); changes the NVMe host path. Can't be set from Linux; risks root re-enumeration; not stacked now (one clean variable).
>
> **RUNG 1 APPLIED 2026-06-08 (`gc2607-cstate-fix.sh`, runs via the sudo trampoline):** global **C6+C10 disabled on all 22 cores** — (a) **live this boot** via sysfs `state2/state3 disable=1` (no reboot), (b) **persisted** `intel_idle.max_cstate=1` on all kernels (`grubby --update-kernel=ALL`; default 7.0.11 confirmed), (c) **boot service** `gc2607-cstate-fix.service` re-asserts the live disable every boot (kernel-agnostic backstop). **Proven engaged:** the all-core C6 usage counter is **frozen** (delta 0 over a 4 s wall gap) while C1E keeps cycling (+113 k) — C6 entry has physically stopped, idle still works. Revert: `sudo ./gc2607-cstate-fix.sh revert`.
>
> **Decision tree from here (no more improvisation):** quiet ≈1 week (~06-15) ⇒ **MTL066 confirmed = the cause**, keep C6-off (optionally refine to per-core IRQ pinning to recover battery, per Arch 308313). **Crash again with C6 globally off ⇒ C-states EXONERATED** (the last free software lever spent) ⇒ cause is hardware: platform fabric (mainboard, Rung 3 / Huawei warranty with the evidence packs) or the SN740 link (Rung 2 drive swap) — plus the free BIOS VMD-disable to try at the next Windows/BIOS visit. **There is no remaining software guess after this rung.**
>
> **Windows-side check (2026-06-08, `gc2607-win-evtx-grab.sh`, read-only mount of `nvme0n1p3`): Windows has ZERO crash/hardware-fault history but is badly UNDER-TESTED — inconclusive, NOT exonerating.** Parsed System.evtx + Kernel-WHEA channels: **0** genuine WHEA-Logger hardware errors, **0** Kernel-Power 41 (unexpected hard shutdown), **0** BugCheck/BSOD (1001), **0** EventID-6008 — every Windows shutdown clean (22× 1074). BUT total Windows uptime EVER (since 2025-01-25, ~16 mo) is only **~45 h across 20 sessions, longest single session 17 h 03 m** — short of the ~19–115 h continuous-uptime window in which Linux crashes appear. So Windows has never run long enough to be a fair test: the logs neither prove immunity nor reproduce the fault. *(Discipline note: the first-pass parse falsely showed "73 fatal WHEA errors" — provider conflation; EventID 18/19/20 were from WindowsUpdate/TPM/Bluetooth/Kernel-Boot, re-parsed by provider = 0 real WHEA. No guesses.)* Evidence: `/home/ff235/dev/gc2607-v4l2-driver/win-evtx/`. **User uses Windows rarely ⇒ warranty path leans NO-WINDOWS: (a) the MTL066 firmware-defect argument (Intel says C6 needs a BIOS workaround; BIOS 1.31 evidently lacks it — proven if the live C6-off test makes Linux quiet), plus (b) the all-OS-software-eliminated matrix (2 kernel series × every power/driver/HMB setting all crash identically ⇒ fault is invariant to OS software). Optional ironclad add-on = ONE unattended weekend idle Windows soak (boot, set never-sleep, walk away — C6 entry peaks at idle, so near-zero Windows usage still tests the hardware).**
>
> **Onset timeline ("why now?", 2026-06-08, from `dnf history` + `rpm -qa --last`):** stable for months on F43; first crash 2026-05-16 was already on an F44 kernel (7.0.6) ⇒ F44 was installed before mid-May. Low-level changes bracketing onset: **`microcode_ctl-2.1-74.fc44` installed 2026-04-30** (~2 wk pre-onset — concrete CPU-microcode change candidate; we are now on 0x28, the newest, which research showed carries no MTL066 fix); `linux-firmware-20260519` + intel-{vsc,gpu,audio}-firmware installed **2026-05-22, AFTER onset** ⇒ not the trigger. **Reconciliation of "always-present erratum" vs "sudden onset" — the "F44 exposed/changed C6" story is now VERIFIED FALSE (sourced research 2026-06-08).** (1) `intel_idle` has had **C6 enabled by default for Meteor Lake since kernel 6.8** (commit `eeae55ed9c0a`, "intel_idle: Add Meteorlake support", Mar 2024) — C6 in the default table, no disable flag — so F43's 6.19 was ALREADY entering C6; F44 did not newly expose it. (2) The MTL `mtl_l_cstates[]` table is **byte-identical between the v6.19 and v7.0 kernel tags** (diffed): same C6 entry, exit_latency 140, target_residency 420, same flags — no change to C6 handling. (3) Microcode: machine runs **0x28** (verified: OS early-loads it over BIOS 0x1c), which shipped upstream ~Nov 2025 (microcode-20251111), five months pre-upgrade — Fedora ships microcode identically across F43/F44, so F43 almost certainly ran the same 0x28 (not machine-recoverable but high-confidence); NOT a differentiator. *(A research agent claimed "0x28 never shipped for 06-aa-04"; discarded — the running machine is on 0x28, ground truth wins.)* Our own data already showed F44's 6.19.14 crashes, so kernel version was never the variable. **F44 upgrade pinned to 2026-04-30** (2,334 pkgs reinstalled that day; journal starts 08:05); first crash 2026-05-16 (~2 wk later). **CONSEQUENCE:** no verified software mechanism for the onset survives — C6 enablement, kernel C-state code, and microcode are all unchanged across the boundary. Onset still time-correlates with the Apr-30 upgrade, but EVERY software layer that governs deep sleep is now checked and unchanged across the boundary: C6 default-on since 6.8; MTL C-state table identical 6.19↔7.0; microcode same 0x28; **kernel cpuidle CONFIG (`CONFIG_INTEL_IDLE=y`, governor `menu`, TEO/LADDER off) is stock Fedora default + byte-identical across F44's 7.0.11 and 6.19.14 builds; no C-state boot arg in the default cmdline; power daemon `tuned-ppd` on both F43 and F44 (Fedora switched at F41; governs freq/EPP not C-states)** (caveat: F43's literal config is gone, so this is "F44 = the release-invariant defaults F43 also ran," not a byte diff). With NO identified software cause surviving, the leading explanation is (b) **a hardware fault that developed ~late-Apr/early-May, the Apr-30 upgrade timing being coincidental**; the only residual software possibility is something subtler than any standard deep-sleep knob, which F43's vanished environment can't be diffed against. **This TILTS the balance toward a developing hardware fault** vs the earlier firmware-trigger framing (the software story didn't survive checking), though it does not prove it. The C6-off test still tests C6 causation directly; if it stops the crashes despite C6 being unchanged, that implies the silicon became MARGINAL to normal C6 use (hardware) or the BIOS still lacks Intel's MTL066 workaround. **Warranty framing improved: no software variable changed (same C-state code, same microcode, C6 always on) yet stable→daily-crashes with no rollback fixing it — the signature of a developing hardware fault.** **Correlation with a software upgrade ≠ software defect** — every kernel/driver/power rollback failed, so the upgrade pulled the trigger on a firmware/hardware flaw, it is not itself the flaw. Honest alternative kept live: a hardware fault that developed ~mid-May (F44 timing coincidental or merely surfacing a marginal part sooner) — the C6-off test discriminates.
>
> — The prior 06-07 diagnosis block follows, kept for history.

> **DIAGNOSIS (2026-06-07 evening — full evidence review + research pass): the failure is a PLATFORM-LEVEL HARD LOCKUP — the CPUs wedge and stop executing within seconds, before any software error path can run. It is not an OS/kernel-software fault, not flash/media failure, and the SN740 is the most frequent FIRST VICTIM but no longer the sole suspect.**
>
> **New facts that forced the re-read (NAS mining of crashes #8–#14 + whole-journal sweeps):**
> 1. **Zero kernel error lines in every crash window #8–#14, and zero NVMe errors in the entire retained journal (≥May 3).** The kernel has never once observed this drive misbehave across 14 deaths.
> 2. **4 of 5 measured disk-first deaths were faster than the 30 s NVMe I/O timeout** (#9 +18 s, #11 +20 s, #12 +5 s, #13 +18 s; only #10 reached ~+31 s). The assumed mechanism "stall → io-timeout → oops → panic" mathematically never fired in those four — something killed the CPUs first, silently.
> 3. **The NVMe admin path kept answering after the write path "died"** (#13: nvme-watch SMART beats on the NAS at +14 s; #14: SMART answered at −1 s). A wedged controller answers nothing; this pattern fits a host-side/fabric wedge better than a dead controller.
> 4. **`_OSC: platform does not support [AER]` on every boot** — Huawei firmware keeps PCIe error handling to itself; Linux is structurally blind to PCIe-level faults on this machine (kernel docs: without _OSC grant, the OS gets no AER events).
> 5. **Research (4/4 sourced SN740/SN770-family Linux+Windows failures are OS-VISIBLE** — `nvme: controller is down; will reset: CSTS=0xffffffff`, stornvme Event 11 BSODs, AER RxErr on the Surface quirk thread). Our 14 silent deaths do NOT match the documented drive-failure signature. **Exception that keeps the drive in play:** Val Packett (lore, SN740 ASPM-L1 thread) describes an SN740-linked FULL-SYSTEM FREEZE on Qualcomm X1E where cores are "*completely* wedged", respond to nothing, and log nothing — proof the drive CAN wedge a platform untraceably. But our #12 crashed with ASPM fully off, and #14's disk was alive to the end.
> 6. **Intel Meteor Lake errata cluster is on-point for the symptom** (spec update doc 792254): **MTL066** "unpredictable system behavior" from cores entering **C6** corrupting other cores (BIOS workaround flagged), MTL037/MTL042 RC6-exit hangs w/ MCE, MTL023 max-turbo hang, **MTL032 warm reset may become COLD reset** (would wipe a ramoops record even if one was written). Same-CPU corroboration: Arch BBS 308313 — **Core Ultra 9 185H silent freezes across all distros**, fixed by C-state disabling. **Hole in our elimination matrix: C6 was never globally disabled** — the #9 mitigation disabled C10 on all cores but C6 on only one core, leaving the MTL066 condition (other cores entering C6) fully live in every crash.
> 7. **Eliminated this evening:** iwlwifi firmware v89 as trigger (loaded since Apr 30, ≥3 weeks pre-crash-#1, never changed across the boundary — pop-os reports of v89 freezes noted but timeline acquits it here); microcode delta from BIOS 1.31 (0x28 effective before and after); BIOS 1.31 changelog (not public anywhere — documented absence, Huawei publishes none and the MS catalog anonymizes entries).
> 8. **No same-model cluster exists** (2024 X Pro / VGHH): no owner report of silent hard-resets on any OS — this machine is so far a population of one, consistent with either a marginal unit or an untriggered-elsewhere config.
>
> **Pre-committed test ladder (no more improvisation; each rung decisive for its hypothesis, ~1 week per rung since crashes were ~daily):**
> - **Rung 0 (LIVE since 06-07 ~18:25): BIOS 1.31 + HMB-off** (+ kernel forward to 7.0.11 — kernel exonerated, holdback reverted, see below). Quiet through ~06-14 ⇒ keep everything, case closed.
> - **Rung 1 (crash #15): run `gc2607-crash-triage.sh` (one command, <30 s, prints disk-first/net-first verdict) ⇒ then disable C6 globally** (`intel_idle.max_cstate=2`-equivalent via sysfs unit or boot arg; battery cost accepted for a week) — direct MTL066 test, free and reversible.
> - **Rung 2 (crash on C6-off): drive replacement** (logistics in the 06-07 morning block) — last host-side lever; the X1E precedent keeps it justified.
> - **Rung 3 (crash after swap): mainboard — Huawei warranty service** with the evidence packs.
>
> **Also this evening: kernel moved forward** — 7.0.11-200.fc44 is default with the full arg set (HMB-off, ramoops, watchdog, psr-off; crashkernel dropped), `UPDATEDEFAULT=yes` + `installonly_limit=3` restored, camera modules verified resolving for 7.0.11, 14 stale `/lib/modules` dirs swept (`gc2607-kernel-forward.sh` phase 1; phase 2 purges 6.19.14 + the koji stash after the next reboot, then self-deletes). Permanent triage tool: `gc2607-crash-triage.sh` (validated against #14: NET-FIRST verdict). Research sources: Intel EDC 792254 errata pages; bbs.archlinux.org/viewtopic.php?id=308313; lore.kernel.org/linux-pci/20251120161253.189580-1-mani@kernel.org (+ Packett reply); gpdstore.net KB; docs.kernel.org/PCI/pcieaer-howto.html.
>
> — The #14 narrative block follows.

> **CRASH #14 (2026-06-07 ~16:34:58) — the signature INVERTED; drive-only attribution now strained. Plan unchanged: HMB-off live (confirmed device-side) + BIOS 1.31, quiet ≈1 week ⇒ closed.** The post-#13 boot (08:53:52, ~7.7 h up, light load, cool — composite 43–44 °C / s1 54–56 to the end) died with **HMB still ON** (the staged arg only activated at the next boot) — so #14 extends the old config's ~daily cadence and does **not** count against the HMB-off test. `unsafe_shutdowns` 39→**40**; error log pristine (14 deaths, still no autopsy). **The new fact: the divergence ran the other way.** In #9–#13 the local journal died first while the NAS stream carried a healthy system 18–32 s past it. In #14 the **NAS stream died first** — at **16:34:52**, because the **iwlwifi firmware wedged** at ~16:34:51 (`SYSTEM_STATISTICS_CMD` timeout → error dump → "Device error - SW reset") and never recovered — while the **local disk demonstrably lived to the end**: journal entries persisted through **16:34:58.687**, and nvme-watch got a SMART answer at **16:34:57.4** — the controller was answering admin commands and completing writes ~1 s before end-of-evidence. Two readings: **(a) platform-level event** (PCH/fabric/power) progressively taking down peripherals in varying order before a hard reset — explains both orderings, the abruptness, and a controller that never logs its own death (the SN740 may be victim, not culprit); **(b) the established SSD stall starting right at the journal cut** (≥16:34:59) with the iwlwifi error a coincidence (baseline: exactly one benign iwlwifi error in the retained journal, May 22) — not disprovable, because both evidence channels were down in the final seconds (WiFi dead; disk state past :58.7 unknown). #14 is the first crash that genuinely strains the drive-only story; the discriminator for any future crash is **which channel died first**.
>
> **Recorder post-mortem — custody was broken; the #14 verdict is unknowable, not negative.** Ramoops was armed and unobstructed (same region `0x200000@0x85f600000` on the crash boot and every reader boot; kdump unloaded hours before), yet pstore is empty — but three findings void the inference: (1) **`CONFIG_PSTORE_CONSOLE` is not set in the Fedora kernel** — the `console_size=0x100000` param was always dead weight; only an oops/panic dmesg record (`max_reason=2`) can ever be written; (2) **`systemd-pstore.service` was disabled** — a record surfacing in the 16:35–18:04 boot's `/sys/fs/pstore` stayed RAM-only; (3) the same-evening **Windows + BIOS-flash trip power-cycled the RAM** and wiped the region. Whether #14 panicked is unknowable. **Fixed: `systemd-pstore` enabled** (`gc2607-fix-pstore-archive.sh`) — any future record is archived to `/var/lib/systemd/pstore` (on disk) seconds after boot and survives power cycles. **Still open: the recorder is unvalidated end-to-end** (a warm reset may or may not preserve the region through memory retraining on this platform); one deliberate `sysrq-c` panic at a convenient reboot moment would settle it in 2 minutes.
>
> **Windows trip results (same evening): BIOS 1.29 → 1.31** (build 2026-03-18) via Windows Update — the public-web "nothing past 1.29" was wrong; the serial-gated channel had one. **SSD firmware untouched: 74117000, single slot** — Windows did not flash the drive. BIOS 1.31 joins HMB-off as a second live variable: quiet week ⇒ no attribution between them (outcome over attribution); crash ⇒ both eliminated at once. **PC Manager catalog check answered same evening (user ran it during the trip): BIOS only, NO SSD-firmware entry — the last official SN740 fw channel is closed permanently.** Side effect: Windows wrote **local time to the RTC** (first post-Windows boot stamped +1 h until chrony stepped back) — harmless; set `RealTimeIsUniversal` on the next Windows visit or ignore. **HMB-off confirmed live device-side on the current boot** (`nvme get-feature 0x0d`: EHM Disabled, HSIZE 0) — **the quiet-week clock starts 2026-06-07 ~18:25 BST.** Evidence: `/var/log/gc2607-crash14/`.
>
> — The prior 06-07 block follows, kept for history.

> **ROOT CAUSE CLOSED — THE DRIVE. 2026-06-07 (crash #13): the kernel-holdback theory is dead — the SN740 died on 6.19.14-300.fc44 (the F44 GA kernel, the "empirically stable series") within ~23 h of the holdback, under light desktop use, cool.** Local journal ends **08:53:00**; the NAS stream carries a fully healthy system past it (nvme-watch composite 53 °C / s1 70–73 °C at 08:53:14, i915-watch clean at 08:53:17, kernel input events at 08:53:18) — ≥18 s divergence, then silence; self-reboot, new boot 08:53:50. `unsafe_shutdowns` 38→**39**; error log still pristine (the controller has never logged any of its 13 deaths). snapd restarted at 08:52:07 (background write burst, refresh-shaped) right before death — consistent with the write-path trigger. **The elimination is total: 3 kernel series (6.19.14 / 7.0.10 / 7.0.11) × the full ASPM/APST matrix × hot and cool × heavy and light load — every cell crashes, and no firmware channel exists for the OEM SKU. The "6.19.x was stable for months" history was survivorship: the drive has degraded into this failure mode. Decision (pre-committed 06-06, triggered now): REPLACE THE DRIVE.**
>
> **Why ramoops caught nothing (recorder flaw, fixed 06-07):** kdump was still armed. In the kernel panic path `__crash_kexec()` transfers control to the crash kernel *before* `kmsg_dump()` runs — a loaded kdump kernel starves ramoops of the panic record, then fails to save the vmcore (target on the dead disk) and reboots: here it can only destroy evidence. **kdump disabled + crash kernel unloaded** (`gc2607-crash13-evidence.sh`; evidence pack at `/var/log/gc2607-crash13/`); `kernel.panic=10` + `panic_on_oops=1` keep the self-reboot. Ramoops is now the sole, unobstructed recorder — any further crash before the swap finally yields a backtrace.
>
> **Interim until the swap (`gc2607-interim-mitigation.sh`, applied 06-07):** snap auto-refresh held indefinitely; **HMB-off promoted from staged-experiment to live mitigation on 6.19.14** (`nvme.max_host_mem_size_mb=0` — the DRAM-less SN740/SN770 family has a documented HMB-corruption crash history, cf. the Windows 24H2 BSOD wave); `crashkernel=` dropped from the entry (kdump dead, reclaims the 256M reservation). Active from the next reboot. Heavy build jobs are no longer "useful load" — minimize write bursts and unsaved work until the swap.
>
> **Replacement logistics:** the OEM drive is **2,048,408,248,320 bytes (2048 GB class)** — retail 2 TB drives are 2,000,398,934,016 B, **48 GB smaller: a raw dd clone will NOT fit**. Either (a) shrink the btrfs on p8 by ~60 GB (online `btrfs filesystem resize`, then shrink the partition from a live USB) and clone partition-aware (Clonezilla), or (b) buy 4 TB and dd-then-grow. The disk is dual-boot — p3/p5/p6 NTFS (Windows) ride along in the clone. Model `SDDPNQE-2T00` ⇒ M.2 **2280** expected (E-suffix; the D-suffix SKUs are 2230) — verify physically at swap time. Keep the old SN740 as evidence; never use it as an OS disk again.
>
> **REVISION, same day (user pushback "new laptop, clean SMART, have you researched?" → fresh research): replacement demoted to contingency; HMB-off test promoted to the primary action.** The Windows 11 24H2 saga is the documented precedent on this exact controller platform: WD DRAM-less drives (retail SN770/SN580/SN5000) **"stall mid-operation and drop offline"** from firmware bugs in host-memory-buffer handling, **only the 2 TB models** (this drive: SN740 **2 TB**), acknowledged by Sandisk/WD with critical firmware fixes (731130WD/281050WD/291020WD) — for retail only; the OEM SN740 has no channel (Dashboard lists none; Framework forum documents a failed attempt to extract SN740 firmware from Dell's updater). Linux-side corroboration: Framework "nvme0: controller is down" freezes, SN770s dropping off the bus on WD's own forums, plus the upstream LKML SN740 quirk. **Reading updated: latent firmware defect (present from manufacture, trigger conditions assembled in May) now leads over progressive physical degradation** — it explains new-drive + 1%-wear + months-clean + sudden cluster + crashes-on-any-kernel. SMART stays moot either way: it audits the flash (genuinely healthy), not the controller's execution; a hung controller logs nothing (error log 0 across 13 deaths = no autopsy, not health). Crash #13 ran with HMB ON; `nvme.max_host_mem_size_mb=0` is staged and activates next reboot, making the buggy path unreachable. **Quiet ≈1 week with HMB off ⇒ keep drive + arg permanently. Crash with HMB off ⇒ every host lever exhausted ⇒ replace (shop / Huawei warranty / external TB4 boot — user won't self-open).**
>
> **Peer-report sweep (06-07, user asked):** no documented cluster for the 2024 MateBook X Pro itself (the one detailed Linux-on-this-model writeup reports no storage issues; the Windows MateBook storage-BSOD threads are 2018 units with Lite-On drives — one fixed by SSD swap, same no-dump-created signature). The *drive* population is where the reports live: GPD ships the same SN740 2TB in handhelds and has a support KB for this crash class (KERNEL_DATA_INPAGE_ERROR / stornvme controller errors = the Windows rendering of our signature). **New lead from its comments (Nov 2025, single report): SN770 fix firmware `731130WD.fluf` manually flashed onto an SN740 via SanDisk Dashboard "without any issues."** Caveats before ever trying: one anecdote; our fw family is **74117000** vs the 73xxxx retail line (Dell/Lenovo SN740 73xx SKUs differ — cross-family flash = rejection-or-brick territory); total-data-loss warning; Dashboard is Windows-only. **Ranking unchanged: HMB-off test first; cross-flash only as a fully-backed-up deliberate step if HMB-off proves the mechanism but we want HMB back, or as last resort before replacement.** GPD article: gpdstore.net/kb/gpd-duo-support-hub/kb-article/wd-sandisk-2tb-ssds-and-windows-11-24h2-crashes/
>
> — The prior 06-06 block follows, kept for history.

> **SUPERSEDED 2026-06-06 (crashes #11/#12) — the ASPM/APST mitigation below FAILED; the power-state theory is dead. The failure mode (NVMe write-path death) stands, but no host-side power knob prevents it. Remediation pivoted to: kernel held back to 6.19.14 (the empirically stable series), ramoops armed, HMB-off staged on 7.0.x, NVMe temp telemetry to the NAS.**
>
> **Crash #11 (2026-06-05 ~17:10):** boot of 06-04 22:40 (no mitigation boot args; ASPM off via live sysfs since 09:47:53, **APST still ON** — the live set-feature had hung and was abandoned, so that boot never got APST-off). Local journal ends **17:10:36.7** mid-health; NAS stream continues with a fully healthy system (i915-watch beats with fresh PIDs 2491061→2491755, display at 810000/4-lane, tailscaled re-resolving endpoints at 17:10:49) until **17:10:56** — ≥20 s divergence. Next boot's first kernel line 17:11:31 fits the 30 s I/O-timeout panic + ~12 s firmware. An OOM kill at 10:39 (a 7.5 GB BEAM process, recovered cleanly) was 6.5 h earlier — unrelated.
>
> **Crash #12 (2026-06-05 ~21:50) — the decisive disproof:** boot of 17:11:31 carried **both staged args live from boot** (`pcie_aspm.policy=performance` + `nvme_core.default_ps_max_latency_us=0`, confirmed in that boot's `/proc/cmdline` capture in the journal; link state under the same args verified `ASPM Disabled`, all `L1SubCtl1` substates minus). No suspend cycles, **light interactive use** (keyboard input 21:42–21:47, nothing heavy in the journal). Local journal ends **21:50:58.6**; NAS gets one more healthy beat at **21:51:03** then silence; new boot 21:51:35. Same storage-death-first signature, full mitigation active. **The 2×2 matrix is complete and every cell crashes: APST-on/ASPM-on (#10 and earlier), APST-off/ASPM-on (#9), APST-on/ASPM-off (#11), both-off (#12). Host-controllable power management is exonerated as the trigger — the LKML SN740 ASPM-L1 quirk cannot fix this machine.**
>
> **Channel research (2026-06-06, all dead ends for a firmware fix):** WD/SanDisk Dashboard catalog (`sddashboarddownloads.sandisk.com/wdDashboard/config/devices/lista_devices.xml`) lists **no SN740 at all** (OEM-only drive; WD points OEMs at their own updaters). LVFS: nothing for `SDDPNQE-2T00-1127` (fw 74117000) nor for the Huawei BIOS (still 1.29). Dell/Lenovo SN740 updater EXEs exist but carry an **older firmware family** (7310.4012/7391.4108) for *their* SKUs, and OEM drives reject foreign firmware — not a path. Huawei BIOS updates ship only via PC Manager (Windows); worth one check there, but no public changelog suggests a fix.
>
> **New controller-side evidence (06-06 diag):** `unsafe_shutdowns` 36→**38** (both crashes registered as power loss at the drive). Error log still pristine (64 entries, all zero — the controller has never managed to log its own death). **Thermal is a live co-factor:** Sensor 1 (controller die) reads **91–93 °C under ordinary build I/O**, and lifetime counters show **13 min above the critical composite temperature** (Warning Temperature Time = Critical Composite Temperature Time = 13 min, T1/T2 trans counts 0 — host thermal management never configured). Heavy-job crashes fit a hot-controller wedge; #9/#12 (light use) fit it less well — co-factor at ~25–30 %, kernel-7.0 host interaction remains the front-runner given the clean F43/6.19 history.
>
> **Remediation applied 2026-06-06 (`gc2607-system-fix.sh`, logged to `/var/log/gc2607-system-fix.log`):**
> 1. **Reverted** `pcie_aspm.policy=performance` + `nvme_core.default_ps_max_latency_us=0` from all kernels (disproven; recovers the 0.5–1.5 W).
> 2. **Kernel 6.19.14-300.fc44 installed and made default** (koji; it is the F44 GA kernel, native fc44 build — no cross-release risk). Rationale: every one of the 12 crashes is on 7.0.x; 6.19.x carried this same drive for months crash-free. `installonly_limit=4` + `UPDATEDEFAULT=no` so future 7.0.x updates neither evict it nor steal the default.
> 3. **Camera stack made whole for both kernels:** the depmod override conf had `ipu_bridge` (underscore) which **never matched** — overrides key on the file stem `ipu-bridge`; fixed. Patched ipu-bridge (GC2607 entry) rebuilt OOT for 7.0.11 **and** 6.19.14 (`ipu-bridge-oot/`), gc2607.ko built for 6.19.14, installed to `extra/` with kernel-loadable xz (`--check=crc32 --lzma2=dict=1MiB` — plain `xz -9` produces modules the kernel cannot decompress). The 7.0.11 boot's camera (down all morning, service crash-looping at restart #105 on "GC2607 not in media topology", then "gc2607.ko not found") is fixed live; service script now accepts `extra/gc2607.ko.xz` (`gc2607-fix-service-modload.sh`, backup kept).
> 4. **ramoops armed on all kernels** via `reserve_mem=2M:4096:ramoops` + `ramoops.mem_name=ramoops` (no manual memmap address math; kernel ≥6.11 feature) + `/etc/modules-load.d/ramoops.conf`. RAM pstore survives the warm self-reboot — the next crash, if any, finally yields the oops backtrace that tells drive-died vs host-died.
> 5. **HMB-off staged on the 7.0.x entries only** (`nvme.max_host_mem_size_mb=0`): the one untested host↔drive layer (DRAM-less drive, 32 MiB host buffer, HMB confirmed enabled at 0x18125000). 6.19.14 left pristine — it is the control configuration, validated by its own history.
> 6. **NVMe temp telemetry:** `nvme-temp-watch.service` (user unit, hwmon is world-readable) logs composite/s1/s2 every 5 s → journal → NAS capture, so any recurrence shows the drive's thermal state in the final seconds.
>
> **Decision tree from here:** stable on 6.19.14 → 7.0 host regression confirmed by elimination; revisit on 7.1+ (with HMB-off first, then pristine). Crashes on 6.19.14 too → read ramoops + nvme-watch: hot-at-death ⇒ thermal/hardware (re-pad or replace drive); cool-at-death ⇒ drive firmware regardless of kernel ⇒ replace drive (SMART is otherwise clean: 1 % wear, 0 media errors). Either way the next crash is no longer silent.
>
> — The prior 06-05 block follows, kept for history.
>
> ~~**SUPERSEDED 2026-06-05 (crash #10) — the i915 display lead below is WRONG for the deaths we can now see inside; the root cause is the WD PC SN740 NVMe dropping its write path, with the system surviving it by ~30 s before the armed panic stack reboots the box.**~~ *(06-06: the write-path death stands; the ASPM/APST mitigation derived from it does not.)*
>
> **Crash #10 (2026-06-04 ~22:39):** boot −1 (psr=0 live, APST back ON after the 06-01 revert) died 14.5 h after its last resume — no dwell adjacency. The decisive evidence is **NAS-vs-local journal divergence**: the local journal (per-line-flushed to the NVMe) ends at **22:39:16.7**, but the NAS stream carries on with a *completely healthy system* — kernel printk flowing, `i915-watch` hitting all seven of its 5 s beats with fresh PIDs (1350671→1351371), the display waking on its cycle at 22:39:32 at a perfect **810000/4-lane** link — until **22:39:48**. 32 seconds of entries exist on the NAS that never reached the local disk: **the NVMe stopped completing writes at 22:39:16.7 while everything else ran on out of page cache.** The display outlived the disk by 30+ s → i915 exonerated for this death. Stream stops 22:39:48–53 ≈ the stock **30 s NVMe I/O timeout** from the stall → nvme error handler → oops → `panic_on_oops=1` (armed 05-23) → kexec to kdump, which **cannot save a vmcore because `/var/crash` sits on the disk that just died** → failure-action reboot. Reset back-computed to ~22:40:03 via `systemd-analyze` firmware+loader (11.7 s) vs first kernel line 22:40:15. The user did not touch the power button.
>
> **Crash #9 re-read:** same signature. Its local journal ends 22:26:19; its NAS stream shows the dying boot alive and logging (Chrome, kernel input events) for 18+ s after — that is what the "18 s of normal run after the netns teardown" really was: the teardown was merely **the last write the disk ever completed**. And #9 ran with `default_ps_max_latency_us=0` live → **APST-off alone does not prevent the drop**; the remaining power layers are PCIe **ASPM L1/L1.2** and the controller's own firmware transitions (SN740 is DRAM-less, runs a 32 MiB host-memory buffer — a family with documented power-transition drop bugs and a long Linux record: Framework/Arch reports of SN740 falling off the bus at deep idle).
>
> **The self-reboot pattern hiding in wtmp:** every crash since the panic sysctls were armed on 05-23 rebooted on its own within ~36–90 s of journal death (#5 10:33→10:34, #6 15:50→15:51, #7 10:39→10:40, #8 14:21→14:22:01, #9 22:26:19→22:27:06, #10 22:39:17→22:40:15). Only #1–4 (pre-arming) sat dead needing the power button. So since 05-23 these were **never silent deadlocks — the kernel oopsed/panicked every time**; the evidence was simply unsavable (kdump target on the dead disk; EFI pstore nonexistent on this firmware). The "kdump caught nothing in 8 freezes ⇒ no panic" inference was inverted.
>
> **Why every earlier theory fit partway:** cpuidle/i915/dwell theories all orbited *power-state transitions* — which is the actual trigger class, just on the wrong device. "Fine before F44" = NVMe/PCIe power behavior changed 6.19→7.0. "Warm + drained after suspend" = an SSD misbehaving in deep states also blocks S0ix residency. Post-resume and idle-adjacent deaths = power-state churn windows. #10's 29 min of ~65 s lock-screen wake/blank cycling (a separate gnome-shell sickness after the 22:15:51 inhibitor-count corruption) churned the SSD through idle transitions ~28 times right before the drop.
>
> **Mitigation status (2026-06-05 09:47:53): ASPM is OFF, LIVE** — `LnkCtl: ASPM Disabled`, `L1SubCtl1: PCI-PM_L1.2- PCI-PM_L1.1- ASPM_L1.2- ASPM_L1.1-` on `0000:01:00.0` (was `PCI-PM_L1.2+ PCI-PM_L1.1+ ASPM_L1.2+` — BIOS-enabled, which validates the `pcie_aspm=off` gotcha below). Applied via `~/setup-nvme-fix-live2.sh` (sysfs only). APST-off is in the module param (covers any controller reset this boot) and joins fully at the next boot via the staged arg. **Do NOT use `nvme set-feature -f 0x0c` live on this controller:** the first live attempt (`~/setup-nvme-fix-live.sh`) hung >5 min in interruptible sleep with NO kernel admin-timeout ever firing and I/O unaffected — the command never reached the queue; killed cleanly, zero kernel residue. Watch bar runs from 09:47:53 (ASPM layer); full config from next boot.
>
> **Mitigation scripts (`~/setup-nvme-freeze-fix.sh` staged 06-05 morning; `~/setup-nvme-fix-live2.sh` applied it live):** `pcie_aspm.policy=performance` + `nvme_core.default_ps_max_latency_us=0` together (≈0.5–1.5 W idle cost). NOT `pcie_aspm=off` — that form stops the kernel *managing* ASPM and can leave BIOS-pre-enabled L1.2 active (thin MTL laptops enable it in firmware for S0ix); `policy=performance` actively clears ASPM on every link. Live application = `nvme set-feature -f 0x0c -v 0` (APST off now) + policy sysfs + per-link `link/l1*_aspm|pcipm` disables on `0000:01:00.0`. Controller-side diagnostics from the 06-05 run: error log **clean** (0 entries, 0 media errors, wear 1%) — no positive controller-side confirmation, consistent with both a firmware drop (a hung controller can't log its own death) and a host-side kernel-7.0 stack bug; the mitigation covers both. 36 unsafe shutdowns (matches history), 66 °C composite (in spec). No LVFS firmware newer than 74117000 for the OEM SKU. `i915.enable_psr=0` stays — free, and the 13 h dwell on boot −1 resumed clean with it. **Confidence: ~90%** (raised from 80% on 2026-06-05 by upstream corroboration): LKML Nov-2025 **"[PATCH v2] PCI: Add quirk to disable ASPM L1 for Sandisk SN740 NVMe SSDs"** — Manivannan Sadhasivam (PCI maintainer), reviewed by Bjorn Helgaas, with WD engineer Alexey Bogoslavsky in the thread (lkml.org/lkml/2025/11/20/1365, /2025/11/24/1650, /2025/11/25/1160). The quirk targets **ASPM L1 — the exact layer this incident's evidence singled out** (#9 died with APST off but ASPM on). Quirk is NOT in mainline `drivers/pci/quirks.c` nor in 7.0.10 (link sat at `ASPM L1 Enabled` until the manual fix); merge status unclear as of Dec 2025 (lkml/lore are bot-walled — recheck via mirror). When a quirked kernel ships, the global `pcie_aspm.policy=performance` can be narrowed back to quirk-only (recovers Wi-Fi/other-link power states). Possible contribution upstream: the NAS-divergence evidence + verifying the quirk's ID match covers the OEM SKU (`SDDPNQE-2T00`, 15b7:5017). Storage-death-first sequence remains directly evidenced for #9/#10; full local confirmation = clean watch bar. **If it recurs:** the tell is NAS-past-local divergence (`ssh nasff235`, compare last NAS line vs `journalctl -b -1 | tail -1`); next escalation is ramoops (RAM-backed pstore survives the warm self-reboot — set up interactively, the memmap reservation needs care) and `nvme.max_host_mem_size_mb=0` to test the HMB angle. — The prior i915-display block follows, kept for history.

> **SUPERSEDED 2026-06-01 (crash #9) — the cpuidle root cause below is WRONG; the lead is now the i915 _display_ driver, not CPU idle states.** Crash #9 froze ~22:26 after only **~4 h awake** (~49 min after resume from a **~4 h s2idle dwell**) with **every** cpuidle/NVMe mitigation verified live on the dead boot (`journalctl -t gpu-irq-cstate-fix -b -1`: all-core C10 off, **C6 off on the GPU-IRQ core cpu18**, IRQ 200 pinned to cpu18, irqbalance stopped; cmdline `nvme_core.default_ps_max_latency_us=0`). Fastest freeze in the catalog with the most complete fix applied → the cpuidle/IRQ/NVMe stack is **disproven**. The per-line NAS capture finally caught the run-up and it is silent: no nvme-timeout, no i915 error, no cleanup_net stall; the docker netns teardown that looked like "last activity" in #7/#8 is **exonerated** (NAS shows ~18 s of normal operation *after* the 22:26:19 teardown — it was the last disk *flush*, not the wedge). A `drm|PHY|dpll|flip_done` grep over all boots (0..−7) and the NAS log: **zero matches.**
>
> **New root cause (research-backed, confidence ~80%): an i915 _display_ regression in kernel 7.0 (F44), triggered by resume from a multi-hour s2idle dwell.** Two user-supplied facts nail the direction: (1) *"didn't happen before the F44 upgrade"* → stable on F43 = kernel **6.19.x**, broken on F44 = **7.0.x**; (2) *"warm + battery drained after suspend"* → the dwell reached little/no **S0ix** residency (failed deep sleep), and the display DPLL resumes *out of that broken state* wrong. Mechanism: the eDP link DPLL — the **"C10 PLL" in `drivers/gpu/drm/i915/display/intel_cx0_phy.c`, a DISPLAY PHY unrelated to the CPU C10 idle state the last three weeks chased** (that naming collision is what misdirected the investigation) — comes back parked at **61.44 MHz instead of 810 MHz HBR3**; the next atomic commit hard-hangs pipe A (`Atomic update failure on pipe A`) → total silent freeze, power-cycle required. The silent logs fit: the **no-`psr` hard-hang variant wedges before it can flush**, whereas machines with `i915.enable_psr=0` only get a 5–10 s slow wake and survive to log the `PHY A` / `c10pll clock: 61440` errors. Same-SoC reports: **Ubuntu LP#2150605** (Arrow Lake-S / "Meteorlake D0"; resume from 2 h+ s2idle dwell; `i915.enable_psr=0` converts hard-hang → slow wake; `enable_dc`/`enable_fbc` do NOT touch this path) and **Arch BBS pid=2297604** (linux-zen 7.x; **fixed by downgrade to 6.19.14; upstream fix in v7.1-rc1**).
>
> **Mitigation (cheap, single clean variable, NOT cpuidle):** `i915.enable_psr=0` via `~/setup-i915-psr-fix.sh` (downgrades hard-freeze → slow wake). **Avoid the trigger:** hibernate or power off for long breaks instead of multi-hour s2idle (hibernation is already wired — cmdline carries `resume=UUID`/`resume_offset`); this also kills the warm/drain. **Complete fix:** a patched kernel — roll to 6.19.x now (the known-good) or move to F44's 7.1 when it ships. **Confirm:** read `/sys/kernel/debug/pmc_core/slp_s0_residency_usec` (sudo) before/after the next suspend to prove the failed-S0ix → bad-resume chain and find any device blocking S0ix. **Wrinkles keeping confidence at ~80%, not higher:** our wedge lands ~49 min *after* resume (not *at* resume) and we log *none* of the PHY/dpll errors even non-fatally — so it may be a close cousin (a later display-power transition hitting the parked-PLL path) rather than the identical bug; crash #7 also froze 35 h after its last resume, which this mechanism explains less cleanly. See the **Crash #9** section for the full post-mortem. — The prior cpuidle root-cause claim follows, kept for history.

**~~ROOT CAUSE IDENTIFIED — 2026-06-01~~ (DISPROVEN by crash #9 — see the superseding block above; the cpuidle diagnosis is wrong, kept for history).** The i915 GPU MSI interrupt (IRQ 200) is delivered to a CPU core sitting in a **deep C-state**, and on Meteor Lake the wake-from-deep-C-state path for the GPU-IRQ core is unreliable; eventually a delivery hangs → GPU/display pipeline wedges → silent total freeze, no log. Confirmed three ways: (1) **local data** — IRQ 200 was on cpu8, and every core still had **C6 enabled** (`state2`, ~1.66M entries/boot); only C10 (`state3`, ~9.8k entries) was ever disabled; (2) **community consensus, same SoC** (Arch BBS 308313): *"i915/xe GPU interrupts are handled by a single LPI core by default … disabling only C10 proved insufficient — deeper states must be disabled on the GPU IRQ core"*; (3) **our crashes #7/#8** froze with C10 disabled, exactly as predicted because C6 was untouched. The `IRQBALANCE_BANNED_CPULIST=12-21` ban made it worse (forced the IRQ onto a C6-enabled P-core). NVMe APST / pcie_aspm / docker / the 7.0.9→7.0.10 kernel bump were all red herrings — community confirms **no kernel version fixes this** (through 7.0-rc); it's a firmware/cpuidle interaction needing a userspace workaround. **FIX (`~/setup-gpu-irq-cstate-fix.sh`, surgical + battery-friendly):** stop irqbalance, pin the i915 IRQ to one core (cpu18), disable C6+C10 on that core only (keep POLL+C1E), persist via `gpu-irq-cstate-fix.service`. Applies live, no reboot. Nuclear fallback: `intel_idle.max_cstate=1` on cmdline (caps all cores at C1E; battery cost). Watch: survive past ~115h clean (~2026-06-06). Sources in the Research section below. — Prior status follows.**

**Status:** **2026-06-01 — crash #8 at ~27.7h uptime. CORRECTION to the crash-#7 plan: the NVMe APST disable was NOT live on the dead boot — `~/setup-nvme-apst-disable.sh` has mtime 05-31 10:44, four minutes *after* boot −1 began (10:40), so it only took effect on the *next* boot. Boot −1's `/proc/cmdline` confirms it carried no `nvme_core...` arg. So crash #8 is a *second* data point for the C10-only config (same as #7), NOT the "both-disabled" test. Two C10-only data points now bracket 28h (#8) to 115h (#7): C10-off widens the variance but does not stop the freeze, and #7's 115h was favorable variance, not evidence APST mattered. A kernel bump (7.0.9-205 → 7.0.10-201) also rode in between #7 and #8; the freeze signature is unchanged, so the bug survived it. The "C10 + APST both off" test genuinely BEGINS NOW on boot 0 (first boot with `default_ps_max_latency_us=0`, verified live). NAS capture worked but lost the final ~70s to NAS-side `cat` block-buffering — fixed (per-line read-loop, verified). See the Crash #8 section. — Prior status below.**

**Prior status (2026-05-31, crash #7):** crash #7 at ~115h uptime WITH all-core C10 disabled (verified live on the dead boot). Per-core C10 exonerated as the *sole* cause, but believed a major accelerant: time-to-freeze went from 24–48h (#1–#6) to ~115h. C10 disable stays in place. Prime suspect was the WD PC SN740 NVMe APST (drive confirmed `SDDPNQE-2T00`, fw `74117000`; APST still ON, `default_ps_max_latency_us=100000`). Mitigation `nvme_core.default_ps_max_latency_us=0` on cmdline (`~/setup-nvme-apst-disable.sh`) — **but see the crash-#8 correction above: it did not actually activate until boot 0.** See the Crash #7 section.

## Open action items (as of 2026-05-31, crash #7)
The fixes and the capture survive reboots/crashes on their own (a kernel cmdline arg + a lingering per-user systemd service) — **independent of any editor/agent/terminal session, so closing one is safe.** Remaining steps:
- [x] Disk deep-sleep fix staged: `nvme_core.default_ps_max_latency_us=0` (grubby, all kernels) via `/home/ff235/setup-nvme-apst-disable.sh`. **Activates on reboot.**
- [x] **NAS capture LIVE (2026-05-31):** `bash /home/ff235/setup-journal-capture.sh` run; `journal-capture-nas.service` active+enabled, `journal-capture-rotate.timer` active+enabled, `Linger=yes` → auto-starts on every boot incl. post-crash cold boot. (Install hit a `%F`→`%%F` systemd-specifier bug, fixed in both the running unit and the script.) Streaming to `fedora-journal-2026-05-31.log` on the NAS.
- [ ] **Reboot** to activate the disk fix and begin the watch window. **Leave docker running** — just reboot (the `unless-stopped` containers auto-restart, which is wanted). Rationale: now that the NAS capture exists, there's no need to speculatively stop docker — testing the disk fix as a *single clean variable* gives an interpretable result, and if it freezes again the capture will reveal whether docker/netns was involved. Stopping docker now would only force a later bisect even in the success case.
- [ ] **Docker stop is the NEXT round, only if the disk fix fails (crash #8):** `docker stop $(docker ps -q --filter name=stratsense)` (`unless-stopped` keeps them down across a reboot).
- [ ] After reboot confirm live: `cat /sys/module/nvme_core/parameters/default_ps_max_latency_us` → `0`.
- **Watch bar:** freeze-free past ~115h (~2026-06-05).
- **If it freezes again:** first thing to grab is the NAS log around the crash time — `ssh nasff235 "tail -300 \$(ls -t /share/homes/ff235/freeze-capture/*-journal-*.log | head -1)"` (per-day files, last 7 kept). That is the first real chance at run-up evidence in seven crashes.

> **Superseded (2026-05-26):** **crash #6 refines the diagnosis (it is not a repeat of #5). The 05-25 E-core-only C10 disable did NOT prevent a freeze (~29h uptime, E-core C10 confirmed disabled), but the post-mortem shows why it could not have: the i915 GPU IRQ (IRQ 200) is delivered to a *P-core* — cpu3 at crash #5, cpu11 at crash #6 — and P-core C10 was never disabled. The 05-25 fix mistargeted cores. The C10 hypothesis is sharpened to "a GPU IRQ delivered to *any* core sitting in C10 wedges the display pipeline" (matches the same-CPU report at archlinux BBS 308313). Mitigation 2026-05-26: C10 disabled on ALL cores cpu0-21 (`~/setup-c10-disable-allcores.sh`, live + persistent, reuses `disable-ecore-c10.service`). Pure cpuidle, no irqbalance. Awaiting freeze-free confirmation past ~48h; if a freeze still occurs, per-core C10 is exonerated → next suspect is NVMe APST (WD SN740, see Crash #6 section).**

> **Superseded (2026-05-25):** irqbalance ban DISPROVEN by crash #5; E-core-only C10 disable applied as the first C10 test. Superseded by crash #6 — the disable was applied to the wrong cores (the GPU IRQ lives on a P-core).

> **Earlier (superseded) status:** Root cause identified 2026-05-23 — i915 IRQ pinned by irqbalance to a Meteor Lake E-core that enters C10; wake-from-C10 on E-cores is unreliable. Fix applied live: `IRQBALANCE_BANNED_CPULIST=12-21`. — Disproven, see 2026-05-25 section below.

## Summary

The MateBook freezes hard several times a week while in active use. Lid is open, system is being used (browser, terminal), then the UI locks up. No panic splash, no auto-reboot — required a power-button cold boot to recover. This is **not** the May 2 suspend hang (that fix `mem_sleep_default=s2idle` is still in place and active).

Crashes catalogued so far (4 confirmed):

| Date | Uptime at crash | Kernel | Boot index |
|---|---|---|---|
| 2026-05-16 09:55 | ~24h | 7.0.6 | -8 |
| 2026-05-17 09:33 | ~24h | 7.0.8 | -7 |
| 2026-05-21 16:06 | 43h | 7.0.8 | -2 |
| 2026-05-23 10:31 | 42h | 7.0.9-205.fc44 | -1 |
| 2026-05-25 10:33 | ~48h | 7.0.9-205.fc44 | crash #5 — see 2026-05-25 section (occurred *with* the irqbalance fix active) |
| 2026-05-26 15:50 | ~29h | 7.0.9-205.fc44 | crash #6 — *with* E-core C10 disabled + NMI-watchdog armed; GPU IRQ was on C10-enabled P-core cpu11. See Crash #6 section |
| 2026-05-31 10:39 | **~115h** | 7.0.9-205.fc44 | crash #7 — *with* ALL-core C10 disabled (verified: `disable-ecore-c10.service` ran on the dead boot, ExecStart `seq 0 21`). Per-core C10 exonerated as sole cause, but time-to-freeze ~2.5–3× longer. Next suspect: NVMe APST. See Crash #7 section |
| 2026-06-01 14:21 | ~27.7h (6 s2idle cycles) | 7.0.10-201.fc44 | crash #8 — C10 disabled, **APST NOT yet active** (script took effect only next boot — see correction). Second C10-only point; freeze unchanged on new kernel. NAS capture live but lost final ~70s. See Crash #8 section |
| 2026-06-01 22:26 | **~4h awake** (49 min after resume from a 4h s2idle dwell) | 7.0.10-201.fc44 | crash #9 — **full cpuidle+NVMe fix verified LIVE** (C6+C10 off on IRQ core cpu18, IRQ pinned, irqbalance off, APST off). **Fastest in the catalog → cpuidle disproven.** NAS run-up silent. ~~New lead: i915 display-PLL resume regression~~ → re-read 2026-06-05: NAS outlived local journal by 18+ s = storage-death signature, see 06-05 top block |
| 2026-06-04 22:39 | ~59h (incl. one clean 13h s2idle dwell, resumed healthy) | 7.0.10-201.fc44 | crash #10 — psr=0 live, APST ON (reverted). **NAS stream outlived the local journal by 32 s with the system fully healthy (display ON at 810000 the whole time) → NVMe write-path death at 22:39:16.7, panic ≈30 s later (I/O timeout), self-reboot 22:40.** i915 exonerated; root cause pivots to the WD SN740. See 06-05 top block |

(Boot-index column is relative to each row's observation date and goes stale after every reboot; the date is the stable key.)

All crashed during active use (last journal entry was foreground activity — keystroke, DHCP renewal). A previous entry in this table that listed `2026-05-17 11:02` was wrong — that was a clean reboot following the 09:33 crash, identifiable by `systemd-shutdown[1]: Sending SIGTERM` in the tail.

## Diagnostic findings

- **No kernel panic in any crash.** `kdump` is enabled and active across all boots, but `/var/crash/` is empty. The kernel never reached `panic()` — pure deadlock or firmware-level hang.
- **`pstore` backend is `(null)`.** EFI firmware on this machine only exposes the `OfflineMemoryDumpUseCapability` EFI variable (an OEM ACPI offline-dump capability), not a writable pstore region. So `efi-pstore` is dead-on-arrival here; no firmware-preserved trace.
- **Zero MCEs across all boots.** Not a CPU hardware fault.
- **No thermal correlation.** Boot ending 2026-05-19 ran 50h with 51 throttle log lines and shut down cleanly; one of the crashed boots had just 3 throttle log lines. Thermal is ruled out as cause.
- **No GPU hang signatures in dmesg.** `i915` GuC and IPU6 boot normally each cycle; no `i915 hang`, `xe hang`, `fence timeout` or `engine reset` messages.
- **~~Touchpad I2C errors precede freezes~~** — **withdrawn.** Per-boot counts (`i2c_designware.0 lost arbitration` + `i2c_hid_acpi incomplete report`) are roughly proportional to uptime regardless of whether the boot crashed. Boot -5 ran 50h *clean* with 8 arbitration events; crashed boots had 0–3. This signal was noise that looked correlated only because we noticed it when inspecting pre-crash logs.

The kernel logged nothing in the minutes before each freeze beyond foreground user input — typical of a hardware-level wedge (no kernel code runs).

## Root cause (verified 2026-05-23)

**i915 GPU IRQ pinned by irqbalance to a Meteor Lake E-core that enters C10 between interrupts.** The wake-from-C10 path on E-cores is unreliable on Meteor Lake firmware; eventually an IRQ delivery hangs, the GPU pipeline wedges, and the whole system freezes without any kernel diagnostic (no code runs to log).

### Evidence

- `/proc/irq/200/smp_affinity_list = 12` before the fix (single E-core, bitmap 0x001000)
- 339,943 i915 IRQs accumulated on cpu12 in 1.5h of uptime — sole target
- `lscpu --extended` confirms cpu12 is an E-core (max 3800 MHz; P-cores are 4800–5100 MHz, LP-E cores are 2500 MHz)
- Kernel boot warning `hpet: HPET dysfunctional in PC10. Force disabled.` — a sibling symptom of PC10 firmware bugs on this hardware
- Pattern match: documented identical root cause and fix on Core Ultra 9 185H at https://bbs.archlinux.org/viewtopic.php?id=308313
- BIOS 1.29 (11/28/2025) is latest per fwupd; microcode 0x28 is current Meteor Lake; F44 already on kernel 7.0.9-205 with no dnf updates pending — **no upstream fix exists today**, only this workaround

### Why uptime correlated

Each IRQ entering cpu12 is a roll of the dice on C10 wake. ~85 IRQs/sec × 24h = millions of opportunities to hit the bad path. Boot -5 (clean 50h) got statistically lucky; the other long-uptime boots did not.

## Fix applied 2026-05-23 (live, no reboot needed)

`/etc/sysconfig/irqbalance`:
```
IRQBALANCE_BANNED_CPULIST=12-21
```

Then `systemctl restart irqbalance`. After ~30–60s settle, irqbalance re-pinned i915 IRQ 200 from cpu12 (E-core) to cpu3 (P-core, 5100 MHz). Script: `~/setup-irq-fix.sh`.

### Verification
```
cat /proc/irq/200/smp_affinity_list      # should be < 12 (P-core)
grep ^IRQBALANCE_BANNED_CPULIST= /etc/sysconfig/irqbalance
# Sample twice 10s apart — cpu12 count should stay frozen while a P-core count grows:
grep -E "^\s*200:" /proc/interrupts
```

### Escalation if freezes recur after a week
1. **Belt-and-suspenders:** disable C10 (state3) on whichever P-core ends up handling i915 IRQ — write `1` to `/sys/devices/system/cpu/cpuN/cpuidle/state3/disable`.
2. **Nuclear option:** add `intel_idle.max_cstate=2` to kernel cmdline (caps C-states globally; more battery cost).
3. Then look at IPU6 / camera-service interactions — the camera service runs 24/7 and was running at all four crash times.

## Crash #5 (2026-05-25) — the irqbalance fix was a no-op

Crash #5 hit at ~10:33 on 2026-05-25 after ~48h uptime, **with the irqbalance fix active and verified** (IRQ 200 confirmed on cpu3, a P-core; `IRQBALANCE_BANNED_CPULIST=12-21` persisted across the 05-23 reboot). Post-mortem of the boot that died (then boot -1):

- **It was a genuine unclean wedge, not a reboot.** `last` shows no `shutdown` line between the 05-23 and 05-25 boots; the journal has no shutdown sequence (no `systemd-shutdown … Sending SIGTERM`, never reached `shutdown.target`). Kernel logged steadily (~13 events/min) to the last second, then silence — sudden hard wedge, recovered by cold boot. The tail (`Stopped target default.target`) was just a root console session logging out moments before the wedge, **not** a system shutdown. The display stack was alive right before (successful GDM login on tty1 at 10:31:17).

### Why the irqbalance fix did nothing for the suspected mechanism

Measured on the post-crash boot via `/proc/interrupts`:

| IRQ(s) | Device | Interrupts on E-cores 12-21 (one boot) | Movable by irqbalance? |
|---|---|---|---|
| 192–199 | `nvme0q15`–`q22` | ~11k–23k **each** (~150k total) | **No** — kernel-managed, one queue per CPU |
| 200 | i915 (the one the fix relocated) | 500 | Yes (and was moved to cpu3) |

NVMe queue IRQs are **kernel-managed**: each hardware queue is bound to a fixed CPU and userspace cannot change the affinity — that is the `Cannot change IRQ … affinity: Permission denied → unmanaged` spam in the irqbalance log. `IRQBALANCE_BANNED_CPULIST` only prevents irqbalance from *moving manageable* IRQs onto the banned cores; it has **zero effect** on the NVMe IRQs the kernel already pinned there.

So the fix relocated a 500-interrupt/boot trickle (i915) and left the ~150k-interrupt/boot flood (NVMe) exactly on the E-cores. C10 on those E-cores remained enabled (`state3 disabled=0`, ~95k entries/boot). **The condition the C10 theory blames — IRQ delivery to an E-core in C10 — was never removed.** The single experiment meant to test the C10 theory was invalid; the theory has still never been tested.

> **Lesson:** an `IRQBALANCE_BANNED_CPULIST` ban does not evict kernel-managed (NVMe/`-fasteoi` managed) IRQs. To actually keep IRQs off a core you must address them at the source (queue count / `irqaffinity=` boot param) or remove the *core-side* trigger (the C-state), not lean on irqbalance.

### Mitigation applied 2026-05-25 (live + persistent)

Disable the C10 idle state on E-cores cpu12-21 so they cannot enter the suspected-bad state, regardless of which (movable or kernel-managed) IRQ targets them:

- Live: `echo 1 > /sys/devices/system/cpu/cpu{12..21}/cpuidle/state3/disable` (E-cores now cap at C6).
- Persistent: systemd oneshot `disable-ecore-c10.service` (enabled, `WantedBy=multi-user.target`).
- Script: `~/setup-ecore-c10-disable.sh` (includes revert instructions in its header).
- Verified: all of cpu12-21 read `state3=C10 disable=1`; P-cores left untouched (still deep-idle).

This is the **first valid test** of the C10 hypothesis — which remains unproven. If freezes continue past the ~48h mark, the C10/E-core theory is wrong and the next suspects are (a) NVMe/`nvme0` itself, (b) the global C-state path (escalate to `intel_idle.max_cstate=2`), (c) IPU6/camera-service.

### Capture instrumentation now finally armed

`nmi_watchdog=panic watchdog_thresh=10` only reached the cmdline on **this** boot (grubby applied it next-boot; boots -1 through the 05-23 boot ran with sysctl knobs only). So the next freeze is the first with the full watchdog→panic→kdump chain live — *if* a CPU can still service the NMI. A true hardware wedge where NMI delivery also fails will still produce an empty `/var/crash/`; that result would itself be evidence and would justify ramoops.

### Unrelated noise observed (not the cause)

`stratsense_redis` (a Supabase-stack container, unrelated to this driver project) generated the per-minute veth/iptables churn seen in the pre-crash logs. On boot -1 it was crash-looping every ~60s (restartCount 1269, `restartPolicy=unless-stopped`). On the post-crash boot it exited once (`exit=255`, empty error string, `restartPolicy=no`) and stayed down — and its own logs show clean RDB saves right up to 24 May 17:39 then nothing, i.e. it was **killed by the freeze, not a redis fault**. Not a plausible kernel-wedge cause. **Stopped 2026-05-25** (`docker stop`; policy is `no`, won't restart) to remove the network-namespace churn from the C10-test observation window.

## Crash #6 (2026-05-26) — E-core-only C10 disable disproven; the GPU IRQ was on a C10-enabled P-core all along

Crash #6 hit ~15:50 on 2026-05-26 after ~29h uptime, **with E-core C10 disabled** (the 05-25 live `echo` held through the boot that died; `disable-ecore-c10.service` itself did not run on that boot — created mid-boot, "No entries" — but the Atom cores stayed at `disable=1`). At ~29h it is well inside the 48h C10-test threshold, so the **E-core-only C10 disable is disproven**. It was an unclean wedge, not a reboot (last journal lines were foreground keypresses to 15:50:47, then silence; no shutdown sequence).

### Why it still froze: the GPU IRQ never touched the cores we disabled

The i915 GPU IRQ (IRQ 200) is delivered to a **P-core**, not an Atom core:

- Crash #5: i915 IRQ 200 confirmed on **cpu3** (P-core), per #362.
- Crash #6 / current boot: IRQ 200 effective affinity is **cpu11** (P-core); this boot it has been served by cpu3/cpu9/cpu11/cpu16 — irqbalance bounces it across the P-cores.
- All P-cores (cpu0-11) had **C10 enabled** (`state3/disable=0`); cpu0 alone logged **475,613** C10 entries this boot. The 05-25 disable only covered the Atom cores (cpu12-21).

So in both crash #5 and #6 the GPU IRQ sat on a core in C10, and the E-core disable was irrelevant to where it landed. The `IRQBALANCE_BANNED_CPULIST=12-21` ban from 05-23 makes it worse: by forbidding the Atom cores (now the C10-safe ones) it **forces** irqbalance to keep the GPU IRQ on a C10-enabled P-core. On kernel 7.0 the GPU IRQ's *default* placement would be cpu18 (an Atom core, already C10-safe) — the ban drags it off that safe default.

This matches the same-CPU report at archlinux BBS 308313 (Core Ultra 9 185H): a GPU (i915/xe) IRQ delivered to a core in deep C-state wedges the display/render pipeline. #362 dismissed the i915 IRQ by *volume* (~500/boot vs NVMe's ~150k), but for the GPU IRQ volume is the wrong metric — a single delayed wake stalls the compositor. The cell never tested until now is **"GPU IRQ on a core that cannot enter C10."**

### Watchdog was armed and caught nothing — consistent with an idle-wait wedge

The boot that died was the first with the full chain live: `nmi_watchdog=panic watchdog_thresh=10` on the cmdline, `NMI watchdog: Enabled` in the log. Yet no soft/hard-lockup or RCU-stall fired and `/var/crash/` is empty. A software spin-deadlock would have tripped the lockup detector. Likeliest reading: the CPUs went **idle** waiting on an I/O or GPU completion that never arrived (not spinning with IRQs off), so no detector saw a "stuck" CPU, and journald could not persist the final ring buffer (disk path wedged) — which also explains the "no logs before the freeze" in every prior crash without needing an "NMI is blocked" theory.

### Second independent suspect: WD PC SN740 NVMe APST

The NVMe drive is a **WD PC SN740** (`SDDPNQE-2T00`, fw 74117000) — a drive family with a documented deep-power-state (APST) freeze bug on Linux; the SN770 got a firmware fix, the SN740 did not. APST deep states are enabled (`nvme_core.default_ps_max_latency_us=100000`) and the kernel already auto-applies a `platform quirk: setting simple suspend` to it. Its failures would be invisible here: `_OSC` denies the OS AER (no PCIe error reporting), and a wedged disk loses the journal. Not addressed by the C10 mitigation — it is the **next suspect** if the all-core C10 disable also fails.

### Mitigation applied 2026-05-26 — C10 disabled on ALL cores

`~/setup-c10-disable-allcores.sh` (live + persistent; reuses `disable-ecore-c10.service`, ExecStart widened to `cpu0-21`). **Verified live 2026-05-26:** all 22 cores read `state3 disable=1`, the unit is enabled, and its persistent ExecStart was confirmed to cover `seq 0 21` (so it survives reboot). Pure cpuidle — no irqbalance change, consistent with the #362 retraction. Chosen over the surgical IRQ-pin because it cannot fail to remove the wake-from-C10 path regardless of where any IRQ is steered (the GPU MSI IRQ number is not stable across boots/driver reloads, which makes a persistent pin fragile for a freeze this expensive to retest).

- **Cost:** with C10 off on every core the package cannot reach PC10 → idle power rises.
- **Refinement (deferred):** after a clean week, pin the i915 IRQ to a C10-disabled Atom core (cpu18) via irqbalance `--banirq=200` and re-enable P-core C10 to reclaim battery; the vestigial `IRQBALANCE_BANNED_CPULIST=12-21` ban can be dropped then (harmless but pointless under all-core C10).
- **Capture:** ramoops is now *de-prioritised* — unlikely to survive the cold power-cycle these wedges require (DRAM loses state), so elimination beats capture here.

### If crash #7 occurs with all-core C10 disabled
Per-core C10 is then exonerated. Order of next moves: (a) disable NVMe APST (`nvme_core.default_ps_max_latency_us=0`, cmdline); (b) PCIe ASPM (`pcie_aspm=off`); (c) global `intel_idle.max_cstate=2`; (d) IPU6 / camera-service.

## Crash #7 (2026-05-31) — all-core C10 disable exonerated as *sole* cause, but it was a major accelerant; NVMe APST is now the prime suspect

Crash #7 hit ~10:39 on 2026-05-31 after **~115h uptime** (4d 19h; `last -x` shows the tty2 session 2026-05-26 15:51 → "crash"). This is the decisive test the 05-26 mitigation set up, and unlike #5/#6 the experiment was **valid this time** — verified, not assumed:

- **Genuine unclean wedge, not a reboot.** Boot −1's tail ends mid-activity at 10:39:05 (Chrome service-worker errors, a docker shim being cleaned up) then cuts straight to the next boot marker. No `systemd-shutdown … Sending SIGTERM`, no `shutdown.target`. Same signature as #1–#6.
- **All-core C10 disable was actually live on the dead boot.** `journalctl -b -1 -u disable-ecore-c10.service` shows it *Started* and *Finished* at 15:51:56 on 2026-05-26; `systemctl cat` confirms the real ExecStart loops `seq 0 21` guarded by `name == C10` (the unit's "ecore" name is vestigial — the body covers all 22 cores). So the wake-from-C10 path was removed on every core for the full ~115h.

### What this proves and what it doesn't
- **Per-core C10 is exonerated as the *complete* root cause** — the freeze recurred with it fully disabled.
- **But C10 was clearly a major accelerant.** Crashes #1–#6 clustered at 24–48h; removing C10 stretched time-to-freeze to ~115h. Boot −1 had **9 s2idle suspend/resume cycles**, so the 115h includes sleep; awake-time is lower — but even discounting ~30–40h of overnight sleep the awake interval (~75–85h) is still well above the prior 24–48h band. So the accelerant effect is real (≈2× awake-time, not necessarily 3×). This is a **multi-factor** freeze: C10-on-a-busy-core was the fast path; a slower mechanism remains. → **Keep the all-core C10 disable in place; stack the next fix on top. Do not revert it.**

### Prime suspect: WD PC SN740 NVMe APST (now being acted on)
The drive is confirmed **WD PC SN740 `SDDPNQE-2T00-1127`, fw `74117000`** — the family with the documented APST deep-power-state freeze bug on Linux (SN770 got a firmware fix; SN740 did not). On this boot the kernel again auto-applies `nvme 0000:01:00.0: platform quirk: setting simple suspend`, and APST deep states are still ON (`/sys/module/nvme_core/parameters/default_ps_max_latency_us = 100000`; cmdline carries no override). Its failures are invisible here exactly as predicted: `_OSC` denies OS AER, and a wedged disk cannot persist the journal — which matches every "no logs before the freeze" crash. No `nvme`/`aer`/`pcie` error appears anywhere in boot −1 (expected for this failure mode).

**Mitigation applied 2026-05-31:** fully disable APST via kernel cmdline `nvme_core.default_ps_max_latency_us=0` (script `~/setup-nvme-apst-disable.sh`, `grubby --update-kernel=ALL`, persistent, takes effect next boot). All-core C10 disable left untouched. Cost: drive holds a shallower idle state → marginally higher idle power. Revert: `grubby … --remove-args="nvme_core.default_ps_max_latency_us=0"`.

- **Watch:** the bar is now **freeze-free past ~115h** (~2026-06-05+), not 48h — C10-disable already buys us to ~115h, so APST is only confirmed as the second factor if we clear that mark.

### New signal seen but NOT chased (uptime-proportional noise)
Boot −1 logged recurring `iwl_pcie_txq_alloc+0x…` (iwlwifi) call-trace fragments every ~30 min, but spread uniformly across uptime and the **last one is ~36h before the crash** — not crash-correlated. Same trap as the withdrawn touchpad-I2C signal; recorded here so a future pass doesn't "rediscover" it as a lead.

> **Confidence note (added on review):** the NVMe-APST hypothesis has **no positive evidence from crash #7** — it rests on the drive's known-bad reputation plus elimination, not on anything in the logs. It earns "prime suspect" only because it's an unaddressed, documented-bad power state. The total-and-silent signature *is* consistent with it (root is on this NVMe — if the controller fails to wake, root I/O hangs and the final journal lines can't be persisted to the wedged disk), but "consistent with" ≠ "evidenced." Hold confidence moderate.

### Co-equal suspect promoted on review: docker / netns teardown churn (`cleanup_net`/netfilter)
A review of crash #7 corrects a stale assumption in the 2026-05-25 notes below. The claim "stratsense_redis stopped 2026-05-25 → netns churn removed from the observation window" **did not hold for crash #7**:
- The full `supabase_*_stratsense` stack (db, kong, auth, realtime, storage, rest, pg_meta, studio, inbucket) plus `book_alerter` and a buildkit builder all have `RestartPolicy=unless-stopped`, so they **auto-started on boot −1** and ran for the whole ~115h. `stratsense_redis` was back up too. ~10 veth pairs + 3 docker bridges live. So heavy netns/veth/iptables churn was present the entire crash-#7 window, not removed.
- **It was active at the exact freeze instant.** Boot −1's final kernel/systemd lines (10:39:01–05): an automated publickey SSH login from the libvirt VM `192.168.122.11` (opens+closes in ~1s), then a short-lived container (`eba9fb9…`, 928ms CPU, 10.3M read) starting and immediately tearing down — `run-docker-netns-f70cdcfbcf8b.mount: Deactivated` and the overlayfs unmount are the **last two lines before the wedge**. This is the second crash whose tail is a docker netns teardown.
- Mechanism is plausible at kernel level (unlike the withdrawn i2c/keycode noise, which had none): netns exit serializes on the global `cleanup_net` work + RTNL, and netfilter/conntrack teardown has a long history of stalls/deadlocks. A clean idle-wait stall here would still produce empty `/var/crash` and no hung-task log (`CONFIG_DETECT_HUNG_TASK` is off on this kernel), so absence of evidence does not exonerate it.
- **It is uptime-proportional** (constant churn), so "active at the freeze" is only weak evidence on its own — but it has *more* positive circumstantial support than NVMe APST does, and it is testable on a **cheaper, orthogonal axis**: stop the docker stack for a watch window (no reboot, no battery cost). Gated on the user — it is their working dev environment.

### Getting eyes on crash #8 — capture feasibility (re-evaluated on review)
The earlier "capture is hopeless" stance is only half right:
- **Atomic kernel netconsole is genuinely blocked here:** the machine is wifi-only (`wlp0s20f3`, `iwlwifi`; no ethernet port present), and `iwlwifi` exposes no `netpoll`/`ndo_poll_controller`, so kernel netconsole cannot emit from the dying (IRQs-off) path.
- **Continuous remote journal forwarding to the NAS — LIVE 2026-05-31** (built, data-path validated, and running: service+timer active/enabled, linger on). The NAS `nasff235` is a QNAP (busybox; no socat/nc), so instead of a listener we pipe `journalctl -f` straight over the existing SSH key into a **per-day** file on the NAS: `journalctl -f -o short-iso | ssh nasff235 'cat >> /share/homes/ff235/freeze-capture/<host>-journal-YYYY-MM-DD.log'`. Installed as a per-user systemd service kept alive across reboots via `loginctl enable-linger` (runs as ff235 → unconfined SELinux context, reads the ssh key + full journal without grief). A daily user timer (`journal-capture-rotate.timer`, 00:05) prunes day-files older than 7 days and restarts the stream onto the new day's file, so NAS use is capped at ~1 week (~49 MB/day measured → ~350 MB ceiling). Script: `/home/ff235/setup-journal-capture.sh`. Validated: a 30-line test pipe landed correctly; prune command verified against the QNAP busybox `find`. This rides the normal network stack (not netpoll), so it ships logs while userspace is still scheduled. Watch live: `ssh nasff235 "tail -f \$(ls -t /share/homes/ff235/freeze-capture/*-journal-*.log | head -1)"`. For the **storage-wedge** hypothesis specifically this is the decisive instrument: if the NVMe controller hangs, the nvme driver's `I/O QID … timeout, reset controller` messages — which currently die unflushed on the wedged root disk — would already be in flight to the NAS. A captured nvme-timeout trail → storage/APST; total silence even at the NAS → favors a CPU/firmware/atomic wedge over storage. Caveat: upload buffering + wifi may still drop the final ~second; not guaranteed, but the best available sight-line and ~free to stand up. (Gold standard if a USB-ethernet dongle is on hand: real netconsole over that NIC to the NAS.)

### If crash #8 occurs with both C10 disabled AND NVMe APST disabled
NVMe APST is then exonerated too. Next moves in order: (a) stop the docker/supabase stack for a window (orthogonal axis, cheap — see above); (b) PCIe ASPM (`pcie_aspm=off`); (c) global `intel_idle.max_cstate=2` (caps every core at C2 — the bluntest cpuidle hammer, real battery cost); (d) IPU6 / camera-service. At that point also reconsider whether the residual factor is the GPU/i915 idle path itself rather than a storage/link power state. **Priority regardless of which mitigation is active: get the NAS journal capture running so crash #8 is finally observed, not just post-mortemed.**

> **Read the crash-#8 section below before acting on this ladder.** The premise of this block — that crash #8 would arrive *with both C10 and APST disabled* — turned out false: APST was never live on the dead boot. The "both-off" test only begins on boot 0 (2026-06-01 14:22). So APST is **not** exonerated, and the docker-stop step (a) has not yet been reached by the ladder's own logic.

## Crash #8 (2026-06-01) — APST was never live on the dead boot; this is a second C10-only point, and the both-off test only starts now

Crash #8 hit **2026-06-01 14:21** after **~27.7h uptime** (boot −1: 05-31 10:40 → 06-01 14:21; 6 s2idle cycles, so awake-time is lower). Same signature as #1–#7:

- **Genuine unclean wedge.** Last *kernel* line is `14:20:47` (an `input … Unknown key pressed` Fn-key event); last *userspace* line is `14:21:25` (Chrome `DidStartWorkerFail` spam, ~1/s). Then silence to the cold reboot at 14:22:01. No `shutdown.target`, no `Sending SIGTERM`. The three `shutdown.target` hits in boot −1 are *user*-manager (`systemd[27126/62650/100007]`) session logouts, not system shutdown.
- **Total silence — no kernel diagnostic of any kind.** `grep` over `journalctl -b -1 -k` for `nvme.*timeout|nvme.*reset|aer|hardware error|soft/hard lockup|rcu.*stall|BUG:|Oops|watchdog` → nothing but the boot-time `NMI watchdog: Enabled` and `_OSC: platform does not support [AER]`. `/var/crash/` empty again; `nmi_watchdog=panic watchdog_thresh=10` was on the cmdline and caught nothing — consistent with an **idle-wait wedge** (CPUs parked waiting on a completion that never arrives), not a spin-deadlock the lockup detector could see.

### The correction that changes what crash #8 means
The crash-#7 plan assumed crash #8 would test **C10 + APST both disabled**. It did not, because the APST mitigation never activated on the dead boot:

- `~/setup-nvme-apst-disable.sh` mtime is **05-31 10:44** — four minutes *after* boot −1 started (10:40). `grubby --update-kernel=ALL` only rewrites the on-disk bootloader entries; the running kernel is unaffected. So the arg landed for the *next* boot, not boot −1.
- Boot −1's `Kernel command line` (from `journalctl -b -1 -k`) confirms it: `… mem_sleep_default=s2idle nmi_watchdog=panic watchdog_thresh=10 crashkernel=…` — **no `nvme_core.default_ps_max_latency_us=0`**.
- Boot 0 (current) *does* carry it, and `/sys/module/nvme_core/parameters/default_ps_max_latency_us = 0` is verified live. All-core C10 is also confirmed disabled this boot (`cpu0`+`cpu11` `state3/disable = 1`).

So crash #8 is a **second data point for the C10-only configuration**, identical in intent to crash #7:

| Crash | Config | Kernel | Uptime |
|---|---|---|---|
| #7 | C10 off, APST **on** | 7.0.9-205 | ~115h |
| #8 | C10 off, APST **on** | 7.0.10-201 | ~28h |

**What this proves:** C10-off does not stop the freeze, and its time-to-freeze is highly variable (28–115h). Crash #7's 115h was favorable variance, **not** evidence that APST was the missing factor — that inference was built on the assumption #8 would change the APST variable, which it didn't. A kernel bump (7.0.9-205 → 7.0.10-201, built 2026-05-27) also rode in between #7 and #8; the unchanged freeze signature shows the bug survived it. **The "C10 + APST both off" experiment genuinely begins now, on boot 0.** APST is therefore *not* exonerated — it has simply not been tested yet.

### NAS capture: live and working, but lost the final ~70s — now fixed
The capture (`journal-capture-nas.service`) was active across the crash and is the first real win on instrumentation — but it did **not** deliver run-up evidence this round:

- The 2026-06-01 NAS file has **no `14:21:*` lines**; boot −1 content stops short of the wedge, and the boot-0 stream only resumes at ~14:22:33 (the `-n 0` follow starts when the service starts post-reboot — that part is by design, not loss).
- **Cause of the lost window:** the laptop side was already line-buffered (`stdbuf -oL journalctl -f`), but the **NAS-side `cat >> file` block-buffers** its stdin→file (stdout to a regular file, not a tty). On the hard wedge + cold power-cycle, the final unflushed block (~the last ~70s of low-rate log here) never hit the NAS disk.
- **Fix applied + verified 2026-06-01:** replaced `cat >> file` with a per-line read-loop — `while IFS= read -r l; do echo "$l"; done >> file` (busybox `echo` = one `write()` per line, no stdio buffering). Patched in both the live unit (`~/.config/systemd/user/journal-capture-nas.service`) and the source script (`~/setup-journal-capture.sh`); `daemon-reload` + restart done. A `logger` marker was confirmed to land on the NAS within ~2s. This shrinks the worst-case loss window from ~a block (~tens of seconds) to ~the last line. (Wifi + the laptop's own TCP send buffer can still drop the very last line on a hard wedge — irreducible without netconsole over a wired NIC.)
- **Interpretation note for crash #9:** with the fix in place, a captured `nvme … I/O QID … timeout, reset controller` trail at the NAS → storage/APST; total silence even at the NAS (to within ~1 line) → favors a CPU/firmware/atomic idle-wait wedge over storage. Crash #8's silence is *not* usable this way because the old buffering ate the window.

### Docker / netns churn — still the strongest positively-evidenced suspect, still present
- dockerd/containerd run as **root** (PIDs 2196/1974 this session). The `supabase_*_stratsense` stack + `book_alerter` (all `unless-stopped`) auto-started on boot −1 and ran the whole window. A container `eba9fb9…` was **crash-looping every ~60s** (`exitCode=255`, `restartCount` climbing 7→8→9→12→13 across the logs), each restart tearing down a netns (`run-docker-netns-*.mount: Deactivated`) — the same `cleanup_net`/RTNL/netfilter teardown that was the last activity before the crash-#7 wedge.
- This is now the suspect with the **most positive circumstantial support** (last-activity in two crashes; constant churn; a visibly broken container), and it sits on a **cheap orthogonal axis** (stop containers — no reboot, no battery cost). But stopping it confounds the now-live APST test, and it is the user's working dev environment → gated on the user.

### Next moves (revised ladder)
1. **Boot 0 is the real first "C10 + APST both off" window.** Watch bar unchanged in spirit: APST is credited only if we clear ~115h+ cleanly (C10-only already reaches that on a lucky run). If a freeze comes in well under ~115h, APST is exonerated.
2. **Identify + stop the crash-looping `eba9fb9` container** regardless — it is broken (exit 255 on a 60s loop, doing no useful work) and removes both noise and churn. (`sudo docker ps -a` / `docker inspect eba9fb9`.)
3. **Docker-stop as a clean orthogonal window** remains the next experiment if crash #9 lands with both C10 and APST off — or sooner if the user is willing to pause the stack (it has more positive evidence than APST ever did). User's call.
4. Then the unchanged tail: (b) `pcie_aspm=off`; (c) `intel_idle.max_cstate=2`; (d) IPU6 / camera-service.

## Root cause + fix (2026-06-01) — GPU IRQ on a core in deep C-state; disable C6 (not just C10) on the IRQ core

After crash #8 the strategy was changed from serial single-knob elimination (hopeless on a multi-day-repro bug) to: (a) read the *one* informative result we already had, and (b) verify against real same-SoC reports instead of theorising. Both converged on the same answer.

### The local evidence that had been there all along
`cpuidle` state map on this machine (kernel 7.0.10, `intel_idle`):

| state | name | exit latency | disabled? | entries this boot (cpu0) |
|---|---|---|---|---|
| state0 | POLL | 0 µs | no | 8,726 |
| state1 | C1E | 1 µs | no | 858,783 |
| state2 | **C6** | 140 µs | **no** | **1,660,695** |
| state3 | C10 | 310 µs | yes | 9,765 |

The "all-core C10 disable" only ever touched **state3**. **C6 (state2) — entered ~1.66M times/boot, 170× more than C10 — was always enabled.** The i915 GPU IRQ (200) was on **cpu8** (a P-core, C6 enabled). Core layout (`lscpu -e`): cpu0-11 = P-cores (4800-5100 MHz), cpu12-19 = E-cores (3800), cpu20-21 = LP-E / low-power-island (2500). `IRQBALANCE_BANNED_CPULIST=12-21` forced the GPU IRQ onto the C6-enabled P-cores.

### Cross-checked against same-SoC reports (no guesses)
- **Arch BBS 308313 — "Random freezes on Intel Meteor Lake (i915)":** root cause = *"i915/xe GPU interrupts are handled by a single LPI core by default"*; the core enters deep C-states and a GPU IRQ delivery then hangs. Explicit: **"disabling only C10 proved insufficient — deeper states must be disabled on the GPU IRQ core."** Working fix = pin i915/xe IRQ to one core + disable its deep C-states (their script disables `state[0-9]*` ≥1 on the chosen cpu; they used cpu17/18). Blunt `intel_idle.max_cstate=0/1 processor.max_cstate=0 pcie_aspm=off` works too but "major issues with noise and battery." **No kernel version (through 7.0-rc) fixes it** — userspace workaround still required.
- This matches our crashes #7/#8 exactly (froze with C10 off) and explains why the 7.0.9→7.0.10 bump changed nothing.
- The Zorin "185H GPU hang" thread is a *different* bug (logged i915 heartbeat resets, ~1 s stutters — not silent hard hangs); not our signature. Recorded so it isn't mistaken for a match.

### The fix (`~/setup-gpu-irq-cstate-fix.sh`)
Surgical, battery-friendly — only one core loses deep idle: (1) `systemctl disable --now irqbalance` (it only ever fought the pin; per our issue #362 it isn't needed and the ban was counterproductive) + comment out `IRQBALANCE_BANNED_CPULIST`; (2) pin the i915/xe IRQ to **cpu18** (re-derived each boot — MSI numbers aren't stable); (3) disable **C6 + C10** on cpu18 only (keep POLL + C1E — C1E is a 1 µs clock-gated halt, never the unreliable-wake culprit). Persisted via `gpu-irq-cstate-fix.service` (`After=multi-user.target`, retries up to 30 s for the IRQ to appear). Applies live, no reboot. Reversible (header documents revert). **Nuclear fallback** if it ever recurs or for a zero-risk night: `intel_idle.max_cstate=1` on the cmdline (all cores → C1E; heavier battery, cannot miss).

### Why this isn't another guess on the pile
It is the only hypothesis simultaneously consistent with (a) the silence + active-use timing + survival-through-C10-disable signature, (b) the live machine state (IRQ on a C6-enabled core; C6 never disabled), and (c) the documented same-SoC community fix. Confidence: high on mechanism, pending the multi-day clean-uptime confirmation any fix here needs. **Watch bar: clean past ~115h (~2026-06-06).** If it still freezes, the per-line-flushed NAS capture should finally show the run-up, and the next escalation is the `intel_idle.max_cstate=1` sledgehammer (which, if *that* also fails, would point away from cpuidle entirely toward IPU6/i915-driver or firmware).

### Fix applied 2026-06-01 (live, verified)
`sudo bash ~/setup-gpu-irq-cstate-fix.sh` ran clean. Verified: IRQ 200 `effective_affinity_list=18`; cpu18 `C6 disable=1, C10 disable=1` (POLL/C1E left enabled); `irqbalance` inactive. No reboot needed — live now, and `gpu-irq-cstate-fix.service` (enabled) re-applies every boot (re-derives the IRQ; survives suspend/resume since i915's IRQ isn't recreated on wake). Confirm after any natural reboot: `journalctl -t gpu-irq-cstate-fix -b` → expect `pinned i915/xe IRQ 200 -> cpu18` + `disabled C6 on cpu18`. **Clean-uptime clock starts 2026-06-01 ~14:40; target ~June 6 (>115h).**

### After the next freeze (crash #9 playbook), in order
1. **NAS run-up log FIRST** (the evidence we've never had): `ssh nasff235 "tail -400 \$(ls -t /share/homes/ff235/freeze-capture/*-journal-*.log | head -1)"`. Read the signature: `nvme … timeout/reset` → storage; `i915`/GPU → GPU path; `cleanup_net`/netns → docker; total silence to the last second → CPU/firmware/atomic wedge.
2. **Verify the fix was live on the dead boot** (crash-#8 lesson — never assume): `journalctl -t gpu-irq-cstate-fix -b -1` (did it pin + disable C6/C10?).
3. **Uptime at crash** (`last -x reboot | head`): longer than the 28–115h band → fix helped but didn't fully close; shorter → no help.
4. **Escalate to the sledgehammer**: `sudo grubby --update-kernel=ALL --args="intel_idle.max_cstate=1" && sudo reboot` (caps all cores at C1E). If crash #10 occurs even with that → cpuidle fully exonerated → pivot to IPU6 / the OOT camera stack (runs 24/7): disable the camera service for a watch window. The step-1 NAS log will likely already point the way.

### Sources
- Arch BBS 308313 — Random freezes on Intel Meteor Lake (i915): https://bbs.archlinux.org/viewtopic.php?id=308313
- intel_idle CPU Idle Time Management Driver (kernel docs): https://www.kernel.org/doc/html/latest/admin-guide/pm/intel_idle.html
- Arch BBS 306935 — same-class random freeze, Core Ultra 7 255H: https://bbs.archlinux.org/viewtopic.php?id=306935

## Crash #9 (2026-06-01) — the cpuidle theory is dead; the lead is the i915 display driver

Crash #9 hit **2026-06-01 22:26** (boot −1 ran 14:22→22:26). It was the decisive test of the 06-01 GPU-IRQ/C6 fix, and it failed it outright.

- **The full fix was verified LIVE on the dead boot** (not assumed — crash-#8 lesson applied). `journalctl -t gpu-irq-cstate-fix -b -1`: `pinned i915/xe IRQ 200 -> cpu18`, `disabled C6 on cpu18`, `disabled C10 on cpu18` (15:03:04). Boot −1's cmdline also carried `nvme_core.default_ps_max_latency_us=0`. So **every** mitigation the investigation produced was active at once: all-core C10 off, C6 off on the GPU-IRQ core, IRQ pinned, irqbalance stopped, NVMe APST off.
- **It froze faster than ever.** Boot −1 suspended 17:33→21:37 (one ~4 h s2idle dwell; `tailscaled` logged "slept 4h4m2s"), so awake-time was ~4 h and the wedge came **~49 min after the resume**. Every prior crash was 24–115 h. Fastest in the catalog with the most complete fix applied → **the cpuidle/IRQ/NVMe hypothesis family is disproven in one data point.**
- **The per-line NAS capture finally delivered the run-up — and it is silent.** The local disk journal stops at 22:26:19 (a docker netns teardown), but the NAS stream kept flowing ~18 s further to 22:26:37 (`studio_chrome` spam + keypresses), then silence. No nvme-timeout, no i915/drm error, no cleanup_net stall. **The docker netns teardown is exonerated**: the system ran normally for 18 s after the 22:26:19 line that looked like "last activity" in #7/#8 — it was only the last disk *flush*, not the wedge.
- **`drm|PHY|dpll|flip_done|pixel_rate|Atomic update failure` grep across all boots (0..−7) and the NAS log: zero matches.** Total silence, consistent with a hard display wedge that never flushes (vs the recovering variant elsewhere, which logs the errors).

**Two user observations reframed it**, both pointing the same way: *"didn't happen before the F44 upgrade"* (stable F43 = kernel 6.19.x, broken F44 = 7.0.x) and *"warm + battery drained after suspend"* (the dwell reached little/no S0ix residency — failed deep sleep). New root cause + research: see the **superseding block at the top of this file**. Mitigation `~/setup-i915-psr-fix.sh` (`i915.enable_psr=0`); avoid multi-hour s2idle (hibernate/poweroff); complete fix = patched kernel (6.19.x or ≥7.1).

### Crash-#9 playbook results (the doc's own step list, executed)
1. **NAS run-up:** silent to the last line → favoured a CPU/firmware/atomic or display wedge over storage. Correct call.
2. **Fix live on dead boot?** Yes, verified — and it still froze.
3. **Uptime at crash:** ~4 h awake / 49 min post-resume — *shorter* than the 28–115 h band → the fix did not help; this was the fastest boot-to-freeze yet.
4. **Escalation:** the doc's next step was "sledgehammer `intel_idle.max_cstate=1`, then pivot to IPU6/camera." **Skip the sledgehammer** — crash #9 already had C6 off on the IRQ core, so capping all cores at C1E is very unlikely to help. The pivot is right, but to the **i915 _display_ path** (not IPU6): the user's two clues + the same-SoC LP#2150605 / BBS pid=2297604 reports point at the `intel_cx0_phy` DPLL-after-long-s2idle regression.

### Fix + instrumentation staged after crash #9 (2026-06-01 night)
- **Mitigation staged:** `~/setup-i915-psr-fix.sh` → `i915.enable_psr=0` (grubby all-kernels; activates next boot). Converts hard-hang → ≤10 s slow wake (LP#2150605); `enable_dc`/`enable_fbc` do NOT touch this path.
- **Disproven fixes reverted:** `~/setup-revert-cpuidle-fixes.sh` disabled `gpu-irq-cstate-fix.service` + `disable-ecore-c10.service`, re-enabled C6/C10 on all cores, restored irqbalance, and dropped `nvme_core.default_ps_max_latency_us=0` — so the psr=0 test is a clean single variable. Kept on purpose: `mem_sleep_default=s2idle`, NAS capture, kdump/nmi_watchdog, hibernation.
- **Confirmation tool (reliable):** `~/setup-confirm-i915-diagnosis.sh {baseline|post-resume}` — run via sudo (unconfined_t, reads debugfs fine). The baseline captured pipe A healthy at `port_clock=810000, lane_count=4` on `[CRTC:149:pipe A]` / `DDI A/PHY A` / `eDP-1` — the exact pipe+PHY the reports' errors name. After a long-dwell resume, `post-resume`: `c10pll … 61440` / `Failed to bring PHY A` / `Atomic update failure on pipe A`, or pipe A `port_clock` ≪810000 ⇒ CONFIRMED.
- **Continuous watcher (best-effort, SELinux-limited):** `i915-watch.service` (`~/setup-i915-watch.sh`) samples pipe A `port_clock` every 5 s → NAS, alerting on a sub-162000 (parked 61440) value. **Caveat learned 2026-06-01:** as a systemd service it runs `unconfined_service_t`, which on this F44 policy **cannot read `debugfs_t`** (read returns empty → it logged `?`; dontaudit'd, so no AVC — `last_hw_sleep`/sysfs still read fine, which is the tell). The script now self-tests and disables gracefully with a `NOTE` if blocked. To force it: add `SELinuxContext=unconfined_u:unconfined_r:unconfined_t:s0` to the unit. **Not essential** — the manual confirm tool above is the reliable path (it runs unconfined). Also fixed a parser bug en route: `port_clock` sits several lines below the CRTC header in the raw file, so `grep -A2` missed it; now uses first-nonzero `port_clock`.
- **Long-term fix:** kernel ≥7.1 (upstream fix ~v7.1-rc1) via normal `dnf update`; or backport the `intel_cx0_phy` commit; or roll to 6.19.x. User chose to wait for 7.1 and ride `psr=0`.

## Working hypothesis (superseded — kept for history)

~~Meteor Lake firmware/power-management interactions — CSE/CSME, IPU6 secure-mode, GuC SLPC, or ACPI/SMI deadlock. None produce kernel diagnostics on this hardware. Not enough evidence to localise further until we capture a vmcore.~~

Superseded by the verified IRQ/C10 root cause above. The watchdog instrumentation in the next section is now redundant for this specific bug class but is kept armed in case a different class of freeze appears.

## Instrumentation — prepared 2026-05-21, NOT deployed until 2026-05-23

> **2026-05-23 reality check:** post-mortem after the 4th crash showed the script was created on 2026-05-21 (mtime 16:44) but **never executed with sudo**. `/etc/sysctl.d/99-crash-debug.conf` was missing and the cmdline never gained `nmi_watchdog=panic`. So crash #4 on 2026-05-23 hit the same blindfold as the previous three. **Verify the on-disk state below every time before assuming kdump will capture.**

Verification one-liner:
```
test -f /etc/sysctl.d/99-crash-debug.conf && \
  grep -q nmi_watchdog=panic /proc/cmdline && \
  test "$(cat /sys/kernel/kexec_crash_loaded)" = 1 && \
  echo OK || echo NOT INSTALLED
```

Script: `~/setup-crash-capture.sh` (run with sudo). Does two things:

### 1. sysctl knobs (live, no reboot)

`/etc/sysctl.d/99-crash-debug.conf`:

```
kernel.softlockup_panic = 1
kernel.hung_task_panic  = 1
kernel.hung_task_timeout_secs = 60
kernel.panic_on_oops    = 1
kernel.unknown_nmi_panic = 1
kernel.panic_on_io_nmi  = 1
kernel.panic            = 10
kernel.sysrq            = 1
```

> **2026-05-23 deployment note:** the script ran cleanly under sudo and the 6 panic knobs above (excluding hung_task) all went live. F44's 7.0.9-205 kernel is **built without `CONFIG_DETECT_HUNG_TASK`**, so `hung_task_panic` and `hung_task_timeout_secs` are silently rejected — there's no hung-task detector to enable in the first place. `CONFIG_SOFTLOCKUP_DETECTOR=y` and `CONFIG_HARDLOCKUP_DETECTOR=y` are both set, so soft+hard lockup detection works as expected.

### 2. Kernel cmdline (takes effect next boot)

```
grubby --update-kernel=ALL --args="nmi_watchdog=panic watchdog_thresh=10"
```

**Net effect:** the next time the kernel deadlocks, watchdogs convert it to a panic within ~10 seconds; `kdump` kexecs into the capture kernel and writes a vmcore to `/var/crash/<timestamp>/`.

### Ramoops deliberately skipped

`pstore_ram` on x86 needs a `memmap=` reservation at a specific physical address — picking one wrong = boot breakage. Since `kdump` is already armed and the missing piece is just reaching `panic()`, watchdogs alone should be enough. Add ramoops only if the next freeze still misses kdump.

### Risks

- `nmi_watchdog=panic` + `softlockup_panic=1` will also panic on legitimate-but-pathological events (heavy compile stalls, kernel debugger break). Uncommon on this hardware. Back out with:
  ```
  sudo grubby --update-kernel=ALL --remove-args="nmi_watchdog=panic"
  ```
  and edit `/etc/sysctl.d/99-crash-debug.conf`.

## How to act on the next freeze

After the system has rebooted post-freeze:

```
ls -la /var/crash/
journalctl -k -b -1 --no-pager | tail -50
```

If `/var/crash/<dir>/vmcore` exists:

```
crash /usr/lib/debug/lib/modules/$(uname -r)/vmlinux /var/crash/<dir>/vmcore
# Then in the crash shell:
#   bt        # backtrace of crashing CPU
#   log       # ring buffer up to panic
#   ps        # task list
#   foreach bt   # backtrace ALL tasks
```

If `/var/crash/` is still empty after a freeze post-instrumentation, escalate to ramoops with `memmap=1M$0x100000000 ramoops.mem_address=0x100000000 ramoops.mem_size=0x100000` (verify against `/proc/iomem` first).

## Related

- `docs/incidents/2026-05-fedora-44-regressions.md` — the suspend hang (different bug, already mitigated)
- Upstream irqbalance issue **#362** (https://github.com/Irqbalance/irqbalance/issues/362) — the report we filed. **2026-05-26 follow-up comment** (https://github.com/Irqbalance/irqbalance/issues/362#issuecomment-4545840990): crash #6, the GPU IRQ on a C10-enabled P-core, and the counterproductive `IRQBALANCE_BANNED_CPULIST=12-21` interaction (the ban forces the GPU IRQ onto a deep-idling P-core). Conclusion stands — not an irqbalance bug; kept open. Comment body kept at `~/362-update.md`.
