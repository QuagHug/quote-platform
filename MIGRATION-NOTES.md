# Migration notes: GitLab CI to GitHub Actions

`.github/workflows/ci.yml` replaces `ci/legacy.gitlab-ci.yml`. I kept the old pipeline's intent (test, scan, build, deploy) and dropped its practices.

**Every PR and every push to main** runs `test` (gofmt, `go vet`, `go test -race`), `sast` (Semgrep) and `chart` (`helm lint`, kubeconform). A failing job marks the PR red. Making them required merge checks needs a ruleset on main, plus a bypass for the bump commit.

**On main**, `build` needs all three, so nothing is published past a failure:
- `build`: build, Trivy-scan, push and cosign-sign the image.
- `toolbox`: the same for the toolbox, only when `toolbox/` changed since the commit the published toolbox was built from.
- `deploy-bump`: commit the new tags to Git. ArgoCD deploys from there, so CI never holds cluster credentials.

## What changed and why

| Legacy | Now | Why |
|---|---|---|
| AWS keys in `variables:` | Deleted. If AWS is needed: GitHub OIDC with `role-to-assume` | No job used them. OIDC (OpenID Connect) swaps a per-job token for short-lived credentials, so no key is stored. |
| `sonar_check` with `allow_failure: true`, no `sonar.qualitygate.wait` | Semgrep `--error` (`p/golang`, `p/dockerfile`, `p/secrets`, `p/github-actions`) | The old gate could never fail. |
| `npm test \|\| echo "tests flaky, continuing"` on `node:16` | `go vet`, `go test -race` | `\|\| echo` forces exit 0. Node 16 is end of life. |
| `only: master` | Checks on `pull_request`, publishing on `push` to main | The old pipeline checked code after merge. |
| dind, `docker login -p` | buildx, `docker/login-action` with `GITHUB_TOKEN` | dind (Docker-in-Docker) needs a privileged runner. `-p` leaks into the process list. |
| `:latest` only | Full git SHA tag, amd64 plus arm64, signed by digest | `latest` is mutable: no audit, no rollback. |
| `kubectl set image` with `$KUBECONFIG_CONTENT` | `deploy-bump` commits the tag, ArgoCD pulls it | No cluster credentials in CI. Rollback is `git revert`. |
| `bitnami/kubectl:1.24` | Removed | The tag returns 404 and 1.24 is long unsupported. |
| `when: manual` | Automatic bump | A reviewer-gated environment deadlocks a one-person repo. In production, `deploy-bump` would sit behind one. |
| Floating versions | Actions pinned to commit SHAs, containers to `tag@digest`, Dependabot with a 7-day cooldown | Tags move. On 2026-03-19, 76 of 77 `aquasecurity/trivy-action` tags were force-pushed to credential-stealing code ([GHSA-69fq-xp46-6x23](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23)). Repos pinned to a commit after 2025-04-09 were not affected. Older SHA pins still pulled the hijacked `setup-trivy`. |
| No image scan | Trivy gate: fixable HIGH or CRITICAL fails the job | Vulnerable images never reach the registry. The toolbox scan only reports. |

**Legacy file.** The copy in `ci/` has its AWS keys replaced by `<redacted>`. They were AWS documentation examples, but scanners match on shape.

**Triage.** The first scan flagged `math/rand` in `app/main.go`. It picks a quote, not a secret, so I suppressed that one rule on that import: `// nosemgrep: go.lang.security.audit.crypto.math_random.math-random-used -- picks a quote, not a secret`. An inline suppression with a reason is auditable in the diff. `allow_failure` hides everything.

**deploy-bump.**
- It sets the tag in `charts/quote-api/values.yaml`. When `toolbox` ran, the same commit points `docker-compose.yml` at `ghcr.io/<owner>/quote-toolbox:${TOOLBOX_TAG:-<sha>}`.
- A push made with `GITHUB_TOKEN` starts no new run, so there is no loop.
- Runs on main never cancel a run in progress. At most one waits and a newer push replaces it, so the newest tag lands last. `toolbox` diffs against the compose tag, so a replaced run can't skip a rebuild.
- Under a ruleset, use a GitHub App token with bypass rights, or Argo CD Image Updater.

**One-time step.** New GHCR packages are private. Make both public after the first push, then check `docker manifest inspect ghcr.io/quaghug/quote-api:<sha>` while logged out.

**Checking a signature.**

```sh
cosign verify ghcr.io/quaghug/quote-api@sha256:<digest> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/QuagHug/quote-platform/.github/workflows/ci.yml@refs/heads/main$'
```

## Migrating GitLab CI variables and secrets

1. **Inventory** project, group and instance variables via the API (`/projects/:id/variables`, `/groups/:id/variables`) with their protected, masked and scope flags. Grep CI files for hardcoded values.
2. **Classify.** Config to `vars.*`. Shared secrets to repository secrets. Protected values to a `production` environment limited to `main` with required reviewers. Group values to organization secrets.
3. **Delete instead of copying.** AWS keys become OIDC, `CI_REGISTRY_*` becomes `GITHUB_TOKEN`, `KUBECONFIG_CONTENT` becomes ArgoCD (revoke its token), `SONAR_TOKEN` goes.
4. **Create the rest from stdin** (`gh secret set NAME --env production < file`) to keep them out of shell history.
5. **Rotate everything that lived in GitLab** and revoke the old values. Masking only hides logs.
6. **Enable secret scanning and push protection**, and keep `p/secrets` in CI.
