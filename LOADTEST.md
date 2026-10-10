# Load test (Part 6)

`./scripts/60-loadtest.sh` installs Prometheus + Grafana and runs k6 against `/api/quote` through the Ingress (k3d load balancer, then Traefik). Evidence: [`docs/evidence/`](docs/evidence).

Machine: Apple M1, Docker VM with 8 vCPUs and 10 GB, shared by all 5 k3d nodes.

## Baseline

A steady 2 req/s (`loadtest/k6/baseline.js`) gives median 122 ms and p95 348 ms. Each request costs 101 ms of CPU on a fast core and 150-320 ms on the M1's efficiency cores, which the VM also uses. That is why p95 is wide even when the machine is idle.

## Capacity

A step test (`loadtest/k6/steps.js`) held each rate for 90 s:

| req/s | p50 | p95 |
|---|---|---|
| 10 | 107 ms | 273 ms |
| 20 | 146 ms | 1.4 s |
| 25 | 193 ms | 3.1 s |
| 30 | 653 ms | 12.7 s |

**Max sustainable: about 15 req/s.** With 10 replicas, a steady 15 req/s held p95 at 0.2-0.5 s, but any burst of host load (pods starting, another app) pushed p95 to several seconds. 10 req/s is the comfortable rate, and that is what the test uses.

## Bottleneck

**Host CPU.** At 20 req/s the 10 replicas used about 0.5 cores each, and the app nodes together used about 7.6 of 8 vCPUs. Traefik used 50m. CPU throttling stayed under 5%. Every k3d node reports the whole VM's 8 CPUs, so the scheduler sees 40 CPUs and the HPA keeps adding pods with no real CPU behind them.

## Result (10 req/s)

- The HPA went 3 to 10 replicas. At 10 replicas the split was 6 spot / 4 on-demand, and on-demand never had 0 ready replicas (`placement.txt`).
- Hold phase: p95 255 ms, p99 791 ms. 0 of 4,199 requests failed.
- Screenshot: `docs/evidence/grafana-during-load.png`.

## Thresholds

- `http_req_failed < 1%` over the whole run.
- **Hold phase only:** `p95 < 1 s`, `p99 < 2.5 s`. That is about 3 times the baseline p95, so efficiency-core noise passes but queueing fails. The ramp phase isn't latency-gated, because it measures how fast the HPA reacts.

## Alert

`QuoteApiLatencyHigh`: p95 > 1 s for 3 minutes, while traffic is above 0.5 req/s. That is the same 3x-baseline line. Short spikes (pod starts, the ramp) are under 3 minutes, but sustained saturation isn't. It fired in the 20 req/s overload run (`docs/evidence/run-20rps/`). That run failed its k6 thresholds (p95 3.5 s), but the script version at the time hid k6's exit code behind `tee` and printed PASS. That bug is fixed.

## What to scale first in production

Node CPU, not replicas. Set the CPU request to the real cost (about 1 core per 10 req/s), so pods only fit where there is CPU and Karpenter adds nodes when they don't. Then lower the HPA target to about 50%, so capacity arrives before p95 climbs. The ingress has plenty of headroom.
