# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

This is a tracking, iteration, and integration repo for running **Hermes Agent** inside a **KubeVirt VirtualMachine** via the **agent-sandbox** Kubernetes controller and **NVIDIA OpenShell** as the sandbox gateway/supervisor.

There is no compiled application here. The repo contains:
- A **bootc guest image build context** (`images/hermes/`) with two Containerfile variants, shared systemd units, and bootstrap scripts
- **CI/CD** (nightly GitHub Actions workflow) that rebases fork branches onto upstream, builds OCI images, and publishes containerDisk images to GHCR
- **Operational runbooks** (`REDEPLOY.md`, `TRACKING.md`) and deployment scripts (`scripts/`, `signal/`)
- An **OpenShell sandbox policy** (`images/hermes/policy.yaml`) defining network egress and filesystem rules

Work happens across forks (branches `kubevirt-backend` / `vm-runtime-backend`): `kubernetes-sigs/agent-sandbox`, `NVIDIA/OpenShell`, and `NVIDIA/NemoClaw`.

Guest variants (see [`images/hermes/README.md`](./images/hermes/README.md)):
- **nemoclaw** (`Containerfile.nemoclaw`) → `hermes-sandbox-bootc` / `hermes-sandbox-kubevirt` (default + site base)
- **hermes-minimal** (`Containerfile.minimal`) → `hermes-minimal-bootc` / `hermes-minimal-kubevirt` (no NemoClaw)

Both symlink `/usr/local/bin/sandbox-entrypoint` to the variant workload.

## Building the Hermes bootc image

Prerequisite: `localhost/openshell-supervisor:kubevirt` (or a GHCR supervisor tag). Nemoclaw also needs `localhost/nemoclaw-hermes:kubevirt`.

```bash
cd images/hermes/
cp -n hermes.env.example hermes.env
: > extra-ca-certs.pem

# NemoClaw variant (default GHCR names)
podman build \
  --build-arg OPENSHELL_SUPERVISOR_IMAGE=localhost/openshell-supervisor:kubevirt \
  -f Containerfile.nemoclaw \
  -t localhost/hermes-sandbox-bootc:latest .

# Minimal variant (Hermes from pinned NousResearch tarball)
podman build \
  --build-arg OPENSHELL_SUPERVISOR_IMAGE=localhost/openshell-supervisor:kubevirt \
  -f Containerfile.minimal \
  -t localhost/hermes-minimal-bootc:latest .
```

Bootc → qcow2 containerDisk via `bootc-image-builder` (CI or manually). Final image is `FROM scratch` with `/disk/fedora.qcow2`.

## Testing

No automated test suite. Testing is manual against a CRC (CodeReady Containers) cluster:

```bash
openshell gateway info
openshell sandbox list
openshell sandbox exec whoami        # expect: sandbox (combined mode only)
openshell sandbox provider list hermes   # expect: github, slack, vertex-prod, atlassian
```

## CI/CD

Single workflow: `.github/workflows/nightly-rebuild.yml` (06:00 UTC daily or manual dispatch).

The pipeline rebases forks onto upstream, builds OCI images across repos, and pushes to GHCR. Cross-repo git uses a GitHub App installation token. Key jobs: rebase agent-sandbox + OpenShell + NemoClaw; build controller/gateway/supervisor/`nemoclaw-hermes`; build both bootc variants; convert each to containerDisk; layer site Hermes on the nemoclaw bootc.

Required repo settings: variable `APP_CLIENT_ID`, secret `APP_PRIVATE_KEY`.

## CRC deployment

Use `./scripts/pin-crc-from-ghcr.sh` to pin controller + gateway to nightly digests. For Hermes VM disk upgrades, prefer in-place patching (keeps PVC data) over delete/recreate. Full procedure in `REDEPLOY.md`.

## Architecture: guest boot sequence

The bootc VM boots through three systemd services in order:

1. **`sandbox-volumes.service`** (`prepare-sandbox-volumes.sh`): mounts virtio metadata disk, PVC disks (mkfs if blank), Secret disks, and virtiofs shares; handles SELinux relabeling
2. **`openshell-sandbox.service`**: OpenShell supervisor (`--mode network,process` or `--mode network`)
3. **`sandbox-workload.service`** (when `SUPERVISOR_MODE=network`): nsenter into sandbox netns and exec `sandbox-entrypoint`

Shared scripts live under `/usr/local/lib/openshell/`. Variant-specific bits are only what each Containerfile installs under `/opt/hermes`, `/usr/local/bin/*`, and `/sandbox/.hermes`.
