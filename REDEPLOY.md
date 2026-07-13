# Redeploy CRC from nightly GHCR

After [Nightly rebase and rebuild](https://github.com/shanemcd/openshell-kubevirt/actions/workflows/nightly-rebuild.yml) is green, use the published OCI images on CRC.

Always talk to the in-cluster gateway:

```bash
export OPENSHELL_GATEWAY=crc
unset OPENSHELL_GATEWAY_ENDPOINT
```

## Artifact map

| GHCR image | CRC use |
|------------|---------|
| `ghcr.io/shanemcd/agent-sandbox-controller:nightly` | Deploy `agent-sandbox-system/agent-sandbox-controller` |
| `ghcr.io/shanemcd/openshell-gateway:nightly` | STS `openshell/openshell` |
| `ghcr.io/shanemcd/openshell-supervisor:nightly` | Intermediate only (baked into bootc) |
| `ghcr.io/shanemcd/nemoclaw-hermes:kubevirt` | Intermediate only (baked into bootc) |
| `ghcr.io/shanemcd/hermes-sandbox-bootc:nightly` | Intermediate bootc OS image (input to containerDisk) |
| `ghcr.io/shanemcd/hermes-sandbox-kubevirt:nightly` | Sandbox `containers[0].image` (KubeVirt containerDisk) |

Tags also include `YYYYMMDD` and `sha-<short>`. Prefer **digest** pins over moving tags.

## 1. Controller + gateway (script)

```bash
./scripts/pin-crc-from-ghcr.sh
# or pin a date tag:
TAG=20260712 ./scripts/pin-crc-from-ghcr.sh
```

Manual equivalent:

```bash
CTRL_DIG=$(crane digest ghcr.io/shanemcd/agent-sandbox-controller:nightly)
GW_DIG=$(crane digest ghcr.io/shanemcd/openshell-gateway:nightly)

oc -n agent-sandbox-system set image deploy/agent-sandbox-controller \
  "*=ghcr.io/shanemcd/agent-sandbox-controller@${CTRL_DIG}"

oc -n openshell patch sts openshell --type=json -p="[{
  \"op\":\"replace\",
  \"path\":\"/spec/template/spec/containers/0/image\",
  \"value\":\"ghcr.io/shanemcd/openshell-gateway@${GW_DIG}\"
}]"
oc -n openshell delete pod openshell-0 --wait=false
```

If CRC cannot pull GHCR, mirror into the OpenShift registry first, then pin to that ImageStream digest (same idea as the old `istag` flow in [`TRACKING.md`](./TRACKING.md)).

After controller rollout, keep optional KubeVirt RBAC bound (from an agent-sandbox checkout):

```bash
kubectl apply -f k8s/kubevirt-rbac.generated.yaml -f k8s/kubevirt.yaml
```

## 2. Hermes VM / containerDisk

Nightly publishes `ghcr.io/shanemcd/hermes-sandbox-kubevirt:nightly` (bootc-image-builder → `/disk/fedora.qcow2`).

```bash
DISK_DIG=$(crane digest ghcr.io/shanemcd/hermes-sandbox-kubevirt:nightly)
# Point Sandbox / create flow at:
#   ghcr.io/shanemcd/hermes-sandbox-kubevirt@${DISK_DIG}
# Or mirror into CRC ImageStream / Quay, then recreate:
#   export OPENSHELL_GATEWAY=crc
```

Optional Quay mirror:

```bash
crane copy \
  "ghcr.io/shanemcd/hermes-sandbox-kubevirt@${DISK_DIG}" \
  quay.io/shanemcd/hermes-sandbox-kubevirt:latest
```

## 3. After every Hermes create / recreate — attach providers

Provider links are **per-sandbox** and are wiped on delete/recreate. Inference can still work via the OpenShell inference bundle without an attach, but GitHub/Slack/Atlassian env rewrite will not.

Always attach the full CRC set (skip `discord` — image disables that platform):

```bash
for p in github slack vertex-prod atlassian; do
  openshell sandbox provider attach hermes "$p"
done
openshell sandbox provider list hermes
```

Prefer the same set on create when the CLI supports it (`--provider github --provider slack --provider vertex-prod --provider atlassian`), then still run `provider list` and attach any that are missing.

## 3b. Supervisor mode (combined vs network-only)

Default is **combined** (`network,process`). To run Hermes as a sibling without Landlock (network leaf + `sandbox-workload`):

```bash
# Persist on recreate:
openshell sandbox create ... --env "SUPERVISOR_MODE=network"

# Or on a live guest (root), after the mode scripts are baked/copied in:
virtctl ssh root@vmi/hermes -n default --local-ssh-opts='-oStrictHostKeyChecking=no' \
  --command='openshell-supervisor-mode network'   # or: combined
```

Do **not** set `SUPERVISOR_MODE=network` without `sandbox-workload` — Hermes will not start and `exec` will hang.

## 4. Smoke

```bash
openshell gateway info
openshell sandbox list
openshell sandbox exec whoami   # expect: sandbox
openshell sandbox provider list hermes   # expect: github, slack, vertex-prod, atlassian
```

Also confirm Slack / Signal / inference if you recreated the Hermes VM.

## Notes

- Nightly **gateway** is distroless (zigbuild + `bundled-z3`). Live CRC previously used a Fedora 44 wrapper for toolbox builds; distroless is the intended cluster image. If the STS fails after switch, mirror/binary-wrap as before.
- Do not use local `tot` quadlets or `OPENSHELL_GATEWAY_ENDPOINT` for CRC Hermes work.
- Tag-only `rollout restart` can leave pods on an old digest; always set the image to a digest (or a fresh ImageStream digest).
