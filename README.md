# openshell-kubevirt

Tracking and iteration repo for running **OpenShell + Hermes (NemoClaw)** on **KubeVirt** via **agent-sandbox** `runtimeBackend: VirtualMachine`.

This is intentionally a thin meta-repo: forks and product code stay in their upstreams; handoff notes, runbooks, and experiments live here.

## Start here

- **[`AGENT-SANDBOX-VM.md`](./AGENT-SANDBOX-VM.md)** — piece-by-piece demo of the agent-sandbox `VirtualMachine` backend only (metadata, PVCs, Secret disks, RBAC).
- **[`VM-HERMES-BLOCKER.md`](./VM-HERMES-BLOCKER.md)** — living CRC handoff for the full Hermes / OpenShell stack (branches, redeploy gotchas, next actions).

## Related repos

| Repo | Fork branch |
|------|-------------|
| [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) → [shanemcd/agent-sandbox](https://github.com/shanemcd/agent-sandbox) | `kubevirt-backend` |
| [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) → [shanemcd/OpenShell](https://github.com/shanemcd/OpenShell) | `kubevirt-sidecar` |
| [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) → [shanemcd/NemoClaw](https://github.com/shanemcd/NemoClaw) | `kubevirt-sidecar` |
| [shanemcd/clankr](https://github.com/shanemcd/clankr) (Hermes bootc image) | `main` |

## Published images

- Container disk: [`quay.io/shanemcd/hermes-sandbox-kubevirt:latest`](https://quay.io/repository/shanemcd/hermes-sandbox-kubevirt)
