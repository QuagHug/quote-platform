# Ops answers (Part 7)

## 1. Upgrade EKS 1.33 to 1.35 with zero downtime

EKS upgrades one minor version at a time, so do two upgrades (1.34, then 1.35), each on staging first.

1. **Check first:** find uses of APIs the next version removes (EKS upgrade insights, `pluto`), and move nodes off Amazon Linux 2 (no images after 1.32).
2. **Control plane:** AWS upgrades the API servers; running pods are untouched. Rollback is possible for 7 days.
3. **Add-ons:** update vpc-cni, CoreDNS and the EBS/EFS storage drivers to the versions AWS lists for the new release.
4. **Nodes:** new nodes start on the new version and old ones drain one at a time; PodDisruptionBudgets keep enough replicas up. Karpenter does this automatically.
5. **kube-proxy last**, so it is never newer than the nodes.

**Top risks:**
1. **Old node images:** the 1.35 kubelet won't start on cgroup v1, so those nodes can't join. Move to AL2023 or Bottlerocket first.
2. **Cluster tools not ready:** Karpenter, the Load Balancer Controller, storage drivers and External Secrets must support 1.35 first.
3. **Stuck drains:** a PodDisruptionBudget allowing 0 disruptions blocks node replacement, and new nodes need free subnet IPs and capacity.

## 2. Stop spot reclaims paging at 3 AM

A spot reclaim is expected, not an incident: make it invisible and page only on real impact.

1. **Drain before the node disappears:** Karpenter receives AWS's 2-minute warning and moves the pods, so the node never shows as unreachable.
2. **Fix the default alert:** `KubeNodeUnreachable` ignores nodes being removed by aws-node-termination-handler but not by Karpenter (taint `karpenter.sh/disrupted`). Replace it with a copy that ignores both.
3. **Split by capacity type:** an on-demand node down pages; one spot node down is a ticket.
4. **Page on user impact:** SLO burn, pods unschedulable for 10 minutes, deployments missing replicas, or a whole zone gone. This still catches losing all spot capacity at once.
5. **Mute follow-on alerts** for a node while it is being removed.

## 3. Mobile LCP is 5 s, HTML caching suspected

Prove whether Cloudflare caches the HTML, find why not, then check whether HTML is even the problem.

1. **Request twice as a phone:** `curl -sI -A "<iPhone user agent>" https://site/`.
2. **Read `cf-cache-status`:** `DYNAMIC` means never cached (the HTML default), `BYPASS` means the origin forbade it, `MISS` every time means the cache key keeps changing, `HIT` means it works.
3. **Check Cache Rules:** HTML needs a rule marking it eligible for cache. A later bypass rule overrides an earlier one.
4. **Check the origin directly:** `curl -sI --resolve site:443:<origin-ip> https://site/`. `private`, `no-store`, `max-age=0` or any `Set-Cookie` blocks caching; public pages should send `public, s-maxage=300` and no cookies.
5. **Check the cache key:** tracking parameters (`utm_*`, `gclid`) and per-device caching split one page into many keys.
6. **If HTML is a fast HIT but LCP is still 5 s,** the page is slow: usually the hero image or render-blocking CSS.

## 4. Secrets on EKS

| | External Secrets Operator (ESO) | Secrets Store CSI Driver |
|---|---|---|
| How the app gets it | Copied into a normal Kubernetes Secret | Mounted as a file at pod start |
| Stored in the cluster | Yes | No |
| Secrets Manager briefly down | Pods still start | New pods can't start |

**Pick ESO with AWS Secrets Manager** for several production clusters:
1. **Works with GitOps:** Git holds only references, never values, and every cluster is set up the same way.
2. **No app changes:** apps read normal Secrets.
3. **Tight access:** each app's IAM role (EKS Pod Identity) reads only its own path, e.g. `prod/<cluster>/<app>/*`.

**Downside:** values sit in the cluster database (etcd), so encrypt it with KMS and limit who can read Secrets.
