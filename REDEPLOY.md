# Redeploy CRC from nightly GHCR

After [Nightly rebase and rebuild](https://github.com/shanemcd/openshell-kubevirt/actions/workflows/nightly-rebuild.yml) is green, use the published OCI images on CRC (MicroShift).

## Deployment shape (keep the host gateway)

| Stack | Role |
|-------|------|
| Host `openshell-ts` → local podman `openshell-gateway` (`:17670`) | **Daily driver** — leave running; do **not** replace or mask |
| CRC/MicroShift `openshell` STS + `agent-sandbox-controller` | **KubeVirt / Hermes verify** — pin from GHCR nightlies |
| Host CLI | Default stays `openshell-ts`. For CRC work use `OPENSHELL_GATEWAY=crc` or the [`scripts/openshell-kubevirt`](./scripts/openshell-kubevirt) wrapper |

Do **not** point CRC Hermes work at local `openshell-driver-kubevirt` (bypasses Sandbox CR). Mask **only** that unit if it is enabled:

```bash
systemctl --user stop openshell-driver-kubevirt.service 2>/dev/null || true
systemctl --user mask openshell-driver-kubevirt.service
# Keep openshell-gateway.service running for openshell-ts
```

### Host CLI isolation

```bash
# Preferred for CRC sessions (does not change the default gateway):
export OPENSHELL_GATEWAY=crc
unset OPENSHELL_GATEWAY_ENDPOINT

# Or install a dedicated binary name:
#   ln -sf "$PWD/scripts/openshell-kubevirt" ~/.local/bin/openshell-kubevirt
#   openshell-kubevirt gateway info
```

Register the CRC gateway once (mTLS client certs must already match the in-cluster server CA — typically from the Helm/`openshell-client-tls` material). Endpoint is the OpenShift Route, **TLS passthrough**:

```bash
# Ensure a passthrough Route exists (CRC MicroShift often uses apps.crc.testing):
oc -n openshell get route openshell 2>/dev/null || \
  oc -n openshell create route passthrough openshell --service=openshell --port=grpc

oc -n openshell get route openshell -o jsonpath='{.spec.host}{"\n"}'
# Example: openshell-openshell.apps.crc.testing

openshell gateway add --name crc --remote "$(whoami)@127.0.0.1" \
  "https://openshell-openshell.apps.crc.testing"
# Adjust host to match `oc get route`. If mTLS files already live under
# ~/.config/openshell/gateways/crc/mtls/, prefer re-using that registration over
# re-adding.
```

After regenerating `openshell-server-tls` (e.g. to add the Route SAN), re-seed client material from the **same** CA into `openshell-client-tls` (gateway + `default` mirror) and `~/.config/openshell/gateways/crc/mtls/`. A stale client CA produces `BadSignature` / handshake failures even when the Route host is correct.

Never set `OPENSHELL_GATEWAY_ENDPOINT` for CRC Hermes — it overrides gateway metadata and historically pointed at the host kubevirt driver.

## Artifact map

| GHCR image | CRC use |
|------------|---------|
| `ghcr.io/shanemcd/agent-sandbox-controller:nightly` | Deploy `agent-sandbox-system/agent-sandbox-controller` |
| `ghcr.io/shanemcd/openshell-gateway:nightly` | STS `openshell/openshell` |
| `ghcr.io/shanemcd/openshell-supervisor:nightly` | Intermediate only (baked into bootc) |
| `ghcr.io/shanemcd/nemoclaw-hermes:nightly` | Intermediate only (baked into nemoclaw bootc) |
| `ghcr.io/shanemcd/hermes-sandbox-bootc:nightly` | NemoClaw variant OS image (input to containerDisk) |
| `ghcr.io/shanemcd/hermes-sandbox-kubevirt:nightly` | NemoClaw containerDisk (variant testing) |
| `ghcr.io/shanemcd/hermes-minimal-bootc:nightly` | Hermes-minimal OS image (no NemoClaw) |
| `ghcr.io/shanemcd/hermes-minimal-kubevirt:nightly` | Minimal containerDisk (variant testing) |
| `ghcr.io/shanemcd/hermes-site-kubevirt:nightly` | **Preferred CRC site guest** (toolbox layers on hermes-minimal bootc) |

Tags also include `YYYYMMDD` and `sha-<short>`. Prefer **digest** pins over moving tags.

For CRC site verify (toolbox layers: `jirahhh`, `gh`, guest docs), prefer **`hermes-site-kubevirt`**. Use nemoclaw/minimal disks only when testing those variants.

## 1. Controller + gateway (script)

Pin **in-cluster** images only — this does not touch the host podman gateway.

```bash
export KUBECONFIG=~/.crc/machines/crc/kubeconfig
./scripts/pin-crc-from-ghcr.sh
# or pin a date tag:
TAG=20260813 ./scripts/pin-crc-from-ghcr.sh
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

CRC pulls `ghcr.io/shanemcd/…` digests directly (no internal-registry copy). The same script pins **both** the gateway and the patched agent-sandbox controller (nightly builds of `vm-runtime-backend` / `kubevirt-backend`).

After controller rollout, keep optional KubeVirt RBAC bound (from an agent-sandbox checkout):

```bash
kubectl apply -f k8s/kubevirt-rbac.generated.yaml -f k8s/kubevirt.yaml
```

## 2. Hermes VM / containerDisk

Nightly publishes:

| Image | Use |
|-------|-----|
| `ghcr.io/shanemcd/hermes-site-kubevirt:nightly` | **Preferred CRC site guest** (toolbox layers on hermes-minimal bootc) |
| `ghcr.io/shanemcd/hermes-sandbox-kubevirt:nightly` | NemoClaw guest (public nemoclaw guest) |
| `ghcr.io/shanemcd/hermes-minimal-kubevirt:nightly` | Hermes-minimal guest (no config seals / MCP integrity) |

```bash
# Site (preferred for CRC verify):
DISK_DIG=$(crane digest ghcr.io/shanemcd/hermes-site-kubevirt:nightly)
IMAGE="ghcr.io/shanemcd/hermes-site-kubevirt@${DISK_DIG}"

# Alternatives:
# DISK_DIG=$(crane digest ghcr.io/shanemcd/hermes-sandbox-kubevirt:nightly)
# DISK_DIG=$(crane digest ghcr.io/shanemcd/hermes-minimal-kubevirt:nightly)
# IMAGE="ghcr.io/shanemcd/hermes-sandbox-kubevirt@${DISK_DIG}"
```

`--from` must be a **containerDisk** (`*-kubevirt`), not a bootc OCI (`*-bootc`).

### 2-create. Fresh site sandbox (no existing Hermes)

Policy lives in public [`shanemcd/toolbox`](https://github.com/shanemcd/toolbox) `openshell-kubevirt/policy.yaml`. If create fails policy validation on Slack hosts (`*.slack.com` websocket overlapping `files.slack.com` rest), drop the specific `files.slack.com` entry for that create (or fix upstream in toolbox).

When TopoLVM / dynamic provisioning cannot bind a workspace claim, create a static hostpath PV/PVC first and pass it through (see §5):

```bash
# --workspace-pvc workspace-hermes-kv-proof
# or: --driver-config-json '{"kubernetes":{"workspace_pvc":"workspace-hermes-kv-proof"}}'
```

```bash
export OPENSHELL_GATEWAY=crc   # or: openshell-kubevirt …
unset OPENSHELL_GATEWAY_ENDPOINT

POLICY="${TOOLBOX:-$HOME/github/shanemcd/toolbox}/openshell-kubevirt/policy.yaml"

openshell sandbox create \
  --name hermes \
  --from "$IMAGE" \
  --policy "$POLICY" \
  --provider vertex-prod --provider slack --provider github \
  --provider atlassian --provider gws --provider gitlab \
  -- /usr/local/bin/nemoclaw-start-vm

for p in github slack vertex-prod atlassian gws gitlab; do
  openshell sandbox provider attach hermes "$p" 2>/dev/null || true
done
openshell sandbox provider list hermes
```

Use a throwaway name (e.g. `hermes-kv-proof`) if you want to avoid colliding with a restored `hermes` PVC/backup. If create omits `--provider`, attach via §3 after Ready.

### 2a. Upgrade disk in place (keep `/sandbox` data) — preferred when Hermes already exists

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

### 2c. Grow workspace PVC (clone + named claim passthrough)

CRC hostpath does **not** support CSI volume expansion. To grow Hermes `/sandbox`:

1. **Stop** the VM (`virtctl stop hermes`) and scale down `agent-sandbox-controller` so it does not auto-resume.
2. Create a larger claim (e.g. `workspace-hermes-20gi`, 20Gi, same StorageClass).
3. **Rsync** old→new via a Job that mounts both PVCs. On KubeVirt filesystem PVCs the payload is `disk.img` — after copy, `qemu-img resize … 20G` and offline `resize2fs` (privileged Job). Keep the old PVC as backup until verified.
4. Deploy a controller that syncs named PVC claimNames (`syncVMPersistentVolumeClaims` on `kubevirt-backend`).
5. **Patch** Sandbox `hermes`: remove `volumeClaimTemplates`; set `podTemplate.spec.volumes[].persistentVolumeClaim.claimName: workspace-hermes-20gi` with mount `workspace` → `/sandbox`.
6. Scale the controller back up (it patches the VM claimName, then sets `running=true`). Confirm guest `df -h /sandbox` ≈ 20G and `.hermes/` present.

**New creates** with an existing claim (gateway must include the OpenShell `--workspace-pvc` support):

```bash
openshell sandbox create --name hermes --workspace-pvc workspace-hermes-20gi --from "$IMAGE" ...
# equivalent driver_config:
# --driver-config-json '{"kubernetes":{"workspace_pvc":"workspace-hermes-20gi"}}'
```

That omits VCT and emits the PVC volume + `/sandbox` mount. Sandbox delete does **not** delete a passthrough claim.

**Live cutover** without recreate: patch Sandbox claimName as above; controller syncs the VM volume; restart/start the VMI.

## 3. After every Hermes create / recreate — attach providers

Provider links are **per-sandbox** and are wiped on **delete/recreate**. Inference can still work via the OpenShell inference bundle without an attach, but GitHub/Slack/Atlassian env rewrite will not. In-place disk upgrades (§2a) do **not** clear attaches.

Always attach the full CRC site set (skip `discord` — image disables that platform):

```bash
export OPENSHELL_GATEWAY=crc   # or: openshell-kubevirt …
unset OPENSHELL_GATEWAY_ENDPOINT

for p in github slack vertex-prod atlassian gws gitlab; do
  openshell sandbox provider attach hermes "$p"
done
openshell sandbox provider list hermes
```

Prefer the same set on create (`--provider …` as in §2-create), then still run `provider list` and attach any that are missing.

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
export OPENSHELL_GATEWAY=crc   # or: openshell-kubevirt …
unset OPENSHELL_GATEWAY_ENDPOINT

openshell gateway info
openshell sandbox list
openshell sandbox provider list hermes
# expect: github, slack, vertex-prod, atlassian, gws, gitlab
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

CLI form (combined mode): `openshell sandbox exec whoami` — sandbox name is `-n` / last-used, **not** a positional before the command (`exec hermes whoami` runs `hermes` as the remote argv[0]).

## 5. CRC create gotchas (2026-08-13)

Hit while bringing up `hermes-kv-proof` / `hermes-site-kubevirt` on MicroShift:

### SA token Secret name mismatch → stuck `Provisioning`

OpenShell’s k8s VM path mounts Secret `{sandboxName}-openshell-sa-token` (e.g. `hermes-kv-proof-openshell-sa-token`). agent-sandbox names the Sandbox CR `default--{sandboxName}` and mints `default--{sandboxName}-openshell-sa-token`. If those diverge, the guest presents a stale/wrong BoundServiceAccountToken; gateway logs show `IssueSandboxToken` TokenReview failures (`pod UID … does not match service account pod ref claim`) and the CLI stays on **Provisioning** even when the VMI is Running.

**Workaround until fixed upstream:** keep the VM-mounted Secret’s `token` key identical to the controller-managed Secret (patch on mint/refresh), then `virtctl restart` so the guest remounts. A one-shot alias is not enough — the controller refreshes when the bootstrap Pod UID changes.

**Real fix:** align OpenShell `secretName` with the Sandbox CR name prefix (`default--…`) or teach the controller to use the short name the driver emits.

### Static hostpath workspace + QEMU `Permission denied`

When TopoLVM cannot schedule (`node(s) did not have enough free storage`), use a manual `hostPath` PV/PVC and `--workspace-pvc` / `kubernetes.workspace_pvc`. KubeVirt writes `disk.img` under the hostpath; QEMU in the virt-launcher must be able to open it. Match a working virt-test volume: owner `107:107`, mode `666`, SELinux `container_file_t` on the `disk.img` (and parent dirs as needed). Wrong perms → VMI crash / `Permission denied` on the workspace disk.

### mTLS / Route

Prefer the passthrough Route (`oc -n openshell get route openshell` — on this seat often `openshell-openshell.apps.crc.testing`, not `apps-crc.testing`). After any server-cert regen, client CA must match (see gateway registration above).

### Policy + providers

- Toolbox Slack policy: `*.slack.com` + `files.slack.com` can fail OpenShell policy validation — strip the specific host for create.
- Create **without** `--provider` leaves an empty attach set; run §3 after Ready.

## Notes

- The VM generates a new SSH host key on every restart, so `known_hosts` entries go stale. Always pass `-oUserKnownHostsFile=/dev/null` (alongside `-oStrictHostKeyChecking=no`) to `virtctl ssh` to avoid "REMOTE HOST IDENTIFICATION HAS CHANGED" errors.
- Nightly **gateway** is distroless (zigbuild + `bundled-z3`). That is the intended cluster image.
- Keep host `openshell-gateway.service` running for `openshell-ts`. Mask **only** `openshell-driver-kubevirt` so CRC creates go through the Sandbox CR.
- Do not use local `tot` / kubevirt-driver endpoints or `OPENSHELL_GATEWAY_ENDPOINT` for CRC Hermes work — use gateway name `crc` or [`scripts/openshell-kubevirt`](./scripts/openshell-kubevirt).
- Tag-only `rollout restart` can leave pods on an old digest; always pin the image to a GHCR digest (`crane digest …:nightly` or `./scripts/pin-crc-from-ghcr.sh`).
