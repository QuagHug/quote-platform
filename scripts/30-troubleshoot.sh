#!/usr/bin/env sh
. "$(dirname "$0")/_lib.sh"

log "Applying troubleshoot/fixed-app.yaml"
kubectl apply -f troubleshoot/fixed-app.yaml
kubectl -n troubleshoot rollout status deployment/web --timeout=180s
kubectl -n troubleshoot rollout status deployment/ai-inference --timeout=180s

log "Running troubleshoot/verify.sh"
if ! sh troubleshoot/verify.sh; then
  log "verify.sh failed once (often the first image pull); retrying"
  sh troubleshoot/verify.sh
fi
