# openshell-kubevirt

Tracking and iteration repo for running **OpenShell + Hermes (NemoClaw)** on **KubeVirt** via **agent-sandbox** `runtimeBackend: VirtualMachine`.

Forks and product code stay in their upstreams; handoff notes, runbooks, and the **Hermes bootc / KubeVirt guest image** (`hermes/`) live here.

## Start here

- **[`AGENT-SANDBOX-VM.md`](./AGENT-SANDBOX-VM.md)** — piece-by-piece demo of the agent-sandbox `VirtualMachine` backend only (metadata, PVCs, Secret disks, RBAC).
- **[`TRACKING.md`](./TRACKING.md)** — living CRC handoff for the full Hermes / OpenShell stack (branches, redeploy gotchas, next actions).
- **[`REDEPLOY.md`](./REDEPLOY.md)** — pin CRC controller/gateway (and Hermes containerDisk) from nightly GHCR.
- **[`hermes/`](./hermes/)** — `Containerfile.kubevirt` + guest bootstrap sources for the Hermes bootc / containerDisk images.
- **[`hermes/OPENSHELL-POLICY.md`](./hermes/OPENSHELL-POLICY.md)** — Hermes instructions: view/diagnose/update OpenShell policy entries.
- **[`signal/`](./signal/)** — in-cluster signal-cli for Hermes (`./signal/link.sh`).
- **[`kube-proxy/`](./kube-proxy/)** — cluster-admin `oc` for Hermes via in-cluster kubectl proxy (`./kube-proxy/setup.sh`; OpenShell blocks `:6443`).

## Related repos

| Repo | Fork branch |
|------|-------------|
| [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) → [shanemcd/agent-sandbox](https://github.com/shanemcd/agent-sandbox) | `kubevirt-backend` |
| [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) → [shanemcd/OpenShell](https://github.com/shanemcd/OpenShell) | `vm-runtime-backend` |
| [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) → [shanemcd/NemoClaw](https://github.com/shanemcd/NemoClaw) | `vm-runtime-backend` |

## Nightly CI

Workflow: [`.github/workflows/nightly-rebuild.yml`](.github/workflows/nightly-rebuild.yml)

- **Schedule:** 06:00 UTC daily
- **Manual:** Actions → *Nightly rebase and rebuild* → Run workflow
  - `rebase` (default on): rebase forks onto upstream `main` and force-push when clean; fail on conflicts
  - `push_images` (default on): build/push GHCR images
  - `build_container_disk` (default on): bootc-image-builder → `hermes-sandbox-kubevirt` containerDisk (long; needs privileged runner)

Rebases run in parallel for agent-sandbox, OpenShell, and NemoClaw. Image builds that can run in parallel do; `hermes-sandbox-bootc` waits on supervisor + nemoclaw-hermes; `hermes-sandbox-kubevirt` waits on bootc.

Cross-repo git uses a GitHub App installation token (`actions/create-github-app-token`). GHCR push uses `GITHUB_TOKEN`.

### Required repo settings

| Kind | Name | Purpose |
|------|------|---------|
| Variable | `APP_CLIENT_ID` | GitHub App client ID |
| Secret | `APP_PRIVATE_KEY` | GitHub App private key (PEM) |

App permissions: **Contents: Read and write**, **Workflows: Read and write** (needed when upstream rebases touch `.github/workflows/*`). Install on `agent-sandbox`, `OpenShell`, and `NemoClaw`.

```bash
gh variable set APP_CLIENT_ID --repo shanemcd/openshell-kubevirt --body '<client-id>'
gh secret set APP_PRIVATE_KEY --repo shanemcd/openshell-kubevirt < /path/to/app.pem
```

### GHCR images (amd64)

| Image | Source |
|-------|--------|
| `ghcr.io/shanemcd/agent-sandbox-controller` | agent-sandbox `kubevirt-backend` |
| `ghcr.io/shanemcd/openshell-gateway` | OpenShell `vm-runtime-backend` |
| `ghcr.io/shanemcd/openshell-supervisor` | OpenShell `vm-runtime-backend` |
| `ghcr.io/shanemcd/nemoclaw-hermes` | NemoClaw `vm-runtime-backend` |
| `ghcr.io/shanemcd/hermes-sandbox-bootc` | this repo [`hermes/`](./hermes/) |
| `ghcr.io/shanemcd/hermes-sandbox-kubevirt` | bootc → qcow2 containerDisk (`/disk/fedora.qcow2`) |

Tags: `nightly`, `YYYYMMDD`, `sha-<short>` (plus `kubevirt` on nemoclaw-hermes / openshell-supervisor).

## Published images

- Nightly OCI layers + containerDisk: see **GHCR images** above
- Quay mirror (optional): [`quay.io/shanemcd/hermes-sandbox-kubevirt:latest`](https://quay.io/repository/shanemcd/hermes-sandbox-kubevirt)
