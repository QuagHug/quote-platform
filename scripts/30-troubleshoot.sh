#!/usr/bin/env sh
# Part 3: apply the fixed manifests and run the provided verifier.
# The story of each fix is in TROUBLESHOOTING.md.
. "$(dirname "$0")/_lib.sh"

log "Applying troubleshoot/fixed-app.yaml"
kubectl apply -f troubleshoot/fixed-app.yaml
kubectl -n troubleshoot rollout status deployment/web --timeout=180s
kubectl -n troubleshoot rollout status deployment/ai-inference --timeout=180s

log "Running troubleshoot/verify.sh"
# verify.sh gives the smoke Job 60s including the curl image pull, so a cold
# first run can time out on a slow link. One retry, with the image cached.
if ! sh troubleshoot/verify.sh; then
  log "verify.sh failed once (often the first image pull); retrying"
  sh troubleshoot/verify.sh
fi
