# AI usage

## Tools

- **Claude Code (Claude Opus 5.5)** for all parts: reading the brief, checking current versions and APIs, writing code and docs, and running the checks.
- **Separate review agents** (also Claude) for a second opinion on each part, prompted to refute rather than agree.

## How I used it

1. **Research before code.** I asked for current versions and API shapes with sources (Karpenter v1, Cloudflare provider v5, Argo CD and k3s releases), not answers from memory.
2. **Adversarial review.** A second agent tried to disprove the research and each deliverable, and re-ran the validators itself.
3. **Nothing accepted without running it.** go test, Semgrep, helm lint, kubeconform, actionlint, terraform validate, the live cluster, `verify.sh`, the drill, the load test, and CI on GitHub.

## Prompts that moved the work forward

1. *"List every independent defect in broken-app.yaml that blocks verify.sh: the kubectl symptom, the diagnose command, root cause and minimal fix. Cite evidence and mark anything you could not verify."*
2. *"You are a skeptic. Try to refute these findings: wrong Kubernetes semantics, outdated API versions, fixes that would still fail verify.sh. Only list a refutation when you have evidence."*
3. *"Verify the current stable Karpenter API and the Cloudflare provider resource names against the latest releases, not memory."*

## Where the AI was wrong

1. **Placement.** The first design claimed the ReplicaSet's deletion order keeps a replica on on-demand. The skeptic agent showed the opposite from the controller source: scale-down removes pods from the busiest node first, which is the on-demand node under a hard pool spread. Fixed with an HPA scale-down of 1 pod per minute.
2. **Part 3 DNS.** It predicted the smoke test would fail with "Could not resolve host". On the live cluster DNS resolved, and `verify.sh` passed even without the DNS rule. A probe pod showed why: kube-router enforces policy on a new pod a few seconds late (lookup at t=0 worked, t=8s failed). I kept the rule and documented it.
3. **Load test.** Its first thresholds assumed 10 req/s per CPU core and a 40 req/s peak. The real run overloaded at 40 req/s. A step test showed the limit is about 20 req/s on this machine, and the thresholds now come from that.

Smaller misses caught by the review agents: a Part 7 draft over the page limit, a wrong claim about `do-not-disrupt` and drift, and a Terraform `import` block with no matching resource.
