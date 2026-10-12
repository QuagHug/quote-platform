# IaC (Part 5, validate-only)

`./scripts/50-validate-tf.sh`: `terraform fmt/init/validate` on `cloudflare/`, `kubeconform` on `karpenter/` against vendored Karpenter v1.15.0 schemas. No token needed.

## 5a Karpenter (`karpenter.sh/v1`, v1.15.0)

- `gpu-spot` (weight 100) and `gpu-on-demand` (weight 10) share EC2NodeClass `gpu`: spot first, on-demand fallback.
- NVIDIA g5/g6/g6e, up to 4 GPUs, taint `nvidia.com/gpu:NoSchedule`, pinned AL2023 AMI. Limits: 16 GPUs spot, 8 on-demand.
- `WhenEmpty` consolidation: a serving node is never consolidated. Cost: a busy on-demand fallback isn't swapped back to spot.
- Budgets: one node at a time; no drift (node replacement after AMI or config changes) weekdays 08:00-18:00 UTC.
- `do-not-disrupt` pods block consolidation; drift still proceeds because the pools set `terminationGracePeriod: 1h`.

**Spot vs on-demand for inference.** Spot saves ~56% (g5.xlarge ~$0.44 vs $1.006/hr), but GPU spot is reclaimed often and gives only 2 minutes' notice. Use it for short, idempotent requests behind a retrying client with spare replicas. Keep long generations, streaming and batch jobs on on-demand. With a hard SLO, keep a small on-demand baseline and burst onto spot.

## 5b Cloudflare (provider v5)

- Proxied CNAME `quote-api.example.com`.
- Cache rules: static assets 30 days edge / 1 day browser; `/api` bypass is last (last match wins).
- `import` adopts the manual `www` record (`id = "<zone_id>/<record_id>"`).
- A zone has one cache ruleset; if the dashboard already created one, import it first or `apply` fails.
- A real `apply` reads `CLOUDFLARE_API_TOKEN`; nothing in code.
