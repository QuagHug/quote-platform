# Migration notes: GitLab CI to GitHub Actions

`.github/workflows/ci.yml` replaces `ci/legacy.gitlab-ci.yml`: same stages, none of the legacy practices.

PRs and pushes to main run `test` (gofmt, `go vet`, `go test -race`), `sast` (Semgrep) and `chart` (`helm lint`, kubeconform). On main, once all three pass, `build` scans, pushes and signs the image, `toolbox` does the same when `toolbox/` changed, and `deploy-bump` commits the new tags for ArgoCD to deploy.

## What changed and why

| Legacy | Now | Why |
|---|---|---|
| AWS keys in `variables:` | Removed (OIDC if AWS is ever needed) | Unused. OIDC stores no keys. |
| `sonar_check` with `allow_failure: true` | Semgrep `--error` | The old gate could never fail. |
| `npm test \|\| echo ...` on `node:16` | `go vet`, `go test -race` | `\|\| echo` forced exit 0. Node 16 is end of life. |
| `only: master` | Checks on PRs, publish on main | Code was checked after merge. |
| dind, `docker login -p` | buildx, `docker/login-action` with `GITHUB_TOKEN` | No privileged runner, no password in the process list. |
| `:latest` only | Full git SHA tag, multi-arch, signed by digest | `latest` is mutable: no audit, no rollback. |
| `kubectl set image` with `$KUBECONFIG_CONTENT` | `deploy-bump` commit, ArgoCD syncs | No cluster credentials in CI. Rollback is `git revert`. |
| `bitnami/kubectl:1.24` | Removed | Tag returns 404; 1.24 is unsupported. |
| `when: manual` | Automatic bump | A reviewer gate deadlocks a one-person repo. Production would add one. |
| Floating versions | Actions pinned to SHAs, images to `tag@digest`, Dependabot with 7-day cooldown | Tags move. |
| No image scan | Trivy fails on fixable HIGH or CRITICAL | Vulnerable images never reach the registry. |

**Why SHA pins.** On 2026-03-19, 76 of 77 `aquasecurity/trivy-action` tags were force-pushed to credential-stealing code ([GHSA-69fq-xp46-6x23](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23)). Pins to a commit after 2025-04-09 were safe; older SHA pins still pulled the hijacked `setup-trivy`.

**Notes**
- The legacy copy in `ci/` has its example AWS keys replaced by `<redacted>`, since scanners match on shape.
- Semgrep's `math/rand` finding is suppressed inline with a reason (it picks a quote, not a secret). That is auditable; `allow_failure` hid everything.
- A push with `GITHUB_TOKEN` starts no new run, so `deploy-bump` cannot loop. Under a branch ruleset it needs a GitHub App token with bypass rights.
- New GHCR packages are documented as private by default, but both packages here are linked to this public repo and came out public (`gh api /users/QuagHug/packages/container/quote-api --jq .visibility` returns `public`).

```sh
cosign verify ghcr.io/quaghug/quote-api@sha256:<digest> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/QuagHug/quote-platform/.github/workflows/ci.yml@refs/heads/main$'
```

## Migrating GitLab CI variables and secrets

1. **Inventory** project, group and instance variables via the API, with their protected, masked and scope flags.
2. **Delete what has a better replacement:** AWS keys to OIDC, `CI_REGISTRY_*` to `GITHUB_TOKEN`, `KUBECONFIG_CONTENT` to ArgoCD.
3. **Map the rest:** config to `vars.*`, secrets to repository secrets, protected values to a `production` environment with required reviewers, group values to organization secrets. Set them from stdin (`gh secret set NAME --env production < file`).
4. **Rotate** everything that lived in GitLab. Masking only hid logs.
5. **Turn on** secret scanning and push protection.
