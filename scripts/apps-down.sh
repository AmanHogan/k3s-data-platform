#!/usr/bin/env bash
# Delete every project app (see APP_NAMESPACES in apps.conf).
#
# Runs apps-save.sh FIRST, so you can always bring everything back with
# apps-up.sh. Then: removes the ArgoCD Applications (so ArgoCD does not
# recreate the apps), uninstalls their Helm releases, and deletes the
# namespaces. All data in those namespaces is deleted permanently.
#
# Infrastructure is not touched: ArgoCD, Jenkins, registry, Cloudflare,
# MetalLB, Headlamp, k3s.
#
# Usage:  scripts/apps-down.sh            asks you to type "yes"
#         DRY_RUN=1 scripts/apps-down.sh  only prints what it would delete
set -euo pipefail
cd "$(dirname "$0")"
source ./apps.conf

run() { if [ "${DRY_RUN:-0}" = 1 ]; then echo "  [dry run] $*"; else "$@"; fi; }

existing=()
for ns in "${APP_NAMESPACES[@]}"; do
  kubectl get namespace "$ns" >/dev/null 2>&1 && existing+=("$ns")
done
if [ ${#existing[@]} -eq 0 ]; then
  echo "None of the app namespaces exist. Nothing to delete."; exit 0
fi

echo "This deletes these namespaces and ALL data in them:"
printf '  %s\n' "${existing[@]}"
if [ "${DRY_RUN:-0}" != 1 ]; then
  read -r -p "Type yes to continue: " answer
  [ "$answer" = "yes" ] || { echo "Cancelled."; exit 1; }
fi

echo "1/4 Saving first..."
if [ "${DRY_RUN:-0}" = 1 ]; then echo "  [dry run] ./apps-save.sh"; else ./apps-save.sh; fi

echo "2/4 Removing ArgoCD Applications..."
for app in $(kubectl get applications.argoproj.io -n argocd -o json | jq -r --argjson ns "$(printf '%s\n' "${existing[@]}" | jq -R . | jq -s .)" \
    '.items[] | select(.spec.destination.namespace as $d | $ns | index($d)) | .metadata.name'); do
  run kubectl delete application.argoproj.io "$app" -n argocd
done

echo "3/4 Uninstalling Helm releases..."
for ns in "${existing[@]}"; do
  for rel in $(helm list -n "$ns" -q); do run helm uninstall "$rel" -n "$ns"; done
done

echo "4/4 Deleting namespaces (can take a minute)..."
for ns in "${existing[@]}"; do run kubectl delete namespace "$ns" --wait=false; done
if [ "${DRY_RUN:-0}" != 1 ]; then
  for ns in "${existing[@]}"; do kubectl wait --for=delete namespace/"$ns" --timeout=300s 2>/dev/null || true; done
fi

echo "Done. To bring everything back:  scripts/apps-up.sh"
