# Ops answers (Part 7)

## 1. EKS 1.33 to 1.35, zero downtime

Two hops, back to back (1.33 is on paid extended support, 1.34 leaves standard support on 2026-12-02), each rehearsed on staging:

1. **Pre-checks:** `aws eks list-insights` plus `pluto`/`kubent` on rendered manifests; nodes on the current minor and off AL2 (EKS AL2 AMIs stopped at 1.32).
2. **Control plane:** `aws eks update-cluster-version --name prod --kubernetes-version 1.34` (7-day rollback window).
3. **Add-ons:** vpc-cni, coredns and EBS/EFS CSI, at versions from `aws eks describe-addon-versions`.
4. **Nodes:** managed node groups surge and drain within PodDisruptionBudgets (PDBs); Karpenter drifts nodes to the new AMI within its disruption budget.
5. **kube-proxy last**, per the skew policy.

Top risks:

1. **Node OS:** the 1.35 kubelet refuses cgroup v1 by default and drops `--pod-infra-container-image`. Move custom AMIs to AL2023 or Bottlerocket first.
2. **Controllers:** Karpenter, the LB Controller, CSI and ESO must support the target before the control plane moves. kube-proxy IPVS is deprecated in 1.35.
3. **Drains:** a PDB with 0 allowed disruptions blocks drains, and a `karpenter.sh/do-not-disrupt` pod stalls Karpenter drift unless the NodePool sets `terminationGracePeriod`. Surge nodes also need subnet IPs and spot or GPU capacity.

## 2. Spot reclaim alert storms

1. **Make reclaims a non-event:** on the 2-minute spot warning, Karpenter's interruption queue drains and deletes the node before it goes unreachable.
2. **Teach the alert:** `KubeNodeUnreachable` ignores the termination handler's `spot-itn` taint but not `karpenter.sh/disrupted`. In kube-prometheus-stack, set `KubeNodeUnreachable: true` under `defaultRules.disabled` and ship a copy that ignores both.
3. **Split by capacity type:** add `karpenter.sh/capacity-type` to kube-state-metrics `--metric-labels-allowlist`. On-demand node down: page. One spot node down: ticket.
4. **Page on real loss:** SLO burn rate, pods unschedulable for 10 minutes, `KubeDeploymentReplicasMismatch`, or over 20% of nodes (or a whole AZ) unreachable.
5. **Inhibit:** `NodeDisrupting` mutes `KubeNode.*` alerts for its own `cluster` and `node`, and routes to a null receiver.

```yaml
- alert: NodeDisrupting
  expr: kube_node_spec_taint{key=~"karpenter.sh/disrupted|.*/spot-itn"} == 1
- alert: OnDemandNodeUnreachable
  expr: |
    kube_node_spec_taint{key="node.kubernetes.io/unreachable", effect="NoSchedule"}
      unless on (node) kube_node_labels{label_karpenter_sh_capacity_type="spot"}
  for: 5m
  labels: {severity: page}
```

## 3. Cloudflare HTML caching, mobile LCP 5s

1. **Check the edge twice, as a phone:** `curl -sI -A "$IPHONE_UA" https://site/ | grep -iE '^(cf-cache-status|age|cache-control|set-cookie|vary):'`
2. **Read `cf-cache-status`:** `DYNAMIC`: HTML not eligible (the default). `BYPASS`: origin response uncacheable. Always `MISS`: fragmented cache key. `HIT` with a rising `Age`: working.
3. **Rules:** HTML needs a Cache Rule ("Eligible for cache", Edge TTL); a later matching bypass rule silently overrides it.
4. **Origin:** `curl -sI --resolve site:443:<origin-ip> https://site/`. `Cache-Control: private`/`no-store`/`max-age=0` or any `Set-Cookie` blocks caching; anonymous pages need `public, s-maxage=300` and no cookies.
5. **Cache key:** exclude `utm_*`/`gclid` query strings. "Cache by device type" also splits it.
6. **HTML or render?** If a HIT has fast time to first byte but LCP stays at 5s, fix the hero image (`fetchpriority="high"`) and render-blocking CSS.

## 4. Secrets on EKS

| | ESO | Secrets Store CSI Driver |
|------|----------|----------|
| Delivery | Syncs into a native Secret | Mounts files at pod start |
| Copy in etcd | Yes | No, unless synced |
| Rotation | `refreshInterval`, plus Reloader | App must re-read the file |
| AWS outage | Existing Secret keeps working | New pods stuck in `ContainerCreating` |

**Pick External Secrets Operator (ESO) with Secrets Manager.**

1. **Same on every cluster:** ArgoCD syncs `ExternalSecret` manifests: references, never values.
2. **Easy for apps:** plain Secrets, no CSI volume; pods still start during a short AWS outage.
3. **Scoped access:** EKS Pod Identity, with each `SecretStore` on a role scoped to `prod/<cluster>/<app>/*`.

**Risks:** values land in etcd, so use a customer-managed KMS key, RBAC limits on Secret `get`/`list`, and a least-privilege ESO role.
