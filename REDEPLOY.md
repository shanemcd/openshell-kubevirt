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
| `ghcr.io/shanemcd/hermes-sandbox-bootc:nightly` | Bootc OS image — **not** a Sandbox disk |

Tags also include `YYYYMMDD` and `sha-<short>`. Prefer **digest** pins over moving tags.

**Not published by nightly:** `hermes-sandbox-kubevirt` containerDisk (qcow2). That still needs bootc-image-builder → disk package → CRC IS / Quay.

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

If CRC cannot pull GHCR, mirror into the OpenShift registry first, then pin to that ImageStream digest (same idea as the old `istag` flow in [`VM-HERMES-BLOCKER.md`](./VM-HERMES-BLOCKER.md)).

After controller rollout, keep optional KubeVirt RBAC bound (from an agent-sandbox checkout):

```bash
kubectl apply -f k8s/kubevirt-rbac.generated.yaml -f k8s/kubevirt.yaml
```

## 2. Hermes VM / containerDisk

Nightly stops at `hermes-sandbox-bootc`. To refresh the guest disk:

1. Pull `ghcr.io/shanemcd/hermes-sandbox-bootc:nightly`
2. Run bootc-image-builder (privileged CRC job / self-hosted) → qcow2
3. Repackage as containerDisk (`COPY … /disk/….qcow2`) → push CRC `openshell-sandboxes/hermes-sandbox-kubevirt` and/or Quay
4. Recreate the sandbox with that image (`OPENSHELL_GATEWAY=crc`)

Until that pipeline is automated, keep using Quay/CRC `hermes-sandbox-kubevirt` for creates.

## 3. Smoke

```bash
openshell gateway info
openshell sandbox list
openshell sandbox exec whoami   # expect: sandbox
```

Also confirm Slack / inference if you recreated the Hermes VM.

## Notes

- Nightly **gateway** is distroless (zigbuild + `bundled-z3`). Live CRC previously used a Fedora 44 wrapper for toolbox builds; distroless is the intended cluster image. If the STS fails after switch, mirror/binary-wrap as before.
- Do not use local `tot` quadlets or `OPENSHELL_GATEWAY_ENDPOINT` for CRC Hermes work.
- Tag-only `rollout restart` can leave pods on an old digest; always set the image to a digest (or a fresh ImageStream digest).
