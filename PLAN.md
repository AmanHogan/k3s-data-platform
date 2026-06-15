# K3s Data Platform — Build Plan

A bare-metal home lab running Proxmox VE as the hypervisor layer, with k3s clusters inside VMs, a full CI/CD pipeline (Jenkins + ArgoCD), remote access via Tailscale, public access via Cloudflare, and a lightweight Databricks-style data platform (Kafka, Spark, Delta Lake, JupyterHub, MLflow) used at small/learning scale.

**Primary "must stay up" workload:** a personal portfolio website.
**Secondary "learning" workloads:** Kafka/Spark/Delta Lake/MLflow — explicitly small-scale (hundreds to low-thousands of rows), used to learn the mechanics, not to process real data volumes.

---

## Hardware

| Node          | Proxmox hostname | Specs                          | Proxmox IP    | k3s VM     | k3s VM IP     |
| ------------- | ---------------- | ------------------------------ | ------------- | ---------- | ------------- |
| HP ProDesk #1 | pve1             | i5-7500T, 16GB DDR4, 256GB SSD | 192.168.1.210 | k3s-server | 192.168.1.200 |
| HP ProDesk #2 | pve2             | i5-7500T, 16GB DDR4, 256GB SSD | 192.168.1.211 | k3s-agent  | 192.168.1.201 |

**Network:** Netgear GS305 unmanaged switch → AT&T router (192.168.1.254). All ethernet, fixed IPs via DHCP reservation (4 reservations total: 2 Proxmox hosts + 2 k3s VMs).

**Mac (dev machine):** kubectl, Helm, VS Code (with Kubernetes + YAML extensions), Tailscale client. No Docker, no k9s — Headlamp (in-cluster) is the dashboard, and all image builds happen in Jenkins.

---

## Workload Profile

This matters because it changes what's "safe" on this hardware:

| Workload            | Scale                        | Notes                                                                   |
| ------------------- | ---------------------------- | ----------------------------------------------------------------------- |
| Portfolio website   | Small, always-on             | The real production workload. Needs to stay up, gets snapshots/backups. |
| Kafka               | A few messages/min, KB-sized | Proof-of-concept only                                                   |
| Spark               | Hundreds to ~1000 rows       | Finishes in seconds, negligible RAM                                     |
| Delta Lake / MinIO  | MB-scale                     | Tiny data lake                                                          |
| JupyterHub / MLflow | Single user, occasional use  | Light, on-demand                                                        |

At this scale, none of the data-platform components come close to stressing 16GB/node. The plan below leans into "enterprise-like patterns at small scale" rather than "handle production data volume."

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Mac (Dev Machine)                            │
│   kubectl / Helm / VS Code / git push / Tailscale client            │
└────────────────────────────────┬─────────────────────────────────────┘
                                 │ via Tailscale (100.x.x.x) or LAN
                                 │
   ┌─────────────────────────────┴─────────────────────────────────┐
   │                                                                 │
   │   ┌─────────────────────────┐     ┌─────────────────────────┐ │
   │   │   pve1 (Proxmox VE)      │     │   pve2 (Proxmox VE)      │ │
   │   │   192.168.1.210          │     │   192.168.1.211          │ │
   │   │   ┌───────────────────┐  │     │   ┌───────────────────┐  │ │
   │   │   │  k3s-server VM    │  │     │   │  k3s-agent VM     │  │ │
   │   │   │  192.168.1.200    │◄─┼─────┼──►│  192.168.1.201    │  │ │
   │   │   │  ~13-14GB RAM     │  │     │   │  ~13-14GB RAM     │  │ │
   │   │   └───────────────────┘  │     │   └───────────────────┘  │ │
   │   └─────────────────────────┘     └─────────────────────────┘ │
   │                                                                 │
   │              Proxmox Cluster (shared web UI, snapshots)         │
   └─────────────────────────────────────────────────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │      k3s Cluster         │
                    │                          │
                    │  Flannel / MetalLB /     │
                    │  Traefik                 │
                    │                          │
                    │  ┌──────────────────┐    │
                    │  │  Portfolio Site   │    │  ← primary workload
                    │  └──────────────────┘    │
                    │                          │
                    │  ┌──────────────────┐    │
                    │  │  CI/CD            │    │
                    │  │  Jenkins/Registry │    │
                    │  │  ArgoCD           │    │
                    │  └──────────────────┘    │
                    │                          │
                    │  ┌──────────────────┐    │
                    │  │  Data Platform    │    │  ← learning workloads
                    │  │  Kafka/Spark/     │    │
                    │  │  MinIO/Jupyter/   │    │
                    │  │  MLflow            │    │
                    │  └──────────────────┘    │
                    │                          │
                    │  Tailscale + Cloudflare  │
                    │  Tunnel (remote access)  │
                    └──────────────────────────┘
```

---

## Networking

### IP Allocation (LAN, all static via DHCP reservation)

| Resource              | IP                | Notes                                |
| --------------------- | ----------------- | ------------------------------------ |
| AT&T router / gateway | 192.168.1.254     |                                      |
| pve1 (Proxmox host)   | 192.168.1.210     | Web UI: `https://192.168.1.210:8006` |
| pve2 (Proxmox host)   | 192.168.1.211     | Web UI: `https://192.168.1.211:8006` |
| k3s-server VM         | 192.168.1.200     | k3s control plane + workloads        |
| k3s-agent VM          | 192.168.1.201     | k3s worker                           |
| MetalLB pool          | 192.168.1.240–250 | LoadBalancer IPs for k8s services    |

### Tailscale (remote access)

- Installed on: both Proxmox hosts (hypervisor access from anywhere), both k3s VMs (kubectl/dashboard access), and the Mac
- Each device gets a stable `100.x.x.x` Tailscale IP + MagicDNS name regardless of physical location
- kubeconfig points at the k3s-server's Tailscale IP/hostname (works from anywhere, including a future apartment move)
- k3s `--tls-san` includes both the LAN IP and the Tailscale IP/hostname

### Cloudflare (public access)

- Domain registered/managed in Cloudflare
- `cloudflared` runs as a pod in the cluster, tunnels to Traefik
- Portfolio site: `https://<yourdomain>` → public, via tunnel
- Everything else (ArgoCD, Jenkins, Grafana, MinIO console, etc.) stays **Tailscale-only** — not tunneled publicly, since they have weak default credentials
- Cloudflare handles TLS for the public hostname automatically

### k3s Registry Configuration

Both k3s VMs need `/etc/rancher/k3s/registries.yaml` pointing at the in-cluster registry's MetalLB IP (filled in after Phase 3, same pattern as the existing Vagrant setup).

---

## Development Workflow (Dev/Prod Model)

Given the scale, this is a **lightweight** model — no duplicated platform services, but real promotion flow for apps.

### Namespaces

| Namespace       | Purpose                                                                                                                       |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `portfolio`     | Production portfolio site (deployed from `main`, ArgoCD auto-sync)                                                            |
| `portfolio-dev` | Optional — test a change before merging to `main`                                                                             |
| `data-platform` | Kafka, Spark, MinIO, JupyterHub, MLflow (single shared instance, no dev/prod split — these are "platform" services, not apps) |
| `cicd`          | Jenkins, registry, ArgoCD                                                                                                     |
| `monitoring`    | Prometheus/Grafana/Loki (if added later)                                                                                      |
| `kube-system`   | Traefik, MetalLB, Headlamp, Tailscale, cloudflared                                                                            |

### The promotion flow for an app (e.g. the portfolio site)

1. Feature branch → Jenkins builds a `:dev`-tagged (or `:pr-<n>`) image, deploys to `portfolio-dev` via a separate ArgoCD Application
2. You review it (via Tailscale URL or port-forward)
3. Merge to `main` → Jenkins builds a `:<git-sha>`-tagged image, updates `manifests/portfolio/deployment.yaml`, pushes
4. ArgoCD (watching `main`) auto-syncs `portfolio` namespace with the new image

For a personal portfolio site, the `portfolio-dev` step is optional — many people skip it and just test locally before pushing to `main`. Both are valid; start without it and add it if you want the extra safety net.

### Local development loop (on your Mac)

No Docker needed for day-to-day coding:

1. `git clone` the app repo
2. Run the app natively — `npm run dev`, `mvn spring-boot:run`, `python -m flask run`, etc.
3. For dependencies (Postgres, MinIO, Kafka), use `kubectl port-forward` to reach the in-cluster instance:
   ```bash
   kubectl port-forward svc/postgres 5432:5432 -n data-platform
   ```
   Your local app connects to `localhost:5432` as if Postgres were local.
4. Edit YAML manifests in VS Code — the Kubernetes extension gives schema validation/autocomplete for k8s resources
5. When ready, push — Jenkins handles the build/push/deploy from there (no local Docker required)

### Process for adding a brand-new application (end-to-end)

This is the full checklist — see `docs/adding-new-apps.md` for the detailed walkthrough (adapted from the existing Vagrant setup's version).

1. **App repo**: write code, add a `Dockerfile`
2. **App repo**: add a `Jenkinsfile` (build → push to in-cluster registry → update manifest tag → push infra repo)
3. **This infra repo**: add `manifests/<app-name>/` — namespace, Deployment, Service, Ingress (if exposing via Traefik)
4. **This infra repo**: add `argocd-apps/<app-name>.yaml` — Application CR pointing at `manifests/<app-name>/`, with `automated: { prune: true, selfHeal: true }`
5. Apply the Application CR once: `kubectl apply -f argocd-apps/<app-name>.yaml`
6. In Jenkins: create a pipeline job pointing at the app repo (Git URL, credentials, `Jenkinsfile` path)
7. Push code → Jenkins builds, pushes image, updates the manifest SHA, pushes infra repo → ArgoCD detects the change and syncs → pod runs the new image
8. Access: via Traefik (LAN/Tailscale `*.ts.net` hostname), and via Cloudflare Tunnel if it should be public

After step 5, **every future push to the app repo is fully automated** — no manual `kubectl apply` needed again.

---

## Full Stack

### Virtualization

| Component       | Purpose                                       | Install method                              |
| --------------- | --------------------------------------------- | ------------------------------------------- |
| Proxmox VE      | Hypervisor on both physical nodes             | ISO install (wipes existing Ubuntu)         |
| Proxmox Cluster | Joins both pve hosts into one management view | `pvecm`                                     |
| k3s-server VM   | Ubuntu 22.04, hosts k3s control plane         | Created via Proxmox UI or `qm` + cloud-init |
| k3s-agent VM    | Ubuntu 22.04, k3s worker                      | Created via Proxmox UI or `qm` + cloud-init |

### Cluster Foundation

| Component  | Purpose                  | Install method                |
| ---------- | ------------------------ | ----------------------------- |
| k3s server | Kubernetes control plane | Shell script (curl installer) |
| k3s agent  | Worker node              | Shell script (curl installer) |
| Flannel    | Pod networking           | Built into k3s                |
| MetalLB    | LoadBalancer IPs         | kubectl apply (manifests)     |
| Traefik    | Ingress controller       | Built into k3s                |

### Remote / Public Access

| Component                         | Purpose                                             | Install method                                       |
| --------------------------------- | --------------------------------------------------- | ---------------------------------------------------- |
| Tailscale                         | Private remote access (Proxmox hosts, k3s VMs, Mac) | Native install on Proxmox hosts + VMs, client on Mac |
| Cloudflare Tunnel (`cloudflared`) | Public access for the portfolio site only           | Deployment in-cluster                                |
| Cloudflare DNS                    | Domain management, TLS for public hostname          | Cloudflare dashboard                                 |

### Storage

| Component              | Purpose                                | Install method       |
| ---------------------- | -------------------------------------- | -------------------- |
| local-path provisioner | Default PVC storage                    | Built into k3s       |
| MinIO                  | S3-compatible object store / data lake | Helm, local-path PVC |

### CI/CD & GitOps

| Component       | Purpose                                 | Install method                 |
| --------------- | --------------------------------------- | ------------------------------ |
| Jenkins         | Builds images, updates manifests (DinD) | Helm                           |
| Docker Registry | Stores built images                     | Manifests, exposed via MetalLB |
| ArgoCD          | GitOps auto-sync from GitHub            | kubectl apply (manifests)      |

### Data Platform (learning scale)

| Component    | Purpose                              | Install method                 |
| ------------ | ------------------------------------ | ------------------------------ |
| Apache Kafka | Ingestion/streaming, KRaft mode      | Helm (Bitnami)                 |
| Apache Spark | Processing via SparkApplication CRDs | Helm (Spark Operator)          |
| Delta Lake   | Table format on MinIO                | Library, bundled in images     |
| JupyterHub   | Notebooks                            | Helm (Zero to JupyterHub)      |
| MLflow       | Experiment tracking                  | Helm or manifests              |
| PostgreSQL   | MLflow metadata                      | Helm (Bitnami), local-path PVC |

### Observability (optional, lower priority)

| Component            | Purpose       | Install method               |
| -------------------- | ------------- | ---------------------------- |
| Prometheus + Grafana | Metrics       | Helm (kube-prometheus-stack) |
| Loki + Promtail      | Logs          | Helm (loki-stack)            |
| Headlamp             | k8s dashboard | Manifests                    |

---

## Phases

> **Progress (see `docs/setup-log.md` for the exact steps actually run):**
> Phases 0, 1, 2 are **COMPLETE** — Proxmox on both nodes, k3s cluster, MetalLB,
> in-cluster registry, Jenkins (Kaniko), ArgoCD, and Headlamp are all up, with a
> hello-world app proving the full automatic loop (push -> build -> registry ->
> manifest bump -> ArgoCD deploy). Phase 3 is **COMPLETE for hello-world** —
> domain registered via Cloudflare, `cloudflared` tunnel deployed in-cluster
> (`platform/cloudflare/cloudflared.yaml`), public hostname routed to
> hello-world, verified live over HTTPS, account hardening done (2FA, Always
> Use HTTPS, Full(strict) TLS, Bot Fight Mode). Phase 4+ are not started; the
> portfolio site (Phase 4) will get its own public hostname via the same tunnel.
> Open item: shrink router DHCP range to end at `.239` (overlaps MetalLB `.240-.250`).

### Phase 0 — Proxmox Foundation  **(DONE)**

**Goal:** Both physical nodes running Proxmox VE, each managed independently, reachable via Tailscale.

> ⚠️ This wipes the existing Ubuntu install on both nodes. Nothing currently on them needs to be preserved (per current state — fresh nodes).

> **Note:** pve1 and pve2 are deliberately **not** clustered together. Each runs its own independent Proxmox install with its own web UI/login. They don't share storage and never need to move VMs between each other, so linking them together would only add a "2-node majority vote" failure mode for no real benefit — bookmark both UIs separately instead.

**Per node (repeat for both pve1 and pve2):**

1. Download the Proxmox VE 8.x ISO (on Mac)
2. Create a bootable USB (e.g. balenaEtcher)
3. Boot the HP ProDesk from USB (F12 for boot menu on most HP ProDesks)
4. Run the Proxmox installer:
   - Target disk: the 256GB SSD (this wipes it)
   - Country/timezone/keyboard
   - Set root password + admin email
   - Network: static IP (`192.168.1.210` for pve1, `192.168.1.211` for pve2), hostname `pve1.local` / `pve2.local`
5. Reboot, confirm web UI loads at `https://<pve-ip>:8006`
6. Post-install repo fix (avoid enterprise-repo errors on a no-subscription install):
   - Disable `pve-enterprise.list`
   - Add the `pve-no-subscription` repo
   - `apt update && apt full-upgrade -y`
7. Install Tailscale on the Proxmox host itself (gives remote hypervisor console access later)

**Deliverables:**

- `docs/proxmox-setup.md` — step-by-step with screenshots/notes, repo-fix commands
- `scripts/00-proxmox-post-install.sh` — repo fix + Tailscale install, run via Proxmox host shell

**Verify:**

- `https://192.168.1.210:8006` and `https://192.168.1.211:8006` each load independently and show their own single node
- Both hosts reachable via Tailscale from the Mac

---

### Phase 1 — k3s VMs + Cluster Bootstrap  **(DONE)**

**Goal:** k3s running inside VMs on both Proxmox hosts, manageable from the Mac via kubectl.

**Create the VMs (on each Proxmox host):**

1. Upload the Ubuntu 22.04 Server cloud image (or standard ISO) to Proxmox storage
2. Create VM:
   - `k3s-server` on pve1, `k3s-agent` on pve2
   - CPU: 3–4 cores
   - RAM: 13–14GB (leaves ~1–2GB for Proxmox itself)
   - Disk: ~220GB (leaves headroom on the 256GB SSD for Proxmox + ISOs)
   - Network: `vmbr0` (bridged — VM gets its own LAN IP)
   - Enable QEMU guest agent
3. Install Ubuntu Server 22.04 (minimal):
   - Hostname: `k3s-server` / `k3s-agent`
   - Static IP: `192.168.1.200` / `192.168.1.201` via netplan
   - Create user, enable SSH
   - Install `qemu-guest-agent` inside the VM

**Per-VM prep (both):** 4. `apt update && apt upgrade -y` 5. Disable swap (k8s requirement) 6. Confirm NTP sync (important for certs and Kafka) 7. Install Tailscale, join the same tailnet as the Proxmox hosts and Mac

**k3s server (on `k3s-server` VM):** 8. Install k3s server:

- `--write-kubeconfig-mode 644`
- `--disable servicelb` (MetalLB replaces it)
- `--node-ip=192.168.1.200`
- `--tls-san=192.168.1.200` and `--tls-san=<tailscale-ip-or-hostname>`

9. Extract node token from `/var/lib/rancher/k3s/server/node-token`

**k3s agent (on `k3s-agent` VM):** 10. Install k3s agent, joining via token: - `--node-ip=192.168.1.201`

**Mac:** 11. Copy kubeconfig from `k3s-server` (`/etc/rancher/k3s/k3s.yaml`) 12. Update `server:` field to the Tailscale hostname (works from anywhere) — keep LAN IP as a fallback context 13. Verify: `kubectl get nodes` shows both `Ready`

**MetalLB:** 14. `kubectl apply -f` MetalLB manifests 15. Apply `IPAddressPool` (`192.168.1.240–250`) + `L2Advertisement` 16. Verify Traefik gets a MetalLB IP

**Namespaces:** 17. Create `portfolio`, `data-platform`, `cicd`, `monitoring`

**Deliverables:**

- `scripts/01-create-vms.sh` — `qm create` + cloud-init commands (run on each Proxmox host) for repeatable VM provisioning
- `scripts/02-prepare-vm.sh` — swap/NTP/Tailscale setup, run inside each VM
- `scripts/03-install-k3s-server.sh`
- `scripts/04-install-k3s-agent.sh`
- `scripts/05-configure-mac.sh` — kubeconfig setup
- `platform/metallb/metallb.yaml`
- `platform/namespaces.yaml`

**Verify:**

- `kubectl get nodes` — both Ready, from the Mac over Tailscale
- `kubectl get svc -n kube-system traefik` — has an EXTERNAL-IP in 192.168.1.240–250
- Headlamp not yet installed — defer dashboard access to Phase 3

---

### Phase 2 — CI/CD Pipeline (Jenkins + Registry + ArgoCD)  **(DONE — Headlamp included)**

**Goal:** Push to GitHub → Jenkins builds in-cluster → image lands in registry → ArgoCD deploys. No Docker on the Mac.

**Docker Registry:**

1. Deploy an in-cluster registry (`registry:2`) as a Deployment + Service + PVC in `cicd`
2. Expose via MetalLB LoadBalancer on port 5001
3. Once it has an IP, update `/etc/rancher/k3s/registries.yaml` on both VMs to trust it
4. Restart k3s/k3s-agent to pick up the change

**Jenkins:** 5. Install Jenkins via Helm into `cicd` 6. Expose via LoadBalancer (Tailscale-only access — no Cloudflare tunnel) 7. Configure Docker-in-Docker so Jenkins can build images 8. Install plugins: Git, Pipeline, Docker Pipeline, Credentials 9. Add GitHub credentials (clone app repos, push manifest updates to this infra repo) 10. Test pipeline: build a hello-world image, push to the registry

**ArgoCD:** 11. Install via manifests (`kubectl apply -n argocd -f ...`) 12. Patch `argocd-server` to `LoadBalancer` 13. Retrieve initial admin password 14. Create the first `Application` CR (bootstraps everything else this repo manages)

**Headlamp (dashboard):** 15. Install Headlamp (ServiceAccount + ClusterRoleBinding + token, same pattern as existing setup)

**Deliverables:**

- `platform/registry/registry.yaml`
- `platform/jenkins/values.yaml`
- `platform/argocd/install.sh`
- `platform/headlamp/headlamp.yaml`
- `scripts/06-configure-registry.sh`
- `argocd-apps/`

**Verify:**

- Registry: `curl http://<REGISTRY_IP>:5001/v2/_catalog`
- Jenkins: can run a build
- ArgoCD: UI accessible, shows synced app
- Headlamp: accessible via Tailscale

---

### Phase 3 — Remote & Public Access (Tailscale verification + Cloudflare)  **(DONE for hello-world)**

**Goal:** Confirm Tailscale access end-to-end, then expose the (future) portfolio site publicly via Cloudflare.

1. Confirm Tailscale access to: both Proxmox UIs, kubectl, Headlamp, Jenkins, ArgoCD — all from a non-LAN network (e.g. phone hotspot)
2. Add domain to Cloudflare (if not already) — **done**, domain registered via Cloudflare Registrar
3. Deploy `cloudflared` in-cluster, create a tunnel pointing at Traefik — **done**, see `platform/cloudflare/cloudflared.yaml` (namespace `cloudflare`)
4. Configure DNS: `<yourdomain>` → tunnel (currently routed to hello-world; will be re-pointed to the portfolio site once it's deployed in Phase 4)
5. Confirm everything _except_ the public hostname stays Tailscale-only (no public DNS records for ArgoCD/Jenkins/Grafana/etc.) — **confirmed**

**Status:** Cloudflare Tunnel is live and serving hello-world over HTTPS publicly. Account hardening done (2FA, Always Use HTTPS, SSL/TLS Full(strict), Bot Fight Mode). Remaining: re-point the Public Hostname to the real portfolio site in Phase 4, and do a full non-LAN (phone hotspot) pass confirming Tailscale access to Proxmox UIs/kubectl/Headlamp/Jenkins/ArgoCD.

**Deliverables:**

- `platform/cloudflare/cloudflared.yaml` — Deployment + tunnel config (token-based, via gitignored Secret `cloudflared-token`)
- `docs/remote-access.md` — Tailscale device list, Cloudflare tunnel routing table (still TODO if you want it written up separately from setup-log.md)

**Verify:**

- Cluster fully manageable from outside the LAN via Tailscale
- Cloudflare tunnel pod healthy, DNS resolves (even if backend isn't ready yet)

---

### Phase 4 — Portfolio Site (first production app)

**Goal:** Deploy the portfolio site through the full pipeline — the template for every future app.

1. Portfolio site repo: add `Dockerfile` + `Jenkinsfile` (following `docs/adding-new-apps.md`)
2. This repo: `manifests/portfolio/` — namespace, Deployment, Service, Ingress (Traefik)
3. `argocd-apps/portfolio.yaml` — Application CR, `automated: { prune: true, selfHeal: true }`
4. Apply once: `kubectl apply -f argocd-apps/portfolio.yaml`
5. Jenkins pipeline job for the portfolio repo
6. Push → verify full cycle: build → registry → manifest update → ArgoCD sync → pod running
7. Point Cloudflare tunnel's hostname rule at the `portfolio` Service
8. Verify `https://<yourdomain>` serves the site publicly

**Deliverables:**

- `manifests/portfolio/`
- `argocd-apps/portfolio.yaml`
- `docs/adding-new-apps.md` (finalized using portfolio as the worked example)

**Verify:**

- `https://<yourdomain>` loads the portfolio site from the public internet
- A test commit flows through the entire pipeline automatically

---

### Phase 5 — Storage (MinIO)

**Goal:** S3-compatible data lake for the learning-scale data platform.

1. Install MinIO via Helm in `data-platform`, local-path PVC
2. Expose API + Console via MetalLB (Tailscale-only)
3. Create access key/secret, store as a Secret
4. Create buckets: `raw-data`, `processed-data`, `mlflow-artifacts`, `backups`

**Deliverables:**

- `platform/minio/values.yaml`
- `platform/minio/minio-secret.yaml.example`
- `platform/minio/buckets-job.yaml`

**Verify:** MinIO console reachable, `mc ls` works from Mac via Tailscale

---

### Phase 6 — Data Ingestion (Kafka)

**Goal:** Kafka running in KRaft mode — proof of concept for streaming ingestion.

1. Install Kafka via Bitnami Helm chart in `data-platform`, KRaft mode, 1 broker
2. Modest resources (1–1.5GB) — plenty given the workload profile
3. Set explicit retention (`retention.bytes`, `retention.ms`) on every topic out of habit, even though volume is tiny
4. Create a test topic, produce/consume a test message

**Deliverables:**

- `platform/kafka/values.yaml`
- `scripts/test-kafka.sh`

---

### Phase 7 — Data Processing (Spark + Delta Lake)

**Goal:** Run a small Spark job (hundreds of rows) that reads/writes Delta tables on MinIO — to learn the mechanics.

1. Install Spark Operator via Helm in `data-platform`
2. Custom Spark image (built via Jenkins): Delta Lake + Hadoop AWS jars for MinIO
3. `SparkApplication` CR: reads a small CSV from MinIO `raw-data`, transforms, writes Delta to `processed-data`
4. 1 executor, 1GB RAM — this is plenty at this scale

**Deliverables:**

- `platform/spark/values.yaml`, `platform/spark/spark-rbac.yaml`
- `images/spark/Dockerfile`
- `jobs/sample-etl/`

---

### Phase 8 — Notebooks (JupyterHub)

**Goal:** Query the Delta table from a notebook.

1. Install JupyterHub via Zero to JupyterHub Helm chart
2. Custom notebook image (built via Jenkins): PySpark + Delta + boto3/s3fs
3. Sample notebook: read Delta table from MinIO, basic pandas/matplotlib

**Deliverables:**

- `platform/jupyterhub/values.yaml`
- `images/notebook/Dockerfile`
- `notebooks/sample-query.ipynb`

---

### Phase 9 — ML Tracking (MLflow)

**Goal:** Log a sample experiment with metrics + artifact in MinIO.

1. PostgreSQL via Bitnami Helm chart (small, local-path PVC)
2. MLflow tracking server — backend store Postgres, artifact store MinIO `mlflow-artifacts`
3. Sample training script (sklearn on a tiny dataset) logging to MLflow
4. `pg_dump` CronJob → MinIO `backups`

**Deliverables:**

- `platform/postgres/values.yaml`, `platform/postgres/backup-cronjob.yaml`
- `platform/mlflow/mlflow.yaml`, `platform/mlflow/mlflow-secret.yaml.example`
- `jobs/sample-ml/`

---

### Phase 10 — Observability (optional, lower priority)

**Goal:** Prometheus + Grafana + Loki, same patterns as the existing Vagrant setup.

1. Loki + Promtail (`isDefault: false` patch for the Grafana datasource conflict)
2. kube-prometheus-stack — 24h retention, disable kubeControllerManager/kubeScheduler/kubeEtcd/kubeProxy scrape targets (k3s-specific fix)
3. Grafana — Tailscale-only

**Deliverables:**

- `platform/monitoring/values.yaml`, `platform/monitoring/loki-values.yaml`
- `scripts/deploy-monitoring.sh`

---

## Repo Structure

```
k3s-data-platform/
├── PLAN.md
├── README.md
├── .gitignore
│
├── scripts/
│   ├── 00-proxmox-post-install.sh
│   ├── 01-create-vms.sh
│   ├── 02-prepare-vm.sh
│   ├── 03-install-k3s-server.sh
│   ├── 04-install-k3s-agent.sh
│   ├── 05-configure-mac.sh
│   ├── 06-configure-registry.sh
│   ├── deploy-monitoring.sh
│   ├── test-minio.sh
│   └── test-kafka.sh
│
├── platform/
│   ├── namespaces.yaml
│   ├── metallb/
│   ├── registry/
│   ├── jenkins/
│   ├── argocd/
│   ├── headlamp/
│   ├── cloudflare/
│   ├── minio/
│   ├── kafka/
│   ├── spark/
│   ├── jupyterhub/
│   ├── mlflow/
│   ├── postgres/
│   └── monitoring/
│
├── argocd-apps/
│   ├── portfolio.yaml
│   └── ...
│
├── manifests/
│   └── portfolio/
│
├── images/
│   ├── spark/Dockerfile
│   └── notebook/Dockerfile
│
├── jobs/
│   ├── sample-etl/
│   └── sample-ml/
│
├── notebooks/
│   └── sample-query.ipynb
│
└── docs/
    ├── proxmox-setup.md
    ├── remote-access.md
    └── adding-new-apps.md
```

---

## Key Decisions

| Decision                           | Choice                              | Rationale                                                                                                                      |
| ---------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Proxmox as hypervisor              | Yes                                 | Snapshot/rollback before risky changes protects the portfolio site; matches enterprise-like goal; cheap at this workload scale |
| k3s inside VMs, not bare metal     | Yes                                 | Standard enterprise pattern (cloud k8s nodes are VMs too); enables easy node recreation                                        |
| No Longhorn                        | local-path everywhere               | Simpler; no replication overhead; can add later                                                                                |
| No Velero                          | pg_dump + MinIO + Proxmox snapshots | Proxmox snapshots cover VM-level recovery; app data is re-runnable or dumped                                                   |
| Tailscale everywhere               | Proxmox hosts + VMs + Mac           | Location-independent management; solves "move the laptop" and "move the cluster"                                               |
| Cloudflare for portfolio only      | Tunnel + DNS                        | Public access for the one workload that needs it; everything else stays private                                                |
| Build images in-cluster            | Jenkins + DinD                      | No Docker needed on Mac                                                                                                        |
| Data platform at learning scale    | Small resource allocations          | Honest about actual workload — avoids over-provisioning                                                                        |
| Dev/prod via namespaces + branches | Lightweight                         | Full duplication isn't justified for a personal portfolio; promotion flow still real                                           |

---

## Maintenance Checklist

| Task                    | Frequency            | Action                                                           |
| ----------------------- | -------------------- | ---------------------------------------------------------------- |
| Proxmox VM snapshot     | Before risky changes | Snapshot via Proxmox UI before Helm upgrades, k3s upgrades, etc. |
| Prune container images  | Monthly              | `k3s crictl rmi --prune` on each VM                              |
| PostgreSQL backup       | Daily (CronJob)      | `pg_dump` → MinIO `backups`                                      |
| Registry cleanup        | Monthly              | Delete old tags, garbage-collect                                 |
| Monitor root filesystem | Monthly              | `df -h /` on each VM                                             |
| Tailscale ACL review    | Occasionally         | Confirm only intended devices/services are reachable             |

---

## Phase Dependency Diagram

```
Phase 0: Proxmox Foundation
    └── Phase 1: k3s VMs + Cluster Bootstrap
         └── Phase 2: CI/CD (Jenkins + Registry + ArgoCD)
              ├── Phase 3: Remote & Public Access (Tailscale + Cloudflare)
              │    └── Phase 4: Portfolio Site  ← primary goal achieved here
              └── Phase 5: Storage (MinIO)
                   ├── Phase 6: Kafka
                   ├── Phase 7: Spark + Delta Lake (needs MinIO)
                   │    └── Phase 8: JupyterHub (needs Spark + MinIO)
                   └── Phase 9: MLflow (needs MinIO + Postgres)

Phase 10: Observability — optional, any time after Phase 2
```
