# hp-node-3 (EliteDesk 800 G4) — Thermal Issue & Fix

## What happened

hp-node-3 (pve3 / `192.168.1.212`) shut itself down overnight on 2026-07-04
while completely idle. Tailscale showed both `pve3` and `k3s-agent-2` going
offline around the same time. On physical inspection the machine was blinking
**4 red + 2 white** — HP's blink code for CPU thermal shutdown / overheating
protection.

Root cause: refurbished 2018 machine, likely dried-out thermal paste between the
CPU and heatsink and/or a seized/dusty fan. Common on machines that sat in a
warehouse before being resold.

## What the logs showed

`journalctl --list-boots` revealed 6 crashes in ~15 minutes during setup on
2026-07-03, each boot lasting shorter than the last (classic thermal runaway —
never cooled between reboots). After 19 hours powered off it booted fine at 36°C
— confirming thermal, not hardware failure.

```
-8  05:31 → 07:17  (normal, ~2hrs)
-7  08:13 → 08:17  (4 min then crash)
-6  08:22 → 08:23  (1 min then crash)
-5  08:29 → 08:33  (4 min then crash)
-4  08:35 → 08:37  (2 min then crash)
-3  08:44 → 08:45  (1 min then crash)
-2  08:47 → 08:47  (instant crash)
--- 19 hour gap (cooling) ---
-1  Sat 04:31  (booted fine at 36°C)
```

## Check temperature anytime (from Mac)

```bash
ssh root@100.85.197.56 "sensors | grep 'Package id 0'"
```

## Thermal watchdog service (auto-shutdown at 85°C)

Set up on pve3 so it shuts down cleanly instead of hard-crashing when temps spike.
Run these commands on pve3 via SSH:

**Step 1 — create the watchdog script:**
```bash
cat << 'EOF' > /usr/local/bin/thermal-watchdog.sh
#!/bin/bash
LIMIT=85
while true; do
  TEMP=$(sensors | grep 'Package id 0' | awk '{print $4}' | tr -d '+°C')
  if (( $(echo "$TEMP > $LIMIT" | bc -l) )); then
    echo "CRITICAL: CPU temp ${TEMP}°C exceeded ${LIMIT}°C — shutting down" | systemd-cat -t thermal-watchdog -p crit
    shutdown -h now
  fi
  sleep 30
done
EOF

chmod +x /usr/local/bin/thermal-watchdog.sh
```

**Step 2 — create the systemd service:**
```bash
cat << 'EOF' > /etc/systemd/system/thermal-watchdog.service
[Unit]
Description=Thermal watchdog — shutdown if CPU exceeds limit
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/thermal-watchdog.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now thermal-watchdog
```

**Verify it's running:**
```bash
systemctl status thermal-watchdog
```

**Check the watchdog logs:**
```bash
journalctl -t thermal-watchdog -f
```

## BIOS setting — auto power-on after shutdown

So the machine restarts itself after a clean thermal shutdown:

1. Reboot pve3, press **F10** at the HP logo to enter BIOS
2. Go to **Advanced → Power Management → After Power Loss**
3. Set to **Power On**
4. Save and exit

This means if the watchdog shuts it down cleanly, it'll come back on its own
once it cools — without needing physical intervention.

## Physical fix (do when home)

### Materials needed

| Item | Purpose | ~Cost |
|---|---|---|
| [Arctic MX-6 Thermal Compound](https://www.amazon.com/ARCTIC-MX-6-Compound-Performance-Durability/dp/B0C1YNPN3B) | Replace dried-out thermal paste between CPU and heatsink | ~$8 |
| [Compressed air duster](https://www.amazon.com/Falcon-Compressed-Disposable-Cleaning-DPSXL4T/dp/B00006IAOR) | Clear dust from fan and heatsink fins | ~$15 |
| Isopropyl alcohol 90%+ ([Amazon](https://www.amazon.com/Amazon-Brand-Isopropyl-Alcohol-Antiseptic/dp/B07NFSFBXQ)) | Clean off old dried thermal paste before applying new | ~$5 |
| Coffee filter or lint-free cloth | Wipe surface clean without leaving lint | ~$0 (household) |
| Small Phillips head screwdriver | Open case, remove heatsink screws | ~$0 (household) |

### Steps

1. **Power off completely** — hold power button, unplug the power cable.
2. **Open the case** — EliteDesk 800 G4 has a slide-off top panel, no tools needed for the outer case.
3. **Check the fan first** — spin it by hand. If it doesn't spin freely, the fan may need replacing (~$10-15).
4. **Blow out dust** — compressed air through the fan, heatsink fins, and all vents.
5. **Remove the heatsink** — unscrew the 4 screws in a cross pattern (loosen each a little at a time).
6. **Clean off old paste** — isopropyl alcohol + lint-free cloth on both the CPU surface and heatsink contact plate. Let dry completely.
7. **Apply new paste** — a pea-sized dot in the center of the CPU die. Don't spread it.
8. **Reinstall heatsink** — same cross pattern, tighten evenly.
9. **Power on and watch the fan** — should spin within seconds of boot.
10. **Monitor temps** — `sensors` should show idle CPU under 50°C.

### Prevention

- Keep hp-node-3 in open air with a few inches of clearance on all sides
- Don't stack anything on top of it
- Re-clean every 6-12 months if the environment is dusty

---

## Follow-up investigation (2026-07-05)

The stacking turned out to be a major factor: the two HP nodes were stacked on
top of each other, so pve3 was inhaling pve1/pve2's hot exhaust. After
unstacking, idle temps settled at 36-41°C and stayed there. The machine was
still hot to the touch 15 hours after shutdown purely from the node below it.

But pve3 kept becoming **unreachable** during the day even at healthy temps.
Findings from physical-console diagnosis:

- **Not thermal**: survived `stress-ng --cpu 6 --timeout 300s` at max 70°C
  (throttle point is 94°C, crit 100°C).
- **Not RAM (probably)**: survived `stress-ng --vm 4 --vm-bytes 75% --timeout 300s`.
- **Not power**: fans/lights stayed on during "outages" — machine was never off.
- **Not the thermal watchdog script**: journalctl showed it never fired.
- Several "crash" boot entries were actually **manual reboots** done because the
  machine was unreachable — the machine may never have crashed on its own that day.
- Separate issue found & fixed: `/etc/resolv.conf` had no nameservers
  (DNS dead → apt broken, everything slow). Fixed with router + 8.8.8.8.
  Should also be set permanently in Proxmox UI → pve3 → System → DNS.

### Current suspects for the network hangs (unresolved)

1. **e1000e NIC hardware unit hang** — known Linux bug on Intel NICs in these
   HP boxes. Machine runs fine but drops off the network until reboot.
   Look for `Detected Hardware Unit Hang` in `journalctl -k`.
   Mitigation: `ethtool -K eno1 tso off gso off` (non-persistent).
2. **Headless deep C-state freeze** — Intel boxes running without a monitor can
   freeze in deep power-saving states. Symptom pattern matched: with a monitor
   plugged in, everything worked flawlessly. Fix if confirmed: add
   `intel_idle.max_cstate=1` to kernel cmdline or disable deep C-states in BIOS.

### The trap (next steps)

1. Leave monitor attached, run normally. If stable for days → unplug monitor.
2. If hangs return headless → C-state bug; apply `intel_idle.max_cstate=1`.
3. If it hangs with monitor attached → do NOT reboot; at the console run:
   `journalctl -k | grep -iE "hang|e1000e|eno1"` and `ping 192.168.1.254`.
4. `qm set 100 --onboot 1` was needed — VM did not auto-start after host boot.

### CONFIRMED (2026-07-05, later): headless deep C-state freeze

Controlled experiment: pve3 ran flawlessly all day with a monitor attached
(survived CPU + RAM stress tests at healthy temps). The moment the display was
unplugged, the host went down and k3s-agent-2 restarted. Suspect #2 confirmed.

**Fix applied** (kernel side): cap C-states via GRUB —

```bash
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_idle.max_cstate=1"/' /etc/default/grub
update-grub
reboot
```

**Hardware alternative**: HDMI dummy plug (~$7) — fakes an attached display so
the iGPU never lets the system enter the buggy deep-idle state.

Verification: run headless for 24h after the fix. If stable, consider adding the
same GRUB line to pve1/pve2 preemptively (same model family).

### RESOLVED (2026-07-05): hot-unplug only, headless boot is fine

Verified: pve3 boots and runs normally with no monitor attached. The crashes
were triggered specifically by **unplugging the display while running** (i915
hot-unplug event). BIOS is Q21 02.33.00 (newer than HP's last published 02.31).

**Operating rule for pve3: shut down before connecting/disconnecting a monitor.
Never hot-unplug the display.** No dummy plug needed unless this recurs.
