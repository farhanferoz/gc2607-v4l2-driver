# Resume Notes

Lightweight notes for picking work back up. Not a status doc — see `docs/archive/PROJECT_HISTORY.md` for that.

## Camera state

Camera is **fully functional** via the custom `gc2607_isp.c` software ISP (~4% CPU). All four Fedora 44 post-upgrade regressions are fixed and verified. See `docs/incidents/2026-05-fedora-44-regressions.md`.

## Hardware ISP — quarterly check (next due: ~August 2026)

The HW ISP path is **closed as infeasible** (`docs/native_hal_investigation.md`). 5-minute glance every ~3 months at the criteria below. If any change materially, **reopen the investigation**.

- [ ] [intel/ipu6-drivers commits](https://github.com/intel/ipu6-drivers/commits/master) — has Intel resumed kernel API tracking past v6.16?
- [ ] [intel/ipu6-drivers Issue #272](https://github.com/intel/ipu6-drivers/issues/272) — any GC2607 sensor patches landing?
- [ ] [linux-media archives](https://lore.kernel.org/linux-media/) — search for `ipu6 PSYS` or `ipu6 BE SOC` — any community upstreaming effort?

If all three are still inactive, status is unchanged — close the check and bump the next-due date by another quarter.

| Date checked | Result | Next due |
|---|---|---|
| 2026-05-03 | Initial close — all three blockers active | 2026-08-03 |

## Open loops

- **Open PR `farhanferoz:virtualcam-auto-wb` → `abbood:master`** (opened 2026-03-28). Stale snapshot — local master has 9 commits beyond it. Decide: refresh, close, or leave.
- **Reboot pending** to (a) verify clean-boot path of F44 v4l2loopback masking fix, (b) lock in `mem_sleep_default=s2idle` cmdline, (c) auto-clean the mem_sleep watcher.
- **Build artifacts in working tree** (`.cmd`, `.ko`, `.mod.*`, `.o`) — should be `.gitignore`d at some point so `git status` stops being noisy.
