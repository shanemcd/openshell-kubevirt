# openshell-kubevirt

Tracking and iteration repo for running **OpenShell + Hermes (NemoClaw)** on **KubeVirt** via **agent-sandbox** `runtimeBackend: VirtualMachine`.

This is intentionally a thin meta-repo: forks and product code stay in their upstreams; handoff notes, runbooks, and experiments live here.

## Start here

- **[`AGENT-SANDBOX-VM.md`](./AGENT-SANDBOX-VM.md)** — piece-by-piece demo of the agent-sandbox `VirtualMachine` backend only (metadata, PVCs, Secret disks, RBAC).
- **[`VM-HERMES-BLOCKER.md`](./VM-HERMES-BLOCKER.md)** — living CRC handoff for the full Hermes / OpenShell stack (branches, redeploy gotchas, next actions).
- **[`REDEPLOY.md`](./REDEPLOY.md)** — pin CRC controller/gateway from nightly GHCR; Hermes disk still needs qcow2 packaging.

## Related repos

| Repo | Fork branch |
|------|-------------|
| [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) → [shanemcd/agent-sandbox](https://github.com/shanemcd/agent-sandbox) | `kubevirt-backend` |
| [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) → [shanemcd/OpenShell](https://github.com/shanemcd/OpenShell) | `kubevirt-sidecar` |
| [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) → [shanemcd/NemoClaw](https://github.com/shanemcd/NemoClaw) | `kubevirt-sidecar` |
| [shanemcd/clankr](https://github.com/shanemcd/clankr) (Hermes bootc image) | `main` |

## Nightly CI

Workflow: [`.github/workflows/nightly-rebuild.yml`](.github/workflows/nightly-rebuild.yml)

- **Schedule:** 06:00 UTC daily
- **Manual:** Actions → *Nightly rebase and rebuild* → Run workflow
  - `rebase` (default on): rebase forks onto upstream `main` and force-push when clean; fail on conflicts
  - `push_images` (default on): build/push GHCR images

Rebases run in parallel for agent-sandbox, OpenShell, and NemoClaw. Image builds that can run in parallel do; `hermes-sandbox-bootc` waits on supervisor + nemoclaw-hermes.

Cross-repo git uses a GitHub App installation token (`actions/create-github-app-token`). GHCR push uses `GITHUB_TOKEN`.

### Required repo settings

| Kind | Name | Purpose |
|------|------|---------|
| Variable | `APP_CLIENT_ID` | GitHub App client ID |
| Secret | `APP_PRIVATE_KEY` | GitHub App private key (PEM) |

App permissions: **Contents: Read and write**. Install on `agent-sandbox`, `OpenShell`, and `NemoClaw`.

```bash
gh variable set APP_CLIENT_ID --repo shanemcd/openshell-kubevirt --body '<client-id>'
gh secret set APP_PRIVATE_KEY --repo shanemcd/openshell-kubevirt < /path/to/app.pem
```

### GHCR images (amd64)

| Image | Source |
|-------|--------|
| `ghcr.io/shanemcd/agent-sandbox-controller` | agent-sandbox `kubevirt-backend` |
| `ghcr.io/shanemcd/openshell-gateway` | OpenShell `kubevirt-sidecar` |
| `ghcr.io/shanemcd/openshell-supervisor` | OpenShell `kubevirt-sidecar` |
| `ghcr.io/shanemcd/nemoclaw-hermes` | NemoClaw `kubevirt-sidecar` |
| `ghcr.io/shanemcd/hermes-sandbox-bootc` | clankr `main` |

Tags: `nightly`, `YYYYMMDD`, `sha-<short>` (plus `kubevirt` on nemoclaw-hermes / openshell-supervisor).

**Not built here:** `hermes-sandbox-kubevirt` containerDisk (qcow2 via bootc-image-builder) — still CRC / Quay / privileged runner.

## Published images

- Nightly OCI layers: see **GHCR images** above
- Container disk (manual/CRC): [`quay.io/shanemcd/hermes-sandbox-kubevirt:latest`](https://quay.io/repository/shanemcd/hermes-sandbox-kubevirt)
