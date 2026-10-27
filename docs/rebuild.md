# Rebuild the Cluster from Zero

This guide rebuilds the whole cluster from this repo plus one archive folder.
It does **not** restore data. Postgres tables, MinIO files, MongoDB, and the
images in the local registry start empty.

`docs/setup-log.md` explains *why* each step exists. This file is the short,
current version: the right IPs, 3 nodes, and pinned versions.

## Before you start

You need:

- **This repo** on the Mac.
- **An archive folder**, made by `scripts/archive.sh` while the old cluster
  was running. It lives in `~/homelab-archive/<date>/` and holds the secrets,
  Helm values, versions, and node config.
- **Tailscale** on the Mac.

If `secrets.json` was encrypted, decrypt it first:

```bash
gpg -d ~/homelab-archive/<date>/secrets.json.gpg > ~/homelab-archive/<date>/secrets.json
```

## Versions captured on 2026-10-25

| Part | Version |
|---|---|
| k3s | v1.36.2+k3s1 |
| ArgoCD | v3.4.3 |
| MetalLB | v0.14.8 |
| Helm: jenkins | jenkins-5.9.25 |
| Helm: minio | minio-5.4.0 |
| Helm: headlamp | headlamp-0.42.0 |

`versions.txt` in the archive has every image tag.

## Addresses

| Host | LAN IP | Runs |
|---|---|---|
| pve1 | 192.168.4.210 | VM `k3s-server` (192.168.4.220) |
| pve2 | 192.168.4.211 | VM `k3s-agent` (192.168.4.221) |
| pve3 | 192.168.4.212 | VM `k3s-agent-2` (192.168.4.222) |

Gateway: `192.168.4.1`. MetalLB pool: `192.168.4.240–250`. Registry: `192.168.4.245:5001`.

---

## 1. Proxmox and VMs

Follow `setup-log.md` Phase 0 and Phase 1 to install Proxmox and create one
Ubuntu 22.04 VM on each host. Then, **on each Proxmox host**:

```bash
qm set <VMID> --onboot 1
```

Without this, the VM stays off after a power cut.

**On each VM**, before you install k3s:

```bash
# Stop cloud-init from replacing the static IP on every reboot
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# Kubernetes needs swap off
sudo swapoff -a && sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Trust the plain-HTTP in-cluster registry
sudo mkdir -p /etc/rancher/k3s
```

Then copy `platform/k3s/registries.yaml` to `/etc/rancher/k3s/registries.yaml`
on **every** VM. Copy `platform/k3s/server-config.yaml` to
`/etc/rancher/k3s/config.yaml` on **k3s-server only**.

Install Tailscale on each VM (`setup-log.md` Phase 1, Step 7).

## 2. k3s

Set `node-ip` in **one place only**: the install flag below. If it is also in
`config.yaml`, k3s joins the two values as `"IP,IP"` and kubelet crash-loops
with no clear error.

**On k3s-server:**

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.2+k3s1 sh -s - server \
  --write-kubeconfig-mode 644 \
  --disable servicelb \
  --node-ip=192.168.4.220 \
  --tls-san=192.168.4.220 \
  --tls-san=k3s-server

sudo cat /var/lib/rancher/k3s/server/node-token   # copy this
```

**On k3s-agent** (then the same on **k3s-agent-2** with `.222`):

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.2+k3s1 \
  K3S_URL=https://192.168.4.220:6443 K3S_TOKEN=<TOKEN> sh -s - agent \
  --node-ip=192.168.4.221
```

**On the Mac**, copy the kubeconfig and point it at the Tailscale IP:

```bash
scp aman@100.112.249.53:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i '' 's/127.0.0.1/100.112.249.53/' ~/.kube/config
kubectl get nodes        # all 3 Ready
```

The Tailscale IP may change on a fresh Tailscale install. If it does,
update the IP above, `platform/k3s/server-config.yaml`, and every
`100.112.249.53` in the docs.

## 3. Cluster add-ons

**On the Mac**, from the repo root:

```bash
# MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=ready pod --all --timeout=180s
kubectl apply -f platform/metallb/metallb-config.yaml

# Namespaces
kubectl apply -f platform/namespaces.yaml
for ns in argocd cloudflare commitments c4-diagram tracker kubenex proxmox-visualizer; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
done

# Secrets (all 9 app secrets, from the archive)
kubectl apply -f ~/homelab-archive/<date>/secrets.json

# Registry
kubectl apply -f platform/registry/registry.yaml

# ArgoCD. --server-side is required: the ApplicationSet CRD is too large for
# a normal apply, and without it the applicationset-controller crash-loops.
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/install.yaml
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"nodePort":30789}]}}'

# Helm releases
helm repo add jenkins https://charts.jenkins.io
helm repo add minio https://charts.min.io/
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update
helm install jenkins jenkins/jenkins --version 5.9.25 -n cicd -f platform/jenkins/values.yaml
helm install minio minio/minio --version 5.4.0 -n data-platform -f platform/minio/values.yaml
helm install headlamp headlamp/headlamp --version 0.42.0 -n kube-system
kubectl patch svc headlamp -n kube-system \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"nodePort":32526}]}}'
kubectl apply -f platform/headlamp/headlamp-admin.yaml

# Cloudflare tunnel (the token secret came from secrets.json)
kubectl apply -f platform/cloudflare/cloudflared.yaml
```

## 4. Data platform

Apply in this order. Each one depends on the one before it.

```bash
kubectl apply -f platform/postgres/postgres.yaml
kubectl -n data-platform rollout status deploy/postgres --timeout=5m

kubectl apply -f platform/spark/spark.yaml
kubectl apply -f platform/spark-thrift/spark-thrift.yaml
kubectl apply -f platform/airflow/airflow.yaml
kubectl apply -f platform/jupyterhub/jupyterhub.yaml

# SQL gateway (code lives in the kubenex repo)
~/dev/kubenex/deploy/sql-gateway/deploy.sh
```

MinIO was installed in step 3. Its chart creates the 4 buckets on first boot.

## 5. Apps (GitOps)

```bash
kubectl apply -f argocd-apps/
```

ArgoCD syncs each app from git. **The app pods stay in `ImagePullBackOff`
until their images are rebuilt**, because the new registry is empty. Rebuild
each image (`kubenex`, `commitments`, `c4-diagram`, `proxmox-visualizer`,
`tracker`, `stream-kubenex`) with its Jenkins pipeline, or build and push it
from the Mac. The tags must match `manifests/<app>/deployment.yaml`.

`stream-kubenex` also needs its API token Secret before its pod can start
(see `manifests/stream-kubenex/secret.yaml.example`):

```bash
kubectl create secret generic stream-api -n stream --from-literal=token="$(openssl rand -hex 32)"
```

`stream-kubenex` keeps its videos on an external SSD attached to pve3 and passed
through to k3s-agent-2 (`scsi1`, by-id path), mounted at `/mnt/stream-media` via
fstab with `nofail`. The pod only starts if `/mnt/stream-media/stream` exists,
which it does only when the drive is mounted (`manifests/stream-kubenex/media-volume.yaml`).

Jenkins starts fresh: re-add the GitHub credentials and pipeline jobs
(`setup-log.md` Phase 2).

## 6. Check

```bash
kubectl get nodes
kubectl get pods -A | grep -v -E "Running|Completed"
kubectl get applications -n argocd
```

New passwords for Jenkins and ArgoCD (other passwords came back from `secrets.json`):

```bash
kubectl get secret jenkins -n cicd -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl create token headlamp-admin -n kube-system --duration=8760h
```

Update `HOMELAB-ACCESS.md` with the new values.

## Tear down or restore only the project apps

The project apps (kubenex, tracker, proxmox-visualizer, c4-diagram,
commitments, data-platform, portfolio) can be removed and restored without
touching the infrastructure. The list lives in `scripts/apps.conf`.

```bash
scripts/apps-save.sh    # save them exactly as they run now (no data)
scripts/apps-down.sh    # save, then delete them; asks you to type "yes"
scripts/apps-up.sh      # bring them back from the latest save
```

Saves go to `~/homelab-archive/apps-<timestamp>/`. They come straight from the
live cluster, so they also capture things that were never committed to git.
Add `DRY_RUN=1` in front of `apps-down.sh` or `apps-up.sh` to see what
would happen without changing anything.

## Keep the archive current

Run this after any change to secrets, Helm values, or node config:

```bash
scripts/archive.sh
```
