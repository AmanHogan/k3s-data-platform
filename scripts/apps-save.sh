#!/usr/bin/env bash
# Save the project apps EXACTLY as they run now, straight from the cluster.
#
# Does not depend on git: whatever is live gets captured, including things
# that were never committed (e.g. the portfolio MongoDB).
#
# Saves, per app namespace: Namespace, Secrets, ConfigMaps, ServiceAccounts,
# PVCs, Services, Deployments, StatefulSets, CronJobs, Roles, RoleBindings,
# Ingresses. Plus the ArgoCD Applications that deploy them and the Helm
# releases (MinIO) installed into them.
#
# Does NOT save data. PVCs come back empty.
#
# Output: ~/homelab-archive/apps-<timestamp>/  (outside git: it holds secrets)
#         ~/homelab-archive/apps-latest -> the newest save
#
# Usage:  scripts/apps-save.sh
set -euo pipefail
source "$(dirname "$0")/apps.conf"

STAMP=$(date +%Y-%m-%d-%H%M)
ROOT="${ARCHIVE_DIR:-$HOME/homelab-archive}"
OUT="$ROOT/apps-$STAMP"

umask 077
mkdir -p "$OUT/namespaces" "$OUT/helm"
if git -C "$OUT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Refusing to write secrets inside a git repo: $OUT" >&2; exit 1
fi

# Strip everything the API server generates, so the objects apply cleanly to
# a fresh namespace. Service clusterIPs and PVC volume bindings must go: the
# new cluster assigns its own.
CLEAN='del(
  .status, .metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
  .metadata.managedFields, .metadata.generation, .metadata.selfLink,
  .metadata.ownerReferences,
  .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
  .metadata.annotations["deployment.kubernetes.io/revision"],
  .metadata.annotations["pv.kubernetes.io/bind-completed"],
  .metadata.annotations["pv.kubernetes.io/bound-by-controller"],
  .metadata.annotations["volume.beta.kubernetes.io/storage-provisioner"],
  .metadata.annotations["volume.kubernetes.io/storage-provisioner"],
  .metadata.annotations["volume.kubernetes.io/selected-node"],
  .spec.clusterIP, .spec.clusterIPs, .spec.volumeName
)'

# Skip what something else recreates: Helm-owned objects (reinstalled from
# saved values), controller-owned objects, the per-namespace defaults, and
# service-account tokens.
KEEP='
  (.metadata.annotations // {} | has("meta.helm.sh/release-name") | not)
  and (.metadata.ownerReferences == null)
  and (.type // "" | test("service-account-token|helm.sh/release") | not)
  and (.metadata.name != "kube-root-ca.crt")
  and ((.kind != "ServiceAccount") or (.metadata.name != "default"))
'

echo "Saving to $OUT"
for ns in "${APP_NAMESPACES[@]}"; do
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "  $ns: does not exist, skipped"; continue
  fi
  # Order matters on restore: config before the workloads that use it.
  {
    kubectl get namespace "$ns" -o json | jq "$CLEAN"
    kubectl get secrets,configmaps,serviceaccounts,persistentvolumeclaims,roles,rolebindings,services,deployments,statefulsets,cronjobs,ingresses \
      -n "$ns" -o json | jq ".items[] | select($KEEP) | $CLEAN"
  } | jq -s '{apiVersion: "v1", kind: "List", items: .}' > "$OUT/namespaces/$ns.json"
  echo "  $ns: $(jq -r '[.items[].kind] | group_by(.) | map("\(length) \(.[0])") | join(", ")' "$OUT/namespaces/$ns.json")"
done

# ArgoCD Applications that deploy into these namespaces
kubectl get applications.argoproj.io -n argocd -o json | jq --argjson ns "$(printf '%s\n' "${APP_NAMESPACES[@]}" | jq -R . | jq -s .)" '
  {apiVersion: "v1", kind: "List", items: [
    .items[] | select(.spec.destination.namespace as $d | $ns | index($d))
    | del(.operation) | '"$CLEAN"'
  ]}' > "$OUT/argocd-apps.json"
echo "  argocd: $(jq -r '[.items[].metadata.name] | join(", ")' "$OUT/argocd-apps.json")"

# Helm releases installed into these namespaces
helm list -A -o json | jq -c '.[]' | while read -r rel; do
  name=$(jq -r .name <<<"$rel"); ns=$(jq -r .namespace <<<"$rel"); chart=$(jq -r .chart <<<"$rel")
  printf '%s\n' "${APP_NAMESPACES[@]}" | grep -qx "$ns" || continue
  helm get values "$name" -n "$ns" -o yaml > "$OUT/helm/$name.values.yaml"
  # chart is "<name>-<version>"; version is the part after the last dash
  printf 'name=%s\nnamespace=%s\nchart=%s\nversion=%s\n' \
    "$name" "$ns" "${chart%-*}" "${chart##*-}" > "$OUT/helm/$name.release"
  echo "  helm:   $name ($chart)"
done

# Cloudflare public hostnames. These live in the Cloudflare dashboard, not in
# the cluster, so record them from cloudflared's last config update. Restoring
# them is manual: Zero Trust -> Networks -> Tunnels -> Public Hostnames.
kubectl logs -n cloudflare deploy/cloudflared --tail=5000 2>/dev/null \
  | grep "Updated to new configuration" | tail -1 \
  | sed -E 's/.*config="(.*)" version=.*/\1/; s/\\"/"/g' \
  | jq '[.ingress[] | select(.hostname) | {hostname, service}]' \
  > "$OUT/cloudflare-routes.json" 2>/dev/null || echo "[]" > "$OUT/cloudflare-routes.json"
echo "  cloudflare: $(jq -r 'map(.hostname) | join(", ")' "$OUT/cloudflare-routes.json")"

ln -sfn "$OUT" "$ROOT/apps-latest"
echo "Done. Latest save: $ROOT/apps-latest"
