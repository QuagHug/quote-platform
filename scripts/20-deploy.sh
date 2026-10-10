#!/usr/bin/env sh
# Part 2: install Argo CD, register the quote-api Application (our Helm chart,
# synced from GitHub), wait until it is Synced/Healthy and answering via Ingress.
. "$(dirname "$0")/_lib.sh"

ARGOCD_CHART_VERSION=10.10.2   # Argo CD v3.5.4

log "Installing Argo CD (argo-cd chart $ARGOCD_CHART_VERSION)"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace -f argocd/values.yaml --wait --timeout 10m >/dev/null
kubectl -n argocd get deploy,statefulset

log "Registering the Application: charts/quote-api from GitHub main"
kubectl apply -f argocd/application.yaml

log "Waiting for Argo CD to sync and the app to become Healthy"
i=0
while :; do
  sync=$(kubectl -n argocd get application quote-api -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  health=$(kubectl -n argocd get application quote-api -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  echo "  sync=${sync:-?} health=${health:-?}"
  [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && break
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    kubectl -n argocd get application quote-api -o jsonpath='{.status.conditions}'; echo
    echo "Argo CD did not reach Synced/Healthy in 10 minutes" >&2; exit 1
  fi
  sleep 10
done
kubectl -n quote-api rollout status deployment/quote-api --timeout=180s

log "Placement (spot preferred, at least one on on-demand)"
kubectl -n quote-api get pods -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName' --no-headers |
  while read -r pod node; do
    printf '  %-32s %-20s %s\n' "$pod" "$node" "$(kubectl get node "$node" -o jsonpath='{.metadata.labels.acme\.io/capacity}')"
  done

log "Calling the API through the Ingress"
i=0
until curl -fsS "http://host.docker.internal:${INGRESS_PORT}/api/quote"; do
  i=$((i + 1)); [ "$i" -le 30 ] || { echo "Ingress did not answer" >&2; exit 1; }
  sleep 2
done
echo
echo "  From your machine: curl http://localhost:${INGRESS_PORT}/api/quote"

log "Argo CD UI on http://localhost:${ARGOCD_PORT} (anonymous, read-only)"
pkill -f 'port-forward.*argocd-server' 2>/dev/null || true
nohup kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8081:80 >/tmp/pf-argocd.log 2>&1 &
