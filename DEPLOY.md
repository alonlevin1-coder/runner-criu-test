# Deployment vs feature releases

Two private GitHub repos (or two roles in one org). Jobs never clone feature **source**.

| Role | Contains | GitHub |
| --- | --- | --- |
| **Deployment** | This folder: `action.yml`, TAP/CRIU scripts, appliance pins | Thin repo *or* `uses: ./github_hosted` from a checkout of only this action |
| **Features** | `proxy_implementation`, later `aws_credential_hook`, eBPF | Releases tagged `proxy-v*`, `hook-v*`, … |

## Local / monorepo (default)

If `github_hosted/../proxy_implementation` exists, `T9_COMPONENT_SOURCE=auto` **builds** (`go build`). No download.

## Hosted job (decoupled)

```yaml
- uses: org/github-hosted-action@v1   # deployment repo, composite step
  with:
    component-source: release
    components-repo: org/runner_idea    # feature-release repo (private OK)
    proxy-release: proxy-v0.1.0
    components-token: ${{ secrets.FEATURES_READ_TOKEN }}  # PAT: contents:read on feature repo
```

If both live in the **same** private repo, `github.token` is enough and `components-token` can be omitted.

Publish binaries (from the feature repo):

```bash
git tag proxy-v0.1.0 && git push origin proxy-v0.1.0
```

That runs `.github/workflows/release-proxy.yml` and uploads `proxy_core`, `t9-ca-inject`, `SHA256SUMS`.
