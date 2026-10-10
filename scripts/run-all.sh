#!/usr/bin/env sh
. "$(dirname "$0")/_lib.sh"

for s in 10-cluster-info 20-deploy 25-reclaim-drill 30-troubleshoot 50-validate-tf 60-loadtest; do
  log "scripts/$s.sh"
  sh "scripts/$s.sh"
done
log "All done. Grafana: http://localhost:${GRAFANA_PORT:-3000}  ArgoCD: http://localhost:${ARGOCD_PORT:-8081}"
