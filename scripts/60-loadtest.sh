#!/usr/bin/env sh
# Part 6: Prometheus + Grafana, a k6 ramp through the Ingress, and evidence that
# the HPA scales past 3 while the spot/on-demand placement holds.
# Evidence from your run lands in ./out/ (gitignored); the committed run is in docs/evidence/.
. "$(dirname "$0")/_lib.sh"

KPS_VERSION=92.3.0
OUT=out/loadtest
mkdir -p "$OUT"

log "Installing kube-prometheus-stack $KPS_VERSION (Prometheus, Grafana, kube-state-metrics)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm upgrade --install kps prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" \
  --namespace monitoring --create-namespace -f monitoring/kube-prometheus-stack.values.yaml --wait --timeout 10m >/dev/null
kubectl -n monitoring get pods

log "Asking Argo CD to re-render the chart now that the monitoring CRDs exist"
# The chart only renders its ServiceMonitor/PrometheusRule when the API exists.
kubectl -n argocd annotate application quote-api argocd.argoproj.io/refresh=hard --overwrite >/dev/null
i=0
until kubectl -n quote-api get servicemonitor quote-api >/dev/null 2>&1 && kubectl -n quote-api get prometheusrule quote-api >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -le 36 ] || { echo "ServiceMonitor/PrometheusRule never appeared" >&2; exit 1; }
  sleep 5
done
kubectl -n quote-api get servicemonitor,prometheusrule

log "Grafana on http://localhost:${GRAFANA_PORT} (dashboard: quote-api)"
pkill -f 'port-forward.*kps-grafana' 2>/dev/null || true
pkill -f 'port-forward.*kps-kube-prometheus-stack-prometheus' 2>/dev/null || true
nohup kubectl -n monitoring port-forward --address 0.0.0.0 svc/kps-grafana 3000:80 >/tmp/pf-grafana.log 2>&1 &
nohup kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 >/tmp/pf-prom.log 2>&1 &
sleep 3

log "Recording HPA and placement every 10s while k6 runs"
kubectl -n quote-api get hpa quote-api --watch > "$OUT/hpa-watch.txt" 2>&1 &
HPA_PID=$!
(
  while :; do
    printf '%s ' "$(date -u +%H:%M:%S)"
    kubectl -n quote-api get pods -l app.kubernetes.io/name=quote-api --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
      while read -r n; do kubectl get node "$n" -o jsonpath='{.metadata.labels.acme\.io/capacity}{"\n"}'; done |
      sort | uniq -c | awk '{printf "%s=%s ", $2, $1} END {print ""}'
    sleep 10
  done
) > "$OUT/placement.txt" 2>&1 &
PLACE_PID=$!
trap 'kill $HPA_PID $PLACE_PID 2>/dev/null || true' EXIT

log "Running k6 against http://host.docker.internal:${INGRESS_PORT}/api/quote (about 10 minutes)"
set +e
k6 run --quiet --summary-export "$OUT/k6-summary.json" \
  -e BASE_URL="http://host.docker.internal:${INGRESS_PORT}" -e PEAK_RPS="${PEAK_RPS:-20}" \
  loadtest/k6/quote.js 2>&1 | tee "$OUT/k6-output.txt"
K6_RC=$?
set -e
sleep 20
kill "$HPA_PID" "$PLACE_PID" 2>/dev/null || true

log "HPA during the run (replicas column)"
cat "$OUT/hpa-watch.txt"
log "Ready replicas per nodepool, sampled every 10s"
cat "$OUT/placement.txt"

MAX=$(awk 'NR>1 {print $6}' "$OUT/hpa-watch.txt" | sort -n | tail -1)
NO_OD=$(grep -c -v 'on-demand=' "$OUT/placement.txt" || true)
log "Firing or pending alerts in Prometheus"
curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname | startswith("QuoteApi")) | "\(.labels.alertname) \(.state) since \(.activeAt)"' || true

echo "  max replicas observed: ${MAX:-?}   samples without an on-demand replica: $NO_OD   k6 exit: $K6_RC"
[ "${MAX:-0}" -gt 3 ] || { echo "FAIL: HPA never scaled past 3" >&2; exit 1; }
[ "$NO_OD" -eq 0 ] || { echo "FAIL: on-demand replica missing in $NO_OD samples" >&2; exit 1; }
[ "$K6_RC" -eq 0 ] || { echo "FAIL: k6 thresholds failed (see $OUT/k6-output.txt)" >&2; exit 1; }
log "PASS: scaled to $MAX replicas, on-demand floor held, k6 thresholds met"
