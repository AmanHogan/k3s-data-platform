#!/usr/bin/env bash
# Recreate every project app from a save made by apps-save.sh.
#
# Restores the namespaces, secrets, config, volumes (empty), services and
# workloads exactly as saved; reinstalls the Helm releases with their saved
# values; then re-adds the ArgoCD Applications.
#
# Usage:  scripts/apps-up.sh                 uses ~/homelab-archive/apps-latest
#         scripts/apps-up.sh <save-folder>   uses a specific save
#         DRY_RUN=1 scripts/apps-up.sh       server-side dry run, changes nothing
set -euo pipefail
source "$(dirname "$0")/apps.conf"

SAVE="${1:-${ARCHIVE_DIR:-$HOME/homelab-archive}/apps-latest}"
[ -d "$SAVE/namespaces" ] || { echo "No save found at $SAVE. Run scripts/apps-save.sh first." >&2; exit 1; }
SAVE=$(cd "$SAVE" && pwd -P)
DRY=(); [ "${DRY_RUN:-0}" = 1 ] && DRY=(--dry-run=server)

# kubectl apply on objects that already exist warns about a missing
# last-applied annotation. Harmless; hide it so real errors stand out.
apply() { kubectl apply "${DRY[@]}" "$@" 2> >(grep -v "last-applied-configuration" >&2) >/dev/null; }

echo "Restoring from $SAVE"

echo "1/3 Namespaces and resources..."
for f in "$SAVE"/namespaces/*.json; do
  ns=$(basename "$f" .json)
  # Namespace first, on its own: everything else in the file lives inside it.
  jq '.items[] | select(.kind == "Namespace")' "$f" | apply -f -
  if [ "${DRY_RUN:-0}" = 1 ] && ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "  $ns: namespace missing, dry run cannot check its contents"; continue
  fi
  jq '.items |= map(select(.kind != "Namespace"))' "$f" | apply -f -
  echo "  $ns: $(jq '.items | length' "$f") objects"
done

echo "2/3 Helm releases..."
for r in "$SAVE"/helm/*.release; do
  [ -e "$r" ] || continue
  # shellcheck disable=SC1090
  source "$r"   # sets name, namespace, chart, version
  url=$(helm_repo_url "$chart")
  helm repo add "$chart" "$url" >/dev/null 2>&1 || true
  helm repo update "$chart" >/dev/null
  if [ "${DRY_RUN:-0}" = 1 ]; then
    helm template "$name" "$chart/$chart" --version "$version" -n "$namespace" \
      -f "$SAVE/helm/$name.values.yaml" >/dev/null && echo "  $name: chart $chart $version renders OK (dry run)"
  else
    helm upgrade --install "$name" "$chart/$chart" --version "$version" -n "$namespace" \
      -f "$SAVE/helm/$name.values.yaml" --wait --timeout 10m >/dev/null
    echo "  $name: $chart $version installed"
  fi
done

echo "3/3 ArgoCD Applications..."
apply -f "$SAVE/argocd-apps.json"
echo "  $(jq -r '[.items[].metadata.name] | join(", ")' "$SAVE/argocd-apps.json")"

echo "Done. Pods take a few minutes to start. Watch them with:"
echo "  kubectl get pods -A | grep -v -E 'Running|Completed'"
