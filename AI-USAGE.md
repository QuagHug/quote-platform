# AI usage

**Tool:** Claude Code (Claude Opus 5.5 / Fable 5.1) for all parts: research, code, docs, and running the checks.

## How I used it

I followed the practices current guidance recommends for AI in infra work:

| Recommended practice | What I did here |
|---|---|
| **AI drafts, a human decides and owns** ([GitHub](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/risks-and-mitigations)) | I made the calls: k3d, Go, all three tracks, the placement trade-offs. I can walk through every file. |
| **Deterministic checks are the gate** ([Thoughtworks](https://www.thoughtworks.com/en-us/radar/techniques/feedback-sensors-for-coding-agents)) | Nothing counted as done until it passed: `go test -race`, Semgrep, helm lint, kubeconform, actionlint, terraform validate, Trivy, `verify.sh`, the drill and load-test scripts. CI runs the same gates. |
| **Small changes in version control, rollback ready** ([DORA](https://cloud.google.com/blog/products/ai-machine-learning/introducing-doras-inaugural-ai-capabilities-model)) | Everything is in git. Deploys are a git commit, so rollback is `git revert`. |
| **Least privilege for the agent** ([Google SRE](https://sre.google/resources/practices-and-processes/ai-engineering-reliable-operations/)) | It worked on a throwaway local cluster and this repo only. No cloud or production credentials existed. Research agents were read-only. |
| **Human approves anything that mutates or goes outside** ([Google Cloud](https://cloud.google.com/blog/topics/developers-practitioners/how-google-sres-use-gemini-cli-to-solve-real-world-outages)) | I approved the GitHub account, making the repo public, and running the drill and load tests before they happened. |
| **Verify against reality, not the model's memory** ([OWASP LLM09](https://genai.owasp.org/llmrisk/llm092025-misinformation/)) | Versions and APIs were checked against live sources (Karpenter v1.15.0 CRDs, Cloudflare provider v5, image tags in the registries). Every claim was run on the cluster. A second agent tried to refute the findings. |

## Prompts that helped

1. **Diagnosis (Part 3)**
   > Context: k3s cluster with a default-deny NetworkPolicy; node labels and taints set by `prepare.sh` must not change. Identify every independent defect in `broken-app.yaml` that prevents `verify.sh` from passing. For each, give the symptom, the `kubectl` command that confirms it, the root cause, and the minimal fix. Cite evidence and flag anything you could not verify.

2. **Adversarial review**
   > Act as a critical reviewer of the findings below. Try to disprove them: incorrect scheduling or networking semantics, deprecated or non-existent API versions, and fixes that would still fail verification. Report only refutations backed by source code, official documentation, or command output.

3. **Version check before writing IaC (Part 5)**
   > Before writing any manifests, confirm the current stable Karpenter API (NodePool, EC2NodeClass) and the Cloudflare Terraform provider's resource names against the latest official releases. Do not rely on prior knowledge; cite the release or documentation used.

## Where the AI was wrong

1. **Placement:** claimed ReplicaSet scale-down spares the on-demand replica. The adversarial review (prompt 2) showed from the controller source that it deletes from the busiest node, the on-demand one, first. Fix: HPA scale-down 1 pod/min.
2. **Load test:** assumed 40 req/s was fine. It overloaded; a step test found the real limit (~15) and the thresholds now come from it.

Also caught in review: Part 7 over the page limit, a wrong claim about what Karpenter's `do-not-disrupt` blocks (see [iac/README.md](iac/README.md)), and a Terraform `import` without a matching resource.
