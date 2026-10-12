# AI usage

**Tool:** Claude Code (Claude Opus 5.5 / Fable 5.1) for all parts: research, code, docs, and running the checks.

## How I used it

I followed the practices current guidance recommends for AI in infra work:

| Recommended practice | What I did here |
|---|---|
| **AI drafts, a human decides and owns** ([GitHub](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/risks-and-mitigations)) | I made the calls: k3d, Go, all three tracks, the placement trade-offs. I can walk through every file. |
| **Deterministic checks are the gate** ([Thoughtworks](https://www.thoughtworks.com/en-us/radar/techniques/feedback-sensors-for-coding-agents)) | Nothing counted as done until it passed: `go test -race`, Semgrep, helm lint, kubeconform, actionlint, terraform validate, Trivy, `verify.sh`, the drill and load-test scripts. CI re-runs the static checks on every push (go test, Semgrep, helm lint, kubeconform, Trivy); the cluster checks run in the scripts. |
| **Small changes in version control, rollback ready** ([DORA](https://cloud.google.com/blog/products/ai-machine-learning/introducing-doras-inaugural-ai-capabilities-model)) | Everything is in git. Deploys are a git commit, so rollback is `git revert`. |
| **Least privilege for the agent** ([Google SRE](https://sre.google/resources/practices-and-processes/ai-engineering-reliable-operations/)) | It worked on a throwaway local cluster and this repo only. No cloud or production credentials existed. Research agents were read-only. |
| **Human approves anything that mutates or goes outside** ([Google Cloud](https://cloud.google.com/blog/topics/developers-practitioners/how-google-sres-use-gemini-cli-to-solve-real-world-outages)) | I approved the GitHub account, making the repo public, and running the drill and load tests before they happened. |
| **Verify against reality, not the model's memory** ([OWASP LLM09](https://genai.owasp.org/llmrisk/llm092025-misinformation/)) | Versions and APIs were checked against live sources (Karpenter v1.15.0 CRDs, Cloudflare provider v5, image tags in the registries). Every claim was run on the cluster. A second agent tried to refute the findings. |

## Prompts that helped

1. **Propose options, then decide**
   > Propose two or three ways to build the compose harness, such as k3d via the Docker socket or k3s as compose services. For each, list the trade-offs for setup, teardown, portability and security, and recommend one. Do not implement until I choose.

2. **Read-only investigation**
   > Investigate only: read files and documentation and run read-only commands. Do not create, apply, push or write anything. Return findings with evidence.

3. **Stop before outward actions**
   > Before any action that publishes, deletes or changes shared state, such as creating the repo, pushing, or changing Docker settings, stop and list what it touches, what it does not touch, and how to undo it.

4. **Thresholds from measurements**
   > Measure a baseline at low load, then step the request rate up. Derive the k6 thresholds and the alert threshold from the measured p95 and p99, not generic numbers, and identify the bottleneck with evidence: CPU, throttling or ingress.

5. **Supply-chain review of CI**
   > Review this GitHub Actions workflow for supply-chain risk: actions not pinned to a commit SHA, token permissions broader than each job needs, secrets that could reach logs, and untrusted input used in run steps. Propose fixes ranked by risk.

## Where the AI was wrong

1. **Placement:** claimed ReplicaSet scale-down spares the on-demand replica. An adversarial review showed from the controller source that it deletes from the busiest node, the on-demand one, first. Fix: HPA scale-down 1 pod/min.
2. **Load test:** assumed 40 req/s was fine. It overloaded; a step test found the real limit (~15) and the thresholds now come from it.

Also caught in review: Part 7 over the page limit, a wrong claim about what Karpenter's `do-not-disrupt` blocks (see [iac/README.md](iac/README.md)), and a Terraform `import` without a matching resource.
