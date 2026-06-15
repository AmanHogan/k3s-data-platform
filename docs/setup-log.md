# Setup Log

This is a running record of the exact steps taken so far, in order, including any gotchas hit and how they were resolved. Use this as the source of truth for "what's actually been done" — `PLAN.md` describes the intended plan, this file describes what actually happened.

---

## Phase 0: Proxmox Foundation

### Step 1: Download the Proxmox VE ISO

1. On your Mac, go to: **[https://www.proxmox.com/en/downloads](https://www.proxmox.com/en/downloads)** -> "Proxmox VE" -> download the latest **Proxmox VE 8.x ISO Installer** (large file, ~1.3GB)
2. Note where it lands (probably `~/Downloads/proxmox-ve_8.x-x.iso`)

### Step 2: Flash it onto your external SSD with Raspberry Pi Imager

Balena Etcher was considered but skipped in favor of Raspberry Pi Imager (trusted, supports arbitrary ISOs via "Use custom"). The external USB SSD (previously used for the Ubuntu installer) was reused as the boot media instead of a USB stick — any USB-bootable drive works.

1. Open **Raspberry Pi Imager** ([https://www.raspberrypi.com/software/](https://www.raspberrypi.com/software/) if not installed)
2. Plug in the external SSD via USB
3. Click **"Choose OS"** -> scroll down -> **"Use custom"** -> select the downloaded Proxmox `.iso`
4. Click **"Choose Storage"** -> select the external SSD (double-check it's the SSD, not the Mac's internal drive — this gets fully erased)
5. Click **"Write"** -> confirm -> wait for write + verify

### Step 3: Physical setup gathering

Gathered before starting on hp-node-1:

- Monitor + keyboard connected to the HP ProDesk
- Ethernet cable connected
- External SSD (with Proxmox installer) ready to plug in

### Step 4: Connect everything to hp-node-1

1. Plugged in monitor, keyboard, ethernet, and the external SSD (USB) with the Proxmox installer
2. Powered on hp-node-1

### Step 5: BIOS configuration (one-time)

Entered BIOS setup with **F10** at the HP logo.

**Secure Boot / Legacy Support:**

- Found under **Security -> Secure Boot Configuration**
- The combined setting was already at **"Legacy Support Disable + Secure Boot Disable"** — this is the correct value (UEFI mode, Secure Boot off). No change needed.
- The "Enable MS UEFI CA key" setting was left as-is (irrelevant while Secure Boot is off).

**Virtualization Technology (VT-x):**

- Not located under the Security tab (where TPM, TXT, Sure Start, SGX, etc. live).
- Found under **Advanced -> System Options** (grouped with Hyper-Threading, Active Cores, Limit CPUID Maximum, etc.)
- Enabled **Virtualization Technology (VTx)**
- Left **Virtualization Technology for Directed I/O (VTd)** disabled (not needed — that's for PCIe passthrough)

Saved and exited BIOS with **F10** -> confirmed save -> machine rebooted.

### Step 6: Boot from the external SSD

1. On reboot, pressed **F9** repeatedly to bring up the one-time Boot Menu
2. Selected the external SSD (shown as a USB drive)
3. Proxmox installer splash screen appeared

### Step 7: Run the Proxmox installer

1. Selected **"Install Proxmox VE"** (graphical)
2. Accepted the EULA
3. **Target Disk:** only one disk was listed — `/dev/nvme0n1`, 238.47GiB, Toshiba. This is the internal 256GB SSD (256GB drives report as ~238GiB due to GB/GiB conversion). The external USB SSD was correctly excluded from the target list by the installer. Selected `/dev/nvme0n1`.
4. Left filesystem options at default (ext4 + LVM, not ZFS)
5. Set country, timezone, keyboard layout
6. Set root password and an admin email
7. Network configuration for **pve1**:
   - Hostname (FQDN): `pve1.local`
   - IP address: `192.168.1.210`
   - Netmask: `255.255.255.0`
   - Gateway: `192.168.1.254`
   - DNS: `192.168.1.254`
8. Reviewed summary, clicked **Install** (wipes `/dev/nvme0n1`, installs Proxmox, ~5-10 min)

### Step 8: Finish and reboot

1. Removed the external USB SSD before/during the reboot prompt (to avoid re-booting the installer)
2. Clicked **Reboot**
3. Console eventually showed the management URL: `https://192.168.1.210:8006/`

### Step 9: Access the web UI from the Mac

Initial attempts to reach `https://192.168.1.210:8006` from Chrome and Brave failed with `ERR_ADDRESS_UNREACHABLE`, even though:

- `ping 192.168.1.210` succeeded (network/IP fine)
- `curl -kv https://192.168.1.210:8006` succeeded with a clean `200 OK` and the Proxmox login page HTML (server fine)

**Root cause:** macOS's per-app "Local Network" permission prompt. Chrome and Brave had been denied access to the local network at some point, so they refused to even attempt the connection (`ERR_ADDRESS_UNREACHABLE`), while `curl` (Terminal) was unaffected.

**Fix:** Opened **Firefox** instead, allowed the "Local Network" permission prompt when asked, and successfully reached the Proxmox login page.

(Note for later: Chrome/Brave can likely be fixed via **System Settings -> Privacy & Security -> Local Network** -> enable for those browsers, if desired.)

Logged in:

- Username: `root`
- Password: set during install
- Realm: `Linux PAM standard authentication`

### Step 10: Post-install repo fix

Opened the **Shell** from the Proxmox web UI (click node `pve1` in the sidebar -> ">_ Shell").

Ran:

```bash
# Disable the enterprise repo
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list

# Add the no-subscription repo
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# Update and upgrade
apt update && apt full-upgrade -y
```

Hit a second enterprise repo error during `apt update`:

```
Err:9 https://enterprise.proxmox.com/debian/ceph-quincy bookworm InRelease  401  Unauthorized
```

**Fix:** there's a separate file for the Ceph enterprise repo. Listed the directory to find it, then disabled it the same way as the main enterprise repo:

```bash
ls /etc/apt/sources.list.d/

# disable the ceph enterprise repo (filename may vary slightly, e.g. ceph.list)
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list

# re-run
apt update && apt full-upgrade -y
```

After this, `apt update` completed with no `Err:` lines, and `apt full-upgrade -y` finished successfully.

### Step 11: Install Tailscale on pve1

Still in the Proxmox shell:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

`tailscale up` printed a login URL (`https://login.tailscale.com/a/xxxxxxxxxxxx`). Opened that URL in a browser, logged into Tailscale account, approved the device.

Verified:

```bash
tailscale status
```

`pve1` shows up with a `100.x.x.x` Tailscale IP.

### Step 12: Install Tailscale on the Mac

1. Downloaded from [https://tailscale.com/download/mac](https://tailscale.com/download/mac) (or `brew install --cask tailscale`)
2. Opened the app, signed in with the same Tailscale account
3. Confirmed both `pve1` and the Mac appear under the same tailnet at [https://login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)
4. Verified connectivity: `tailscale status` on the Mac shows `pve1`, and `ping <pve1's 100.x.x.x IP>` responds

**pve1 is now fully done:** Proxmox installed, repo fixed, Tailscale connected on both pve1 and the Mac.

---

## Phase 0 (continued): pve2 (hp-node-2)

Repeat Steps 4-12 above on the second HP ProDesk (hp-node-2), with these differences:

- IP address: `192.168.1.211`
- Hostname (FQDN): `pve2.local`
- Reuse the same external SSD (still has the Proxmox installer on it)
- BIOS: check `Advanced -> System Options -> Virtualization Technology (VTx)` is enabled, and confirm Secure Boot is already at "Legacy Support Disable + Secure Boot Disable" (same as pve1 — may already be set this way out of the box, or may need the same one-time change)
- Everything else (installer flow, target disk selection, repo fix commands including the `ceph.list` fix, Tailscale install/auth) is identical to pve1

Once pve2's web UI is reachable (`https://192.168.1.211:8006`), if using Chrome/Brave, enable **System Settings -> Privacy & Security -> Local Network** for that browser to avoid the `ERR_ADDRESS_UNREACHABLE` issue hit on pve1 (or just use Firefox again).

---

pve2 completed Steps 4-12 with IP `192.168.1.211` / hostname `pve2.local`, following the same process as pve1 (including the `ceph.list` repo fix). Tailscale connected successfully.

**Phase 0 is now complete.** All three devices (pve1, pve2, Mac) are on the same tailnet and can reach each other via their `100.x.x.x` Tailscale addresses.

---

---

## Phase 1: k3s VMs (k3s-server on pve1, k3s-agent on pve2)

This section documents the clean, correct procedure for creating each VM — done once for `k3s-server` (pve1, `192.168.1.200`) and once for `k3s-agent` (pve2, `192.168.1.201`).

### Step 1: Upload the Ubuntu 22.04 Server ISO

In the Proxmox web UI for the target node (pve1 or pve2): node name in sidebar -> **local (pveX)** storage -> **ISO Images** tab -> **Download from URL** -> Ubuntu 22.04 Server ISO URL (check ubuntu.com/download/server for the current point release).

### Step 2: Create the VM

Click **Create VM**:

- **General:** Node = pve1 (or pve2), Name = `k3s-server` (or `k3s-agent`)
- **OS:** select the Ubuntu 22.04 ISO, Guest OS Type Linux / 6.x - 2.6 Kernel
- **System:** check **Qemu Agent** -> Enabled (do this now, at creation time, so no later restart is needed)
- **Disks:** 220 GiB, storage `local-lvm`
- **CPU:** 4 cores
- **Memory:** 14336 MiB (14GB)
- **Network:** bridge `vmbr0`, model VirtIO
- **Confirm:** review, click **Finish**

### Step 3: Start the VM and run the Ubuntu installer

Start the VM, open **Console**, and go through the installer:

| Screen | Value |
|---|---|
| Language / Keyboard | English / your layout |
| Installation type | Ubuntu Server (full, not minimized) |
| Network connections | Manual IPv4 — see table below |
| Proxy | leave blank |
| Ubuntu archive mirror | leave default |
| Storage configuration | "Use an entire disk" -> select the ~220GB disk -> confirm |
| Your name | anything, e.g. `aman` |
| Server's name | `k3s-server` or `k3s-agent` |
| Username | your choice, e.g. `aman` |
| Password | **letters and numbers only** — symbols (e.g. `?`) can be mistyped due to noVNC keyboard mapping differences between console and SSH |
| SSH Setup | check "Install OpenSSH server" |
| Featured Server Snaps | select nothing |

**Network connections (Manual IPv4):**

| Field | k3s-server | k3s-agent |
|---|---|---|
| Subnet | `192.168.1.0/24` | `192.168.1.0/24` |
| Address | `192.168.1.200` | `192.168.1.201` |
| Gateway | `192.168.1.254` | `192.168.1.254` |
| Name servers | `192.168.1.254` | `192.168.1.254` |
| Search domains | (blank) | (blank) |

After install completes, select **Reboot Now**. If it hangs on "remove the installation medium," go to **Hardware** tab -> CD/DVD drive -> set to "Do not use any media," then it boots cleanly.

### Step 4: First SSH connection from the Mac

```bash
# only needed if the IP was used by something else before:
ssh-keygen -R 192.168.1.200   # or .201 for k3s-agent

ssh <username>@192.168.1.200  # or .201
```

Accept the new host key prompt (`yes`).

### Step 5: Update packages and install the QEMU guest agent

```bash
sudo apt update && sudo apt upgrade -y
```

If a blue/magenta "which services should be restarted" dialog (`needrestart`) appears: the default selections are fine — press **Tab** until **`<Ok>`** is highlighted, then **Enter**.

```bash
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

Since "Qemu Agent" was enabled in the VM's System settings at creation time (Step 2), no VM restart is needed — Proxmox's Summary tab should show the VM's IP shortly after this.

### Step 6: Disable swap (Kubernetes requirement)

```bash
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
```

### Step 7: Install Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Open the printed login URL in a browser, log in with the same Tailscale account, approve the device.

### Step 8: Verify

```bash
tailscale status
```

After both VMs are done, this shows all 5 devices on the tailnet:

```
k3s-agent          linux
amans-macbook-air  macOS
k3s-server         linux
pve1               linux
pve2               linux
```

(it's normal for a device to occasionally show `offline, last seen Xm ago` if it was recently rebooted/idle — Tailscale reconnects automatically)

**Phase 1 VM creation is now complete** for both `k3s-server` (pve1, `192.168.1.200`) and `k3s-agent` (pve2, `192.168.1.201`). Both are on the tailnet, have the QEMU guest agent running, swap disabled, and OpenSSH accessible from the Mac.

---

## Phase 1 (continued): Install k3s and configure kubectl

### Step 1: Install k3s server on `k3s-server` (192.168.1.200)

```bash
ssh aman@192.168.1.200

curl -sfL https://get.k3s.io | sh -s - server \
  --write-kubeconfig-mode 644 \
  --disable servicelb \
  --node-ip=192.168.1.200 \
  --tls-san=192.168.1.200 \
  --tls-san=k3s-server
```

Verify locally:

```bash
sudo k3s kubectl get nodes
```

Shows `k3s-server` as `Ready`.

### Step 2: Get the node token

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Copy the full token value.

### Step 3: Install k3s agent on `k3s-agent` (192.168.1.201)

```bash
ssh aman@192.168.1.201

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.200:6443 K3S_TOKEN=<TOKEN> sh -s - agent \
  --node-ip=192.168.1.201
```

Note: `sudo k3s kubectl get nodes` does **not** work on the agent itself — agents don't run the API server or have a kubeconfig, so this is expected and not an error. Always run `kubectl`/`k3s kubectl` from `k3s-server`.

### Step 4: Verify both nodes from `k3s-server`

```bash
ssh aman@192.168.1.200
sudo k3s kubectl get nodes
```

Both `k3s-server` and `k3s-agent` show `Ready` (agent may take 10-30 seconds to register after install).

### Step 5: Install kubectl + Helm on the Mac

```bash
brew install kubectl helm
```

### Step 6: Copy the kubeconfig to the Mac

```bash
mkdir -p ~/.kube
scp aman@192.168.1.200:/etc/rancher/k3s/k3s.yaml ~/.kube/config
```

### Step 7: Point the kubeconfig at the cluster (initial LAN setup)

The copied file points at `https://127.0.0.1:6443` (correct only on the server itself). Initially updated to the LAN IP:

```bash
sed -i '' 's/127.0.0.1/192.168.1.200/' ~/.kube/config
```

(`-i ''` is required for macOS `sed`)

Verified:

```bash
kubectl get nodes
```

Both nodes showed `Ready` from the Mac.

---

## Phase 1 (continued): Switch kubeconfig to Tailscale (location-independent access)

The LAN IP (`192.168.1.200`) only works while the Mac is on the home network. To make `kubectl` work from anywhere (matching the plan's Tailscale goal), the kubeconfig was switched to use `k3s-server`'s Tailscale IP instead.

### Step 1: Get k3s-server's Tailscale IP

```bash
ssh aman@192.168.1.200
tailscale ip -4
```

Result: `100.112.249.53`

### Step 2: Add the Tailscale IP as an additional TLS SAN

The server's TLS certificate only allows the addresses it was issued for (`192.168.1.200`, `k3s-server`). Added the Tailscale IP via a k3s config file:

```bash
sudo mkdir -p /etc/rancher/k3s
sudo tee -a /etc/rancher/k3s/config.yaml <<EOF
tls-san:
  - "100.112.249.53"
EOF
```

### Step 3: Restart k3s to regenerate the server certificate

```bash
sudo systemctl restart k3s
sudo k3s kubectl get nodes
```

Confirmed both nodes still `Ready` after restart.

### Step 4: Update the Mac's kubeconfig to use the Tailscale IP

```bash
sed -i '' 's/192.168.1.200/100.112.249.53/' ~/.kube/config
```

### Step 5: Verify

```bash
kubectl get nodes
```

Works — `kubectl` now reaches the cluster via Tailscale, independent of which network the Mac is on.

---

## Phase 1 (continued): MetalLB + namespaces

### Step 1: Apply the MetalLB IPAddressPool + L2Advertisement

MetalLB itself was installed earlier (manifests). Config lives in `platform/metallb/metallb-config.yaml`:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.240-192.168.1.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - local-pool
```

```bash
kubectl apply -f platform/metallb/metallb-config.yaml
```

### Step 2: Verify Traefik got a MetalLB IP

```bash
kubectl get svc -n kube-system traefik
```

`EXTERNAL-IP` came up as `192.168.1.240` (first in the pool).

### Step 3: Create the namespaces

```bash
kubectl create namespace portfolio
kubectl create namespace data-platform
kubectl create namespace cicd
kubectl create namespace monitoring
```

(Also declared in `platform/namespaces.yaml` for reproducibility.)

> **Known config issue to fix:** the router's DHCP range overlaps the MetalLB pool
> (`192.168.1.240-250`) — the Mac was handed `192.168.1.247` by DHCP. Shrink the
> router DHCP range to end at `.239` so `.240-.254` is reserved for MetalLB and
> nothing else can collide with a service IP.

---

## Phase 2: In-cluster Docker registry

### Step 1: Apply the registry manifest

`platform/registry/registry.yaml` — `registry:2` Deployment + 20Gi local-path PVC +
LoadBalancer Service pinned to `192.168.1.245:5001`.

```bash
kubectl apply -f platform/registry/registry.yaml
kubectl get pods -n cicd          # registry-... Running
kubectl get svc -n cicd registry  # EXTERNAL-IP 192.168.1.245
```

### Step 2: Verify the registry answers (in-cluster and from a node)

```bash
# in-cluster (how Jenkins will reach it):
kubectl run regtest --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://registry.cicd.svc.cluster.local:5001/v2/_catalog

# from a node (how k3s pulls):
ssh aman@192.168.1.200
curl http://192.168.1.245:5001/v2/_catalog
```

Both return `{"repositories":[]}` (empty = correct, nothing pushed yet).

> Note: the registry's LoadBalancer IP is reachable in-cluster and from the nodes,
> but **not** directly from the Mac over WiFi (MetalLB L2 ARP). This is cosmetic —
> the registry is only consumed in-cluster (Jenkins push, k3s pull).

### Step 3: Trust the (plain-HTTP) registry on BOTH nodes

containerd refuses to pull from an HTTP registry unless whitelisted. On **each** node
(`k3s-server` and `k3s-agent`) — note the agent needs the dir created first:

```bash
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<'EOF'
mirrors:
  "192.168.1.245:5001":
    endpoint:
      - "http://192.168.1.245:5001"
configs:
  "192.168.1.245:5001":
    tls:
      insecure_skip_verify: true
EOF
```

Then restart the right service per node:

```bash
sudo systemctl restart k3s          # on k3s-server
sudo systemctl restart k3s-agent    # on k3s-agent
```

Verify with `sudo cat /etc/rancher/k3s/registries.yaml` on each.

---

## Phase 2 (continued): Jenkins

### Step 1: Install Jenkins via Helm into `cicd`

Values in `platform/jenkins/values.yaml` (LoadBalancer `192.168.1.246:8080`, local-path
persistence 8Gi, Kubernetes build agents in `cicd`, plus `docker-workflow` +
`credentials-binding` plugins on top of the chart defaults).

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update
helm install jenkins jenkins/jenkins -n cicd -f platform/jenkins/values.yaml
kubectl get pods -n cicd -w     # wait for jenkins-0 to reach 2/2 Running
```

> Gotcha: newer chart renamed `controller.adminUser` -> `controller.admin.username`.

### Step 2: Access the Jenkins UI (Tailscale-only, durable)

The MetalLB LoadBalancer IP (`192.168.1.246`) is not directly reachable from the Mac
over WiFi (the L2/ARP issue). Instead, reach Jenkins via the **server node's Tailscale
IP + the service NodePort** — works from home or anywhere, survives reboots, no
port-forward needed and inherently Tailscale-only:

```bash
kubectl get svc -n cicd jenkins
# PORT(S) shows 8080:<nodePort>/TCP  ->  open http://100.112.249.53:<nodePort>
```

Initial admin password (one time only — Jenkins state persists on the PVC afterward):

```bash
kubectl exec -n cicd svc/jenkins -c jenkins -- \
  cat /run/secrets/additional/chart-admin-password && echo
```

Log in as `admin`. (This node-Tailscale-IP + NodePort pattern is how all admin UIs
here — Jenkins, ArgoCD, Headlamp — are reached.)

### Step 3: Add GitHub credentials

1. GitHub -> Settings -> Developer settings -> Personal access tokens (classic) ->
   generate a token with the `repo` scope.
2. Jenkins -> Manage Jenkins -> Credentials -> System -> Global credentials ->
   Add Credentials:
   - Kind: `Username with password`
   - Username: GitHub username (`AmanHogan`)
   - Password: the `ghp_...` token
   - ID: `github-pat`  (referenced by this ID in pipelines)

---

## Phase 2 (continued): hello-world test app + first pipeline

### Step 1: Create the throwaway app repo

Separate repo (not the infra repo): `github.com/AmanHogan/hello-world`. Local copy at
`/Users/amanhogan/dev/hello-world`. Files:

- `index.html` — static page served by nginx
- `Dockerfile` — `nginx:1.27-alpine` + the page
- `Jenkinsfile` — Kaniko build + push (below)

`Jenkinsfile` builds with **Kaniko** (no Docker daemon / no privileged container) in an
ephemeral Kubernetes agent pod and pushes to the in-cluster registry:

```groovy
agent {
  kubernetes {
    yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:v1.23.2-debug
      command: ["sleep"]
      args: ["infinity"]
      tty: true
'''
  }
}
// ...
/kaniko/executor --context "$(pwd)" --dockerfile Dockerfile \
  --destination 192.168.1.245:5001/hello-world:${BUILD_NUMBER} \
  --destination 192.168.1.245:5001/hello-world:latest \
  --insecure --skip-tls-verify
```

(`--insecure --skip-tls-verify` because the registry is plain HTTP.)

```bash
cd /Users/amanhogan/dev/hello-world
git init && git add -A && git commit -m "Initial hello-world app"
git branch -M main
git remote add origin https://github.com/AmanHogan/hello-world.git
git push -u origin main
```

### Step 2: Create the Jenkins pipeline job

Jenkins -> New Item -> name `hello-world` -> **Pipeline** -> OK. In the Pipeline section:

- Definition: **Pipeline script from SCM**
- SCM: Git
- Repository URL: `https://github.com/AmanHogan/hello-world.git`
- Credentials: `github-pat`
- Branch Specifier: `*/main`
- Script Path: `Jenkinsfile`

Save -> **Build Now** -> watch Console Output.

### Step 3: Verify the image landed in the registry

Build finishes green (`Finished: SUCCESS`). From the server node:

```bash
ssh aman@192.168.1.200
curl http://192.168.1.245:5001/v2/_catalog
# {"repositories":["hello-world"]}
```

End-to-end build -> push loop confirmed working.

---

## Phase 2 (continued): ArgoCD (GitOps deploy)

### Step 1: Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -w     # wait for all ~7 pods Running
```

### Step 2: Expose the UI (NodePort, reached via node Tailscale IP)

```bash
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort"}}'
kubectl get svc argocd-server -n argocd   # note the 443:<nodePort>
```

UI at `https://100.112.249.53:<nodePort>` (self-signed cert — click through the warning).

### Step 3: Log in

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Username `admin` + that password.

---

## Phase 2 (continued): Deploy hello-world via ArgoCD + close the GitOps loop

### Step 1: Deploy manifests in the infra repo

- `manifests/hello-world/deployment.yaml` — runs `192.168.1.245:5001/hello-world:<tag>`
- `manifests/hello-world/service.yaml` — NodePort
- `argocd-apps/hello-world.yaml` — ArgoCD Application: watches `manifests/hello-world`
  on `master`, deploys to namespace `hello-world`, `automated: {prune, selfHeal}`,
  `CreateNamespace=true`

Commit + push them, then register the Application (it auto-syncs):

```bash
git add manifests/ argocd-apps/ && git commit -m "Add hello-world deploy" && git push origin master
kubectl apply -f argocd-apps/hello-world.yaml
```

App goes Synced/Healthy; pod runs; page at `http://100.112.249.53:<nodePort>`.

### Step 2: Make it fully automatic (Jenkins writes the tag back to Git)

Added a second stage to `hello-world`'s `Jenkinsfile`: a `git` container clones the
infra repo, `sed`s the new unique build tag into `deployment.yaml`, and pushes. ArgoCD
sees the manifest change and redeploys. Uses the `github-pat` Jenkins credential.

Full loop, hands-off:

```
git push (app repo)
  -> Jenkins: Kaniko build + push image:<build-number> to registry
  -> Jenkins: update deployment.yaml tag + push to infra repo
  -> ArgoCD: detect manifest change -> deploy new pod
```

> After this, Jenkins pushes commits to the infra repo `master`. Run
> `git pull origin master` on the Mac before editing the infra repo to stay in sync.

---

## Phase 2 (continued): Headlamp dashboard

### Step 1: Install (Helm, into kube-system)

```bash
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update
helm install headlamp headlamp/headlamp -n kube-system
```

### Step 2: Expose (NodePort)

```bash
kubectl patch svc headlamp -n kube-system -p '{"spec":{"type":"NodePort"}}'
kubectl get svc headlamp -n kube-system   # note the nodePort
```

### Step 3: Login token (cluster-admin service account)

`platform/headlamp/headlamp-admin.yaml` defines a `headlamp-admin` ServiceAccount +
cluster-admin ClusterRoleBinding.

```bash
kubectl apply -f platform/headlamp/headlamp-admin.yaml
kubectl create token headlamp-admin -n kube-system --duration=8760h
```

Open the URL, paste the token.

---

## Access cheat sheet (all Tailscale-only, via the server node's Tailscale IP)

Server node Tailscale IP: `100.112.249.53`. NodePorts are assigned by Kubernetes and
stable across restarts — re-check any with `kubectl get svc -n <ns> <name>`.

| Service          | URL                          | Notes                       |
| ---------------- | ---------------------------- | --------------------------- |
| hello-world site | http://100.112.249.53:32543  | the demo app                |
| Jenkins          | http://100.112.249.53:32430  | admin                       |
| ArgoCD           | https://100.112.249.53:30789 | admin (self-signed cert)    |
| Headlamp         | http://100.112.249.53:32526  | paste service-account token |

Initial passwords/tokens:

```bash
# Jenkins admin password (one-time)
kubectl exec -n cicd svc/jenkins -c jenkins -- cat /run/secrets/additional/chart-admin-password && echo
# ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo
# Headlamp token (regenerate anytime)
kubectl create token headlamp-admin -n kube-system --duration=8760h
```

---

## Phase 3: Cloudflare Tunnel (public access for hello-world)

### Step 1: Register a domain via Cloudflare

dash.cloudflare.com -> Domain Registration -> Register a Domain. Registering
through Cloudflare directly auto-adds it to the account as a zone (no separate
nameserver-pointing step needed).

### Step 2: Create a Tunnel

one.dash.cloudflare.com (Zero Trust dashboard) -> Networks -> Tunnels -> Create a
tunnel -> connector type **Cloudflared** -> name it (e.g. `k3s-homelab`) -> Save.
On the "install connector" page, copy the tunnel **token** (`eyJ...`) — used to
authenticate the in-cluster connector. Don't run the shown docker command; deploy
as a k8s pod instead (next step).

### Step 3: Deploy cloudflared in-cluster

`platform/cloudflare/cloudflared.yaml` — namespace `cloudflare` + a Deployment
running `cloudflare/cloudflared:latest`, reading the tunnel token from a Secret.

```bash
kubectl create namespace cloudflare
kubectl create secret generic cloudflared-token -n cloudflare \
  --from-literal=token='<tunnel token from dashboard>'
kubectl apply -f platform/cloudflare/cloudflared.yaml
kubectl get pods -n cloudflare -w     # wait for Running
```

Tunnel shows **Healthy** in the Zero Trust dashboard once the pod is up.

### Step 4: Route a public hostname to hello-world

Tunnel -> **Public Hostname** tab -> Add a public hostname:
- Subdomain/domain: pick the hostname (e.g. blank for root, or `hello.<domain>`)
- Service Type: `HTTP`
- Service URL: `hello-world.hello-world.svc.cluster.local:80` (in-cluster Service
  DNS — `cloudflared` runs inside the cluster so it resolves this directly)

Save — Cloudflare auto-creates the DNS record (CNAME to `<tunnel-id>.cfargotunnel.com`,
not to a home IP, so it survives IP changes / moving).

### Step 5: Verify

`https://<hostname>` loads the hello-world page, valid HTTPS (Cloudflare cert), from
any network (test on cellular, not home WiFi, for a true public-access check).

> Note: immediately after going live, Cloudflare Analytics will show traffic from
> scanners/bots worldwide (e.g. Switzerland, Japan, Finland, Germany) — this is
> normal internet background noise (Certificate Transparency logs broadcast new
> certs the instant they're issued, and bots scan continuously). Not a sign of
> compromise; happens to every new public site.

### Step 6: Security hardening (Cloudflare dashboard, one-time)

- **2FA on the Cloudflare account** (Profile -> Authentication) — most important,
  the account now controls DNS + tunnel routing into the home network.
- **SSL/TLS -> Edge Certificates -> Always Use HTTPS** -> On
- **SSL/TLS -> Overview** -> mode `Full` or `Full (strict)`
- **Security -> Bots -> Bot Fight Mode** -> On
- Confirm the tunnel's Public Hostname list contains **only** the intended
  hostname(s) — no accidental wildcards exposing other in-cluster services.
- (Later, when the real portfolio site is up) consider rate-limiting rules and a
  default-deny WAF rule before adding further public hostnames.

---

## Status / Next Up

**Phases 0, 1, 2, 3 complete — the core platform is fully stood up, proven end-to-end, and publicly reachable.**

- **Phase 0 (Proxmox):** pve1 + pve2 installed, repos fixed (incl. ceph.list), Tailscale.
- **Phase 1 (k3s + cluster):** k3s-server (`192.168.1.200` / Tailscale `100.112.249.53`) + k3s-agent (`192.168.1.201`), Ubuntu 22.04, swap off, qemu-guest-agent; Mac kubectl via Tailscale IP; MetalLB pool `.240-.250` (Traefik on `.240`); namespaces `portfolio`/`data-platform`/`cicd`/`monitoring`.
- **Phase 2 (CI/CD):** in-cluster registry (`192.168.1.245:5001`, trusted on both nodes); Jenkins (Kaniko builds); ArgoCD (GitOps deploy); Headlamp dashboard. hello-world proves the **full automatic loop**: push code → build → registry → manifest bump → ArgoCD deploy.
- **Phase 3 (Public access):** domain registered via Cloudflare; `cloudflared` tunnel (`platform/cloudflare/cloudflared.yaml`, namespace `cloudflare`) routes a public hostname -> `hello-world.hello-world.svc.cluster.local:80`. Verified live with valid HTTPS from outside the home network. Account hardening done (2FA, Always Use HTTPS, Full(strict) TLS, Bot Fight Mode).

**Open items / housekeeping:**

- Shrink router DHCP range to end at `.239` (currently overlaps the MetalLB pool `.240-.250`).
- `hello-world` is throwaway scaffolding — can be deleted (and its public hostname re-pointed) once the real portfolio site is built.
- If/when moving locations: Tailscale (`100.x.x.x`) and the Cloudflare Tunnel both survive unchanged (outbound-only / coordination-based). The thing to watch is the LAN subnet (`192.168.1.x`) — configure the new router to keep the same `192.168.1.0/24` range to avoid reconfiguring Proxmox/k3s/MetalLB static IPs.

**Next (all optional / on your schedule):**

- **Phase 4** — the real portfolio site (first production app, same pipeline pattern as hello-world; swap the Cloudflare Tunnel's public hostname to point at it).
- **Phases 5-9** — data platform (MinIO, Kafka, Spark/Delta, JupyterHub, MLflow).
- **Phase 10** — observability (Prometheus/Grafana/Loki) — deferred; Proxmox dashboard covers node metrics for now.
