#!/usr/bin/env bash
# Archive everything needed to rebuild the cluster that git does NOT hold.
#
# Git already holds the manifests (platform/, manifests/, argocd-apps/).
# This script captures the rest:
#   secrets.json     every app Secret, cleaned so `kubectl apply` restores it
#   helm-values/     the exact values each Helm release was installed with
#   versions.txt     k3s, chart and image versions running right now
#   nodes/<host>/    k3s flags and config files from each node
#   live-snapshot/   every non-Secret resource per namespace (reference only)
#
# It does NOT capture data (Postgres rows, MinIO objects, MongoDB, PVCs).
#
# Output goes OUTSIDE every git repo, because secrets.json holds real
# passwords. Default: ~/homelab-archive/<date>/  (override with ARCHIVE_DIR).
#
# Usage:  scripts/archive.sh
set -euo pipefail

STAMP=$(date +%Y-%m-%d)
OUT="${ARCHIVE_DIR:-$HOME/homelab-archive}/$STAMP"
NODES=("k3s-server:100.112.249.53" "k3s-agent:100.122.47.108" "k3s-agent-2:100.89.108.57")
# Namespaces that hold platform/app resources (system ones are rebuilt by installers)
APP_NS=(data-platform cicd cloudflare commitments c4-diagram tracker kubenex proxmox-visualizer portfolio)

umask 077
mkdir -p "$OUT"
if git -C "$OUT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Refusing to write secrets inside a git repo: $OUT" >&2
  exit 1
fi
mkdir -p "$OUT"/{helm-values,nodes,live-snapshot}
echo "Archiving to $OUT"

# --- Secrets ---------------------------------------------------------------
# Keep only Secrets created by hand (kubectl create secret). Skip anything an
# installer recreates: Helm-owned (restoring it blocks `helm install`),
# owner-referenced, service-account tokens, and the argocd/kube-system/metallb
# internals.
kubectl get secrets -A -o json | jq '
  {apiVersion: "v1", kind: "List", items: [
    .items[]
    | select(.type == "Opaque")
    | select(.metadata.namespace as $n | ["argocd","kube-system","metallb-system"] | index($n) | not)
    | select((.metadata.annotations // {}) | has("meta.helm.sh/release-name") | not)
    | select(.metadata.ownerReferences == null)
    | {apiVersion: "v1", kind: "Secret", type,
       metadata: {name: .metadata.name, namespace: .metadata.namespace}, data}
  ]}' > "$OUT/secrets.json"
echo "  secrets:  $(jq '.items | length' "$OUT/secrets.json") ($(jq -r '[.items[] | .metadata.namespace + "/" + .metadata.name] | join(", ")' "$OUT/secrets.json"))"

# --- Helm values -----------------------------------------------------------
helm list -A -o json | jq -r '.[] | "\(.name) \(.namespace) \(.chart)"' |
while read -r name ns chart; do
  case "$name" in traefik|traefik-crd) continue ;; esac   # bundled with k3s
  helm get values "$name" -n "$ns" -o yaml > "$OUT/helm-values/$name.yaml"
  echo "  helm:     $name ($chart)"
done

# --- Versions --------------------------------------------------------------
{
  echo "# Captured $STAMP"
  echo "## Nodes"
  kubectl get nodes -o custom-columns=NAME:.metadata.name,K3S:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage --no-headers
  echo; echo "## Helm releases"
  helm list -A --no-headers
  echo; echo "## Images"
  kubectl get deploy,sts,ds -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' | sort
} > "$OUT/versions.txt"
echo "  versions: versions.txt"

# --- Node config (read-only over SSH; no sudo needed) ----------------------
for entry in "${NODES[@]}"; do
  host=${entry%%:*}; ip=${entry##*:}
  mkdir -p "$OUT/nodes/$host"
  if ssh -o ConnectTimeout=5 -o BatchMode=yes "aman@$ip" true 2>/dev/null; then
    ssh -o BatchMode=yes "aman@$ip" '
      for f in /etc/systemd/system/k3s.service /etc/systemd/system/k3s-agent.service; do
        if [ -f "$f" ]; then sed -n "/^ExecStart=/,\$p" "$f"; fi
      done' > "$OUT/nodes/$host/k3s-execstart.txt"
    for f in config.yaml registries.yaml; do
      ssh -o BatchMode=yes "aman@$ip" "cat /etc/rancher/k3s/$f 2>/dev/null" > "$OUT/nodes/$host/$f" || true
      [ -s "$OUT/nodes/$host/$f" ] || rm -f "$OUT/nodes/$host/$f"
    done
    ssh -o BatchMode=yes "aman@$ip" "cat /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg 2>/dev/null" \
      > "$OUT/nodes/$host/99-disable-network-config.cfg" || true
    echo "  node:     $host"
  else
    echo "  node:     $host UNREACHABLE (skipped)" >&2
  fi
done

# --- Live snapshot (reference for drift, not for blind re-apply) -----------
for ns in "${APP_NS[@]}"; do
  kubectl get deploy,sts,ds,svc,cm,pvc,cronjob,ingress,sa,role,rolebinding \
    -n "$ns" -o yaml > "$OUT/live-snapshot/$ns.yaml" 2>/dev/null || true
done
kubectl get ipaddresspools.metallb.io,l2advertisements.metallb.io -A -o yaml \
  > "$OUT/live-snapshot/metallb.yaml" 2>/dev/null || true
kubectl get applications.argoproj.io -n argocd -o yaml \
  > "$OUT/live-snapshot/argocd-applications.yaml" 2>/dev/null || true
echo "  snapshot: live-snapshot/ (${#APP_NS[@]} namespaces + metallb + argocd apps)"

echo
echo "Done. secrets.json holds real passwords. To encrypt it:"
echo "  gpg -c \"$OUT/secrets.json\" && rm \"$OUT/secrets.json\""
