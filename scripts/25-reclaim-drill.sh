#!/usr/bin/env sh
# Spot reclaim drill: drain one spot node while a curl loop hits the Ingress,
# show the pods rescheduling, then uncordon. Fails if more than 1% of
# requests fail or the on-demand replica is lost.
. "$(dirname "$0")/_lib.sh"

NS=quote-api
URL="http://host.docker.internal:${INGRESS_PORT}/api/quote"
TMP=$(mktemp -d)

where() {
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=quote-api \
    -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready' --no-headers |
  while read -r pod node ready; do
    printf '  %-32s %-20s %-10s ready=%s\n' "$pod" "$node" "$(kubectl get node "$node" -o jsonpath='{.metadata.labels.acme\.io/capacity}')" "$ready"
  done
}

kubectl -n "$NS" rollout status deployment/quote-api --timeout=120s >/dev/null

# Drain the spot node that currently runs a quote-api pod.
SPOT=""
for n in $(kubectl get nodes -l acme.io/capacity=spot -o jsonpath='{.items[*].metadata.name}'); do
  if kubectl -n "$NS" get pods -l app.kubernetes.io/name=quote-api --field-selector "spec.nodeName=$n" --no-headers 2>/dev/null | grep -q .; then
    SPOT=$n; break
  fi
done
[ -n "$SPOT" ] || { echo "no spot node is running quote-api" >&2; exit 1; }

cleanup() {
  [ -n "${LOOP_PID:-}" ] && kill "$LOOP_PID" 2>/dev/null || true
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
  kubectl uncordon "$SPOT" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

log "Before: placement"
where

log "Starting curl loop against $URL (5 req/s)"
( while :; do
    curl -s -o /dev/null -m 3 -w '%{http_code}\n' "$URL" >> "$TMP/codes" || echo "000" >> "$TMP/codes"
    sleep 0.2
  done ) &
LOOP_PID=$!
sleep 3

log "Simulating a spot reclaim: draining $SPOT"
kubectl -n "$NS" get pods -l app.kubernetes.io/name=quote-api -o wide --watch-only \
  | awk '{print "  [watch] " $1, $3, $7}' &
WATCH_PID=$!
kubectl drain "$SPOT" --ignore-daemonsets --delete-emptydir-data --timeout=180s
kubectl -n "$NS" rollout status deployment/quote-api --timeout=180s
sleep 5
kill "$WATCH_PID" 2>/dev/null || true

log "During reclaim: placement with $SPOT cordoned"
where

log "Uncordoning $SPOT (pods stay where they are; the scheduler does not rebalance)"
kubectl uncordon "$SPOT"
sleep 2
kill "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""

TOTAL=$(wc -l < "$TMP/codes" | tr -d ' ')
OK=$(grep -c '^200$' "$TMP/codes" || true)
FAILED=$((TOTAL - OK))
log "Result: $OK/$TOTAL requests answered 200 during the drill ($FAILED failed)"
grep -v '^200$' "$TMP/codes" | sort | uniq -c | sed 's/^/  non-200: /' || true

OD=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=quote-api -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | while read -r n; do kubectl get node "$n" -o jsonpath='{.metadata.labels.acme\.io/capacity}{"\n"}'; done | grep -c '^on-demand$' || true)
echo "  replicas on on-demand: $OD"

[ "$OD" -ge 1 ] || { echo "FAIL: lost the on-demand replica" >&2; exit 1; }
[ $((FAILED * 100)) -le "$TOTAL" ] || { echo "FAIL: more than 1% of requests failed" >&2; exit 1; }
log "PASS: service kept answering through the reclaim"
