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
| `ghcr.io/shanemcd/nemoclaw-hermes:nightly` | Intermediate only (baked into nemoclaw bootc) |
| `ghcr.io/shanemcd/hermes-sandbox-bootc:nightly` | NemoClaw variant OS image (input to containerDisk) |
| `ghcr.io/shanemcd/hermes-sandbox-kubevirt:nightly` | Default Sandbox `containers[0].image` (nemoclaw containerDisk) |
| `ghcr.io/shanemcd/hermes-minimal-bootc:nightly` | Hermes-minimal OS image (no NemoClaw) |
| `ghcr.io/shanemcd/hermes-minimal-kubevirt:nightly` | Optional Sandbox image (minimal containerDisk) |
| `ghcr.io/shanemcd/hermes-site-kubevirt:nightly` | Site containerDisk (toolbox layers on hermes-minimal bootc) |

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

Nightly publishes:

| Image | Use |
|-------|-----|
| `ghcr.io/shanemcd/hermes-sandbox-kubevirt:nightly` | NemoClaw guest (public nemoclaw guest) |
| `ghcr.io/shanemcd/hermes-minimal-kubevirt:nightly` | Hermes-minimal guest (no config seals / MCP integrity) |
| `ghcr.io/shanemcd/hermes-site-kubevirt:nightly` | Site layers (`jirahhh`, `gh`, guest docs) on hermes-minimal bootc |

```bash
DISK_DIG=$(crane digest ghcr.io/shanemcd/hermes-sandbox-kubevirt:nightly)
# or minimal:
# DISK_DIG=$(crane digest ghcr.io/shanemcd/hermes-minimal-kubevirt:nightly)
# or site:
# DISK_DIG=$(crane digest ghcr.io/shanemcd/hermes-site-kubevirt:nightly)
IMAGE="ghcr.io/shanemcd/hermes-sandbox-kubevirt@${DISK_DIG}"
# IMAGE="ghcr.io/shanemcd/hermes-minimal-kubevirt@${DISK_DIG}"
```

Optional Quay mirror:

```bash
crane copy \
  "ghcr.io/shanemcd/hermes-sandbox-kubevirt@${DISK_DIG}" \
  quay.io/shanemcd/hermes-sandbox-kubevirt:latest
```

### 2a. Upgrade disk in place (keep `/sandbox` data) — preferred

Hermes agent state lives on PVC `workspace-hermes` mounted at `/sandbox`. That claim is owned by the Sandbox CR, so **`openshell sandbox delete` wipes it**. To change only the OS/containerDisk:

1. Patch the Sandbox image.
2. Wait for the controller to sync `VirtualMachine` `containerDisk.image` (agent-sandbox `kubevirt-backend` with containerDisk sync).
3. `virtctl restart` (or reboot the guest) so a new VMI boots the new disk. The controller does **not** auto-restart the VMI.

```bash
export KUBECONFIG=~/.crc/machines/crc/kubeconfig
NS=default
NAME=hermes
# IMAGE=...@sha256:...   # from crane digest above

oc -n "$NS" patch sandbox "$NAME" --type=json -p="[{
  \"op\":\"replace\",
  \"path\":\"/spec/podTemplate/spec/containers/0/image\",
  \"value\":\"${IMAGE}\"
}]"

# Controller should copy the image onto the VM; confirm before restart:
for i in $(seq 1 30); do
  img=$(oc -n "$NS" get vm "$NAME" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="containerdisk")].containerDisk.image}')
  [[ "$img" == "$IMAGE" ]] && break
  sleep 2
done
oc -n "$NS" get vm "$NAME" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="containerdisk")].containerDisk.image}{"\n"}'

virtctl restart "$NAME" -n "$NS"
```

**Older controllers** (before containerDisk sync on reconcile): also patch the VM volume directly — the Sandbox image field alone did not update an existing VM:

```bash
IDX=$(oc -n "$NS" get vm "$NAME" -o json | python3 -c '
import json,sys
vm=json.load(sys.stdin)
vols=vm["spec"]["template"]["spec"]["volumes"]
print(next(i for i,v in enumerate(vols) if v.get("name")=="containerdisk"))
')
oc -n "$NS" patch vm "$NAME" --type=json -p="[{
  \"op\":\"replace\",
  \"path\":\"/spec/template/spec/volumes/${IDX}/containerDisk/image\",
  \"value\":\"${IMAGE}\"
}]"
```

Verify after SSH is up:

```bash
# Same PVC (creationTimestamp / uid unchanged)
oc -n "$NS" get pvc workspace-hermes -o jsonpath='uid={.metadata.uid} created={.metadata.creationTimestamp}{"\n"}'

# Guest rootfs is the new image; /sandbox is still the PVC
virtctl ssh root@vmi/"$NAME" -n "$NS" -i ~/.ssh/id_rsa \
  --local-ssh-opts="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null" \
  --command='findmnt -n /sandbox; bootc status 2>/dev/null | head -20'
```

Notes:

- Site-only files copied into `/sandbox` in the image (e.g. `/sandbox/.config/jirahhh`) appear on **first** PVC seed only. An existing PVC keeps its tree; rootfs-only bits (`/opt/hermes/.../jirahhh`, `/usr/local/bin/gh`) still update with the disk.
- After restart, confirm `openshell-sandbox` + (if `SUPERVISOR_MODE=network`) `sandbox-workload` are active and Signal/Slack reconnect. Provider attaches survive in-place upgrades (they are gateway metadata keyed by sandbox name, not guest disk).
- Optionally pin gateway `default_image` in `openshell/openshell-config` to the same digest so the next **create** matches; that is separate from upgrading this VM.

### 2b. Recreate (wipes `/sandbox` unless you orphan the PVC)

```bash
# Destructive: Sandbox ownerRef deletes workspace-hermes
openshell sandbox delete hermes
openshell sandbox create --from "$IMAGE" --name hermes ...
# then §3 attach providers
```

To recreate the Sandbox CR but keep data, orphan the claim first (`remove ownerReferences`, label `agents.x-k8s.io/adoptable=true`), delete, recreate with the **same name** so the controller can adopt `workspace-<name>`. Prefer §2a when you only need a new guest OS.

## 3. After every Hermes create / recreate — attach providers

Provider links are **per-sandbox** and are wiped on **delete/recreate**. Inference can still work via the OpenShell inference bundle without an attach, but GitHub/Slack/Atlassian env rewrite will not. In-place disk upgrades (§2a) do **not** clear attaches.

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
virtctl ssh root@vmi/hermes -n default -i ~/.ssh/id_rsa \
  --local-ssh-opts="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null" \
  --command='openshell-supervisor-mode network'   # or: combined
```

Do **not** set `SUPERVISOR_MODE=network` without `sandbox-workload` — Hermes will not start and `exec` will hang.

Guest entrypoint is `/usr/local/bin/sandbox-entrypoint` (symlink to `nemoclaw-start-vm` or `hermes-start.sh` depending on the image). Gateway `sandbox_command` / create `--env OPENSHELL_SANDBOX_COMMAND=…` can override; prefer leaving it empty so the image owns the default.

## 4. Smoke

```bash
openshell gateway info
openshell sandbox list
openshell sandbox provider list hermes   # expect: github, slack, vertex-prod, atlassian
```

`openshell sandbox exec` only works when the supervisor runs in **combined** mode (`--mode network,process`). In **network-only** mode the supervisor does not proxy process execution, so use `virtctl ssh` instead:

```bash
# combined mode:
openshell sandbox exec whoami   # expect: sandbox

# network-only mode:
virtctl ssh root@vmi/hermes -n default -i ~/.ssh/id_rsa \
  --local-ssh-opts="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null" \
  --command='whoami'   # expect: root
```

Also confirm Slack / Signal / inference after an in-place disk restart or recreate.

## Notes

- The VM generates a new SSH host key on every restart, so `known_hosts` entries go stale. Always pass `-oUserKnownHostsFile=/dev/null` (alongside `-oStrictHostKeyChecking=no`) to `virtctl ssh` to avoid "REMOTE HOST IDENTIFICATION HAS CHANGED" errors.
- Nightly **gateway** is distroless (zigbuild + `bundled-z3`). Live CRC previously used a Fedora 44 wrapper for toolbox builds; distroless is the intended cluster image. If the STS fails after switch, mirror/binary-wrap as before.
- Do not use local `tot` quadlets or `OPENSHELL_GATEWAY_ENDPOINT` for CRC Hermes work.
- Tag-only `rollout restart` can leave pods on an old digest; always set the image to a digest (or a fresh ImageStream digest).
