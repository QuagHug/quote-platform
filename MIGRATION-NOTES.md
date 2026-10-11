# Migration notes: GitLab CI → GitHub Actions (Part 4)

[`ci.yml`](.github/workflows/ci.yml) replaces [`ci/legacy.gitlab-ci.yml`](ci/legacy.gitlab-ci.yml).

**Flow:** PRs and main run `test`, `sast` (Semgrep) and `chart`. On main, once they pass: `build` (Trivy, push, sign), `toolbox` (if changed), then `deploy-bump` commits the new tag for Argo CD.

## What changed

| Legacy | Now | Why |
|---|---|---|
| AWS keys in `variables:` | Removed (OIDC if ever needed) | Unused; OIDC stores no keys |
| Sonar with `allow_failure: true` | Semgrep `--error` | Old gate could never fail |
| `npm test \|\| echo` on `node:16` | `go vet`, `go test -race` | `\|\| echo` forced success; Node 16 is EOL |
| `only: master` | Checks on PRs | Code was checked after merge |
| dind + `docker login -p` | buildx + `GITHUB_TOKEN` | No privileged runner, no password in process list |
| `:latest` | Full SHA tag, multi-arch, cosign-signed | Traceable, rollback-able |
| `kubectl set image` with kubeconfig secret | Git commit, Argo CD pulls | No cluster credentials in CI |
| `bitnami/kubectl:1.24` | Removed | Tag returns 404 |
| `when: manual` | Automatic bump | Approval gate would deadlock a solo repo; production adds one |
| Floating versions | Actions pinned to SHA, Dependabot | Tags move (trivy-action tags were hijacked 2026-03-19, [GHSA-69fq-xp46-6x23](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23)) |
| No image scan | Trivy fails on fixable HIGH/CRITICAL | Bad images never published |

**Notes**
- The legacy copy has its example AWS keys redacted.
- One Semgrep finding (`math/rand` picking a quote) is suppressed inline with a reason, which is auditable unlike `allow_failure`.
- `GITHUB_TOKEN` pushes start no new run, so the bump can't loop.
- Both GHCR packages came out public because they're linked to this public repo.

## Migrating GitLab variables and secrets

1. Inventory project, group and instance variables with their flags.
2. Delete what's replaced: AWS keys (OIDC), registry creds (`GITHUB_TOKEN`), kubeconfig (Argo CD).
3. Map the rest: config → `vars`, secrets → repo secrets, protected → `production` environment secrets.
4. Rotate everything that lived in GitLab.
5. Enable secret scanning and push protection.
