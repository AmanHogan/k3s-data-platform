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

## Symptoms

- 4 red + 2 white LED blink code on power-on
- Machine shuts down at idle (not under load) — indicates the thermal issue is
  severe, not marginal
- `pve3` and `k3s-agent-2` both show offline in `tailscale status`
- `kubectl get nodes` shows `k3s-agent-2` as `NotReady`

## Materials needed

| Item | Purpose | ~Cost |
|---|---|---|
| [Arctic MX-6 Thermal Compound](https://www.amazon.com/ARCTIC-MX-6-Compound-Performance-Durability/dp/B0C1YNPN3B) | Replace dried-out thermal paste between CPU and heatsink | ~$8 |
| [Compressed air duster](https://www.amazon.com/Falcon-Compressed-Disposable-Cleaning-DPSXL4T/dp/B00006IAOR) | Clear dust from fan and heatsink fins | ~$15 |
| Isopropyl alcohol 90%+ ([Amazon](https://www.amazon.com/Amazon-Brand-Isopropyl-Alcohol-Antiseptic/dp/B07NFSFBXQ)) | Clean off old dried thermal paste before applying new | ~$5 |
| Coffee filter or lint-free cloth | Wipe surface clean without leaving lint | ~$0 (household) |
| Small Phillips head screwdriver | Open case, remove heatsink screws | ~$0 (household) |

Total: ~$25-30 if starting from nothing.

## Fix procedure (when home)

1. **Power off completely** — hold power button, unplug the power cable.

2. **Open the case** — EliteDesk 800 G4 has a slide-off top panel, no tools
   needed for the outer case. Heatsink screws need the Phillips head.

3. **Check the fan first** — spin it by hand. If it doesn't spin freely or feels
   gritty, the fan may need replacing in addition to the paste (~$10-15 on Amazon
   for the G4-compatible fan).

4. **Blow out dust** — compressed air through the fan, heatsink fins, and all
   vents. Do this outside or in a well-ventilated area.

5. **Remove the heatsink** — unscrew the 4 screws around the CPU heatsink in a
   cross pattern (loosen each a little at a time, don't fully remove one before
   starting the others — prevents warping).

6. **Clean off old paste** — use isopropyl alcohol + lint-free cloth/coffee
   filter on both the CPU surface and the heatsink contact plate. Wipe until
   there's no grey residue left. Let dry completely (30 seconds).

7. **Apply new paste** — a pea-sized dot in the center of the CPU die. Don't
   spread it — the heatsink pressure spreads it when you tighten it down.

8. **Reinstall heatsink** — same cross pattern, tighten evenly.

9. **Power on and watch the fan** — it should spin up within seconds of boot.
   If it doesn't, the fan is the problem not the paste.

10. **Monitor temps** — from the pve3 shell:
    ```bash
    apt install -y lm-sensors
    sensors
    ```
    Idle CPU temp should be under 50°C. If it's still spiking above 80°C at
    idle after the paste replacement, the fan needs replacing.

## After the fix

Once pve3 is stable, SSH in and start k3s-agent-2's VM:

```bash
ssh root@100.85.197.56   # pve3 Tailscale IP
qm list                   # find k3s-agent-2's VM ID
qm start <vmid>
```

Then verify from the Mac:
```bash
kubectl get nodes          # k3s-agent-2 should return to Ready
tailscale status           # pve3 and k3s-agent-2 both online
```

## Prevention

- Keep hp-node-3 in open air with at least a few inches of clearance on all sides
  (mini PCs have tight airflow tolerance)
- Avoid stacking anything on top of it
- Re-clean every 6-12 months if the environment is dusty
