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
