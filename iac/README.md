# Part 5 - IaC design (validate-only)

Nothing in this folder is applied. It is designed to pass `terraform validate` and schema checks, and to be correct enough to apply against a real EKS cluster and Cloudflare zone once the placeholders are filled in.

## What is here

| File | What it is |
|---|---|
| `karpenter/ec2nodeclass-gpu.yaml` | **EC2NodeClass** `gpu`. Karpenter is the EKS node autoscaler: it watches for pods that cannot be scheduled and launches EC2 instances for them. The EC2NodeClass is the AWS half of that config: which AMI, IAM role, subnets, security groups and disks a new node gets. |
| `karpenter/nodepool-gpu-spot.yaml` | **NodePool** `gpu-spot` (weight 100). A NodePool is the Kubernetes half: which instance types and capacity types Karpenter may pick, what taints and labels the node gets, how much it may launch in total, and when it may remove nodes. |
| `karpenter/nodepool-gpu-on-demand.yaml` | NodePool `gpu-on-demand` (weight 10), the fallback when spot capacity is not available. Same node class, same taint. |
| `karpenter/schemas/` | JSON schemas for `NodePool` and `EC2NodeClass`, generated from the Karpenter v1.15.0 CRDs. Only the validate script reads them; they are not applied. |
| `cloudflare/versions.tf` | Terraform and Cloudflare provider versions. The provider block is empty on purpose: the provider reads the token from the `CLOUDFLARE_API_TOKEN` environment variable, so no credential is ever in code. |
| `cloudflare/variables.tf` | `zone_id` (required, not a secret), the origin hostname, and the static-asset TTLs. |
| `cloudflare/dns.tf` | The proxied `quote-api.example.com` record, plus an `import` block and the matching resource that adopt a hand-made `www` record. |
| `cloudflare/cache_rules.tf` | A **ruleset**: an ordered list of rules that Cloudflare runs at one phase of request handling. Cache rules live in the `http_request_cache_settings` phase. |
| `cloudflare/.terraform.lock.hcl` | Provider checksums for linux_amd64, linux_arm64 and darwin_arm64, so `init` installs exactly v5.27.0 everywhere. |

Versions checked live on 2026-10-11: Karpenter v1.15.0 (CRDs serve only `karpenter.sh/v1` and `karpenter.k8s.aws/v1`), Cloudflare provider v5.27.0, Terraform 1.16.5, EKS AMI release v20261003.

## How to validate

```sh
./scripts/50-validate-tf.sh
```

It runs inside the toolbox container and does four things, and exits non-zero if any fails:

1. `terraform fmt -check -recursive` on `iac/cloudflare`
2. `terraform init -backend=false -lockfile=readonly` (downloads the provider, never touches state)
3. `terraform validate` (no Cloudflare token needed: validate never calls the provider API)
4. `kubeconform -strict` on `iac/karpenter`, against JSON schemas vendored in `iac/karpenter/schemas/`

The schemas are generated from the Karpenter v1.15.0 CRDs (`pkg/apis/crds/karpenter.sh_nodepools.yaml` and `karpenter.k8s.aws_ec2nodeclasses.yaml` at the `v1.15.0` tag of aws/karpenter-provider-aws), so they match the version the manifests target and cannot change under us. The community CRDs-catalog was not used because its main branch moves and can lag a new Karpenter release. Generation used kubeconform's own converter at the tool's version in the toolbox (`scripts/openapi2jsonschema.py` at yannh/kubeconform `v0.8.0`), run from each group folder:

```sh
DENY_ROOT_ADDITIONAL_PROPERTIES=1 FILENAME_FORMAT='{kind}_{version}' python3 openapi2jsonschema.py <crd.yaml>
```

That gives `schemas/<group>/<kind>_<version>.json`, the layout the script's `-schema-location` template expects. Every object gets `additionalProperties: false`, so a misspelled field fails the check instead of being ignored. To move to a newer Karpenter, regenerate from that release's CRDs.

The first run needs internet access to download the Cloudflare provider, which is cached under `/tmp` in the toolbox, so reruns are fast and the repo stays clean (no `.terraform/` directory is written into it). The Karpenter check runs offline.

What it cannot check: the CEL rules inside the Karpenter CRDs (for example "exactly one of role or instanceProfile") only run in a real API server, so I checked those by hand against the v1.15.0 CRDs. `terraform plan` needs a real token and zone.

## 5a - Karpenter for GPU inference

- **Spot first, on-demand fallback.** Two NodePools share one node class. Karpenter tries higher weights first, so `gpu-spot` (100) wins whenever spot GPUs are available, and `gpu-on-demand` (10) is used when they are not. Karpenter remembers unavailable spot capacity for about 3 minutes and then retries spot. The docs say Karpenter does not guarantee it will always pick the highest-weight pool. A single pool allowing both capacity types would also prefer spot; two pools give each capacity type its own limits and disruption settings.
- **Instances.** NVIDIA, x86 (`amd64`), category `g`, families `g5` (A10G), `g6` (L4) and `g6e` (L40S), at most 4 GPUs per node. Several families give spot more pools to draw from. The 4-GPU cap limits how many replicas a single spot reclaim can take out at once.
- **Taint `nvidia.com/gpu:NoSchedule`.** Only pods that tolerate it land on these expensive nodes.
- **Disruption that does not cut requests off.**
  - `consolidationPolicy: WhenEmpty`: Karpenter only removes a node once no inference pod is left on it. It never moves a running pod to pack nodes tighter, because a moved pod has to reload its model. `Balanced` (new in v1.14) is the middle ground if cost starts to matter more.
  - The cost of `WhenEmpty`: a fallback on-demand node is never swapped back to spot while it is busy. It goes away only when it is empty (5m later), when it reaches `expireAfter`, or when drift replaces it. `Balanced` or `WhenEmptyOrUnderutilized` would replace it with a cheaper spot node once spot is back, but that means moving its pods and reloading their models (and nodes running `do-not-disrupt` pods are skipped either way).
  - `consolidateAfter`: 15m on spot and 5m on on-demand. This avoids churn between bursts, and expensive fallback nodes go away sooner once idle.
  - Budgets: at most 1 node disrupted at a time, and `nodes: "0"` for `Drifted` from 08:00 to 18:00 UTC on weekdays. An AMI bump therefore rolls nodes only outside business hours. Karpenter's budget cron has no timezone support, so shift it to your users' peak.
  - `expireAfter: 720h` rotates every node monthly for patching. Expiration is forceful: it ignores budgets and `do-not-disrupt`. `terminationGracePeriod: 1h` still gives pods up to an hour to drain, and it also stops a stuck pod from blocking a drain forever.
- **Pods opt in to extra protection** with the `karpenter.sh/do-not-disrupt: "true"` annotation. Here it blocks consolidation only. It does **not** block drift, because both NodePools set `terminationGracePeriod`, and the Karpenter docs say a node with that field set stays eligible for drift even when annotated pods run on it. So an AMI bump still replaces the node, just never inside the weekday 08:00-18:00 UTC window that the `Drifted` budget closes. During that drain Karpenter does not evict the annotated pod, but it deletes it early enough to give the pod its own grace period before the 1h node limit runs out: with the 120s grace period in the example below, that is about 58 minutes after the drain starts. The annotation also does not block spot interruption, expiration, node repair (alpha, off by default) or manual deletion (`kubectl delete node`). Removing `terminationGracePeriod` would make the annotation block drift too, but then a node that expires with an annotated pod on it can sit in drain forever, which the Karpenter docs advise against. I kept the grace period so every node still gets patched.
- **Limits** cap total spend per pool: 16 GPUs / 256 vCPU / 1024Gi on spot, 8 GPUs / 128 vCPU / 512Gi on on-demand.
- **EC2NodeClass.** `al2023@v20261003` is pinned, because `@latest` would drift and replace every GPU node whenever AWS ships an AMI. Bump the pin on purpose after testing. Karpenter picks the NVIDIA variant of the AMI for GPU instances by itself. Subnets and security groups are found by the `karpenter.sh/discovery: quote-prod` tag. The root volume is 200Gi gp3 (6000 IOPS, 500 MiB/s) for multi-GB inference images and model weights. IMDSv2 (the token-based instance metadata API) is required with hop limit 1, so pods that are not on the host network cannot read the node's IAM credentials.
- **Prerequisites not in this folder:** the NVIDIA device plugin DaemonSet (without it Karpenter never marks GPU nodes as initialized), the Karpenter interruption SQS queue (`--interruption-queue`, which is how the 2-minute spot notice reaches Karpenter), the `KarpenterNodeRole-quote-prod` IAM role, and the discovery tags on subnets and security groups.

A GPU inference pod would carry:

```yaml
metadata:
  annotations:
    karpenter.sh/do-not-disrupt: "true"
spec:
  terminationGracePeriodSeconds: 120
  nodeSelector:
    workload-type: gpu-inference
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: model
      resources:
        limits:
          nvidia.com/gpu: 1
```

### Spot vs on-demand for AI inference

Spot GPUs are about half price, but you can lose them at any moment, and the protections people expect do not help. In us-east-1 a g5.xlarge is $1.006/hr on-demand, about $734/month running 24x7. The AWS Spot Instance Advisor (checked 2026-10-11) shows 56% savings over on-demand (about $0.44/hr), roughly $410/month saved per GPU node. The same advisor puts g5.xlarge and g6.xlarge in its highest interruption bucket (over 20%). When AWS reclaims a spot node you get a 2-minute notice. `karpenter.sh/do-not-disrupt`, PDBs and `terminationGracePeriod` cannot extend it, so any request still running after 2 minutes is lost. Spot therefore fits stateless inference where each request is short (well under 2 minutes) and idempotent, the client or gateway retries on a 5xx or reset, there are enough replicas spread across nodes to absorb losing one, and pods stop taking new requests as soon as they get SIGTERM (Karpenter starts draining the node when the notice arrives). Long or stateful work goes on on-demand, using `nodeSelector: {karpenter.sh/capacity-type: on-demand}`: batch jobs, long generations, streaming sessions, and anything holding a large warm cache. If the service has a hard latency SLO, keep a small on-demand baseline that is always up and burst onto spot, so a wave of reclaims costs headroom rather than availability.

## 5b - Cloudflare in Terraform

- `quote-api.example.com` is a proxied CNAME to the origin load balancer. `ttl = 1` means "automatic", which is what Cloudflare uses for proxied records.
- The cache ruleset has two rules. The first caches static files (by extension: js, css, images, fonts, source maps) for 30 days at the edge and 1 day in browsers. The browser TTL is shorter because a Cloudflare purge cannot clear browser caches. The second rule bypasses the cache for `/api` and `/api/*`.
- **Adopting the hand-made `www` record:** look up its ID (`GET /zones/<zone_id>/dns_records?name=www.example.com`), put `<zone_id>/<record_id>` in the `import` block's `id`, and run `terraform plan`. You want `1 to import, 0 to add, 0 to change`. If attributes differ, edit the `legacy_www` resource until they match what is live. The resource block is required: without it `validate` still passes, but `plan` fails with `Configuration for import target does not exist` (checked on Terraform 1.16.5). Import blocks need Terraform 1.5 or newer (1.4.7 rejects the block, 1.5.7 validates), hence `required_version >= 1.5.0`.
- The token needs only Zone > DNS > Edit and Zone > Cache Rules > Edit, scoped to this one zone.

Two Cloudflare traps:

1. Cache rules stack, and when two matching rules set the same setting, the **last** matching rule wins. That is why the `/api` bypass is the last rule: a future "cache everything" rule added above it can never start caching API responses.
2. A zone has at most **one entry point ruleset per phase**. If anyone ever created cache rules in the dashboard, that ruleset already exists and `terraform apply` fails to create a second one. Import it first (`id = "zones/<zone_id>/<ruleset_id>"`), and from then on this ruleset owns every cache rule in the zone, so dashboard edits will be overwritten.
