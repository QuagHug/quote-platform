# Load test (Part 6)

`./scripts/60-loadtest.sh`: Prometheus + Grafana, then k6 on `/api/quote` through the Ingress. Evidence: [`docs/evidence/`](docs/evidence).

Machine: Apple M1, Docker VM with 8 vCPU / 10 GB shared by all 5 nodes.

## Baseline and capacity

Each request costs ~101 ms CPU on a fast core, 150-320 ms on the M1's efficiency cores. Baseline at 2 req/s: p50 122 ms, p95 348 ms.

Step test ([`steps.js`](loadtest/k6/steps.js), 90 s per step):

| req/s | p50 | p95 |
|---|---|---|
| 10 | 107 ms | 273 ms |
| 20 | 146 ms | 1.4 s |
| 25 | 193 ms | 3.1 s |
| 30 | 653 ms | 12.7 s |

**Max sustainable: ~15 req/s.** The test runs at 10 for headroom.

## Bottleneck

Host CPU. At 20 req/s, 10 pods used ~0.5 core each and the nodes ~7.6 of 8 vCPU; Traefik used 50m; throttling stayed under 5%. Every k3d node claims all 8 CPUs, so the scheduler sees 40 and keeps adding pods with no real CPU behind them.

## Result at 10 req/s

- HPA 3 → 10. At 10 replicas: 6 spot / 4 on-demand. On-demand never 0.
- Hold phase: p95 255 ms, p99 791 ms, 0 of 4,199 failed.
- Screenshot: [`grafana-during-load.png`](docs/evidence/grafana-during-load.png).

## Thresholds and alert

- k6: errors < 1%; hold-phase p95 < 1 s and p99 < 2.5 s (~3× baseline p95). The ramp isn't latency-gated; it measures HPA reaction.
- Alert `QuoteApiLatencyHigh`: p95 > 1 s for 3 min while traffic > 0.5 req/s. Short spikes pass; sustained saturation fires. It fired in the 20 req/s run ([`run-20rps/`](docs/evidence/run-20rps)), which failed k6 at p95 3.5 s; that script version wrongly printed PASS (fixed).

## Scale first in production

Node CPU, not replicas: set the CPU request to the real cost (~1 core per 10 req/s) so Karpenter adds nodes, then lower the HPA target to ~50%.
