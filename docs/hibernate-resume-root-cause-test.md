# Hibernate resume hang: root-cause test plan

**Status (2026-09-22, superseded below):** hibernate is OFF (`sudo bash gc2607-suspend-hibernate.sh disable`). This plan is how to find
out why resume hangs so it can be switched back on. Evidence and history: top block of
`docs/incidents/2026-05-silent-freezes.md`.

**What is already proven.** On 2026-09-21 the hibernate image was written completely and the machine powered off; the
next morning's RESUME hung and needed a power-button hold (`gc2607-hib-image-probe.py`, see the incident note). The
earlier record: 09-11 a resumed session died 64 s after resume; 07-01 one unexplained no-resume. Nothing can be logged
during a resume, so the cause is unknown. Do not guess one; the steps below each remove one suspect.

**Status (2026-10-09):** the same resume hang happened again (complete image, resume hung), and the record now splits
by power source: every cold resume on AC worked (6/6), both on battery hung (0/2). Steps 1-3 below were only ever run
on AC. Step 0 tests the battery case first. Hibernate is OFF until Step 0 passes.

## Step 0: resume on battery (2026-10-09)

Needs: one reboot after 2026-10-09, so the early SN740 ASPM rule is live in the initramfs. Each cycle can end in a
power-button hold; the boot after a hang triages itself and probes the image (`/var/log/gc2607-crash-triage/`).

1. `sudo bash gc2607-nvme-aspm.sh status`: `boot record` must show `gc2607-sn740-aspm: firmware left l1_aspm=..`.
   `sudo bash gc2607-hibernate-test.sh status`: every initramfs line `present`.
2. `sudo bash gc2607-hibernate-test.sh step2-prep`, then reboot (turns hibernate on, shows the console on resume).
3. Unplug the charger. `sudo bash gc2607-hibernate-test.sh step2-run battery`. When it is off, press power with the
   charger still out.
   - **Resumes:** repeat twice more on battery. Three in a row under one configuration is the bar for turning hibernate
     back on (`gc2607-suspend-hibernate.sh install 90min`), recorded in the incident note.
   - **Hangs:** photograph the screen, hold power, boot, read the newest `triage-report.txt` and `hib-image-probe.txt`.
     Then `sudo bash gc2607-hibernate-test.sh step3-shutdown` and repeat 3 on battery: firmware S4 is then bypassed.
     Resumes only in `shutdown` mode -> the firmware's S4 path on battery; keep `HibernateMode=shutdown` as the fix.
     Hangs in both -> the image-loading kernel on battery; compare the `gc2607-sn740-aspm` boot records on AC and
     battery (`journalctl -k -g gc2607-sn740-aspm`) before anything else.
4. `sudo bash gc2607-hibernate-test.sh cleanup` always (it turns hibernate OFF again).

## Preconditions (every step)

- Owner at the machine, on AC, all work saved. Any step can end in a power-button hold.
- **Never `systemctl restart systemd-logind`** on the live desktop: it strips GNOME's keyboard and mouse and forces
  a power-off (happened 2026-06-25 and 2026-09-22). Anything that "needs logind reloaded" waits for a reboot.
- Steps 1 and 2 write `/sys/power/state` directly, so systemd's sleep hooks do **not** run. That includes
  `gc2607-resume`'s `docker pause`, which dodges the runc freeze race. Pause containers by hand first:
  `docker ps -q | xargs -r docker pause`, and `docker ps -q --filter status=paused | xargs -r docker unpause` after.
- Check the kernel's resume target before starting: `cat /sys/power/resume /sys/power/resume_offset` must print
  `259:8` and `22100502` (true on 2026-09-22).
- Make the resume path legible for every step:
  ```
  echo 0 | sudo tee /sys/power/pm_async          # resume devices one at a time, so the last line names the culprit
  echo 1 | sudo tee /sys/power/pm_print_times    # print every device callback
  echo 1 | sudo tee /sys/power/pm_debug_messages
  sudo dmesg -n 8                                # all kernel messages to the console
  ```
  These reset at reboot.

## Step 1: kernel-only restore, no power cycle (~5 min)

`test_resume` writes the image, then restores from it at once, without powering off or going through the firmware.
systemd would overwrite `/sys/power/disk` with its own `HibernateMode`, so bypass it:

```
echo test_resume | sudo tee /sys/power/disk
echo disk | sudo tee /sys/power/state
```

- **Session comes back:** the kernel and driver restore path is fine. The fault is in the cold-boot path (firmware
  re-init, or the initrd loading the image). Go to step 2.
- **Hangs:** the fault is in kernel/driver resume and is now reproducible at will. Photograph the screen (the last
  device line is the suspect), hold power, then bisect drivers: unload the suspect module before step 1 and repeat.
  First candidates to unload one at a time are this machine's out-of-tree and camera stack (`gc2607`, `v4l2loopback`,
  the IPU6 modules), because they are the non-stock part of the resume path. That is an ordering choice, not a claim.

## Step 2: a real cold-boot resume with the console visible

1. `sudo bash gc2607-suspend-hibernate.sh enable` (deletes the two drop-ins that turn hibernate off; logind reads
   sleep.conf per call, so no restart).
2. Make boot output visible for this test only:
   `sudo grubby --update-kernel=ALL --remove-args="rhgb quiet" --args="no_console_suspend"`, then reboot so the
   running kernel carries them. Re-apply the four switches from Preconditions after the reboot.
3. `sudo systemctl hibernate`, let it power off, press power.
4. **Hangs:** photograph the screen, hold power. Then run `sudo python3 gc2607-hib-image-probe.py` before anything
   touches the swap file, to confirm the image was complete again (same failure as 09-21, not a new one).
5. **Resumes:** repeat 2 to 3 more times. One good cycle proved nothing on 07-01.

## Step 3: A/B the firmware S4 path

Only if step 2 still hangs. `/sys/power/disk` offers `platform` (firmware S4, current default) and `shutdown` (kernel
powers off, firmware not told about S4). Force `shutdown`:

```
sudo mkdir -p /etc/systemd/sleep.conf.d
printf '[Sleep]\nHibernateMode=shutdown\n' | sudo tee /etc/systemd/sleep.conf.d/96-gc2607-hibernate-shutdown-mode.conf
```

Repeat step 2.3 a few times. Hangs only under `platform` point at the firmware S4 path; hangs under both clear it.

## Optional: pm_trace

`/sys/power/pm_trace` exists on this kernel. It stores a hash of the last device-resume point in the RTC, so it
survives a hang plus power-cycle and is decoded from dmesg on the next boot. It corrupts the clock. The kernel
documents it for suspend-to-RAM; whether it catches the hibernate restore path here is **unverified**, so treat a
result from it as a lead, not a finding.

## Cleanup (always)

```
sudo grubby --update-kernel=ALL --remove-args="no_console_suspend" --args="rhgb quiet"
sudo rm -f /etc/systemd/sleep.conf.d/96-gc2607-hibernate-shutdown-mode.conf
```

Leave hibernate either OFF (`disable`) or ON (`install 90min` for lid-close on battery, which needs a reboot, not a
logind restart), according to the result. Record the outcome in the incident note.
