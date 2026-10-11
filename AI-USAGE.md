# AI usage

**Tool:** Claude Code (Claude Opus 5.5) for all parts, plus separate review agents prompted to refute rather than agree.

## Method

1. **Research first:** current versions and APIs with sources, not memory.
2. **Adversarial review:** a second agent tried to disprove each finding and re-ran the validators.
3. **Run everything:** tests, Semgrep, helm lint, kubeconform, actionlint, terraform, the live cluster, `verify.sh`, the drill, the load test, CI.

## Prompts that helped

1. "List every defect in broken-app.yaml that blocks verify.sh: symptom, diagnose command, cause, fix. Cite evidence; mark what you couldn't verify."
2. "You are a skeptic. Refute these findings: wrong Kubernetes semantics, outdated APIs, fixes that would still fail. Only with evidence."
3. "Verify the current Karpenter API and Cloudflare provider resources against the latest releases, not memory."

## Where the AI was wrong

1. **Placement:** claimed ReplicaSet deletion order keeps an on-demand replica. The skeptic showed the opposite from source. Fix: HPA scale-down 1 pod/min.
2. **Part 3 DNS:** predicted "Could not resolve host". Live, DNS resolved and `verify.sh` passed without the rule. A probe pod showed the policy lands seconds late. Kept the rule.
3. **Load test:** assumed 40 req/s was fine. It overloaded; a step test found the real limit (~15) and the thresholds now come from it.

Also caught in review: Part 7 over the page limit, a wrong `do-not-disrupt` claim, and a Terraform `import` without a matching resource.
