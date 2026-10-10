# Part 5: IaC design (validate-only)

Nothing here is applied. `./scripts/50-validate-tf.sh` runs `terraform fmt -check`, `init -backend=false` and `validate` on `cloudflare/`, then `kubeconform -strict` on `karpenter/` against schemas generated from the Karpenter v1.15.0 CRDs. No Cloudflare token is needed.

Versions checked 2026-10-11: Karpenter v1.15.0 (`karpenter.sh/v1`, `karpenter.k8s.aws/v1`), Cloudflare provider v5.27.0, Terraform 1.16.5.

## 5a: Karpenter GPU nodes

- **Spot first:** NodePools `gpu-spot` (weight 100) and `gpu-on-demand` (weight 10) share EC2NodeClass `gpu`, so each capacity type has its own limits and disruption settings.
- **Nodes:** g5, g6, g6e, at most 4 GPUs, tainted `nvidia.com/gpu:NoSchedule`, AMI pinned to `al2023@v20261003`. Limits: 16 GPUs spot, 8 on-demand.
- **Consolidation:** `WhenEmpty`, so a serving pod is never moved and forced to reload its model. The cost: a busy on-demand fallback node is not swapped back to spot. It goes when empty, at `expireAfter: 720h`, or on drift.
- **Budgets:** one node at a time, no drift 08:00 to 18:00 UTC on weekdays.
- **`karpenter.sh/do-not-disrupt`** blocks consolidation but not drift, because both pools set `terminationGracePeriod: 1h`. AMI updates never stall on an annotated pod.
- **Not included:** NVIDIA device plugin, interruption queue, node IAM role, discovery tags.

### Spot vs on-demand for AI inference

Spot saves about 56% (g5.xlarge in us-east-1: $1.006/hr on-demand, about $0.44/hr spot, roughly $410/month per node), but g5.xlarge and g6.xlarge sit in AWS's highest interruption bucket (over 20%), and a reclaim gives 2 minutes' notice that nothing in Kubernetes can extend. Spot fits short, idempotent requests behind a retrying client, with enough replicas to lose one. Long generations, streaming, batch jobs and large warm caches belong on on-demand. With a hard latency SLO, keep a small on-demand baseline and burst onto spot, so reclaims cost headroom, not availability.

## 5b: Cloudflare

- Proxied CNAME `quote-api.example.com`.
- Static assets cache 30 days at the edge, 1 day in browsers (a purge cannot clear browsers). `/api` and `/api/*` bypass, placed last because the last matching rule wins.
- The `import` block adopts a hand-made `www` record: set `id` to `<zone_id>/<record_id>`, expect `plan` to show `1 to import, 0 to add, 0 to change`.
- A zone has one cache ruleset. If the dashboard already made one, import it first.
- Token comes from `CLOUDFLARE_API_TOKEN`, scoped to DNS and Cache Rules edit on this zone.
