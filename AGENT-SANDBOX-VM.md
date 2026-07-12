# agent-sandbox VirtualMachine backend — piece-by-piece demo

> **Scope:** [`kubernetes-sigs/agent-sandbox`](https://github.com/kubernetes-sigs/agent-sandbox) only (fork branch [`kubevirt-backend`](https://github.com/shanemcd/agent-sandbox/tree/kubevirt-backend)). No OpenShell, Hermes, or NemoClaw. Use this to walk a reviewer through what the controller actually does when `runtimeBackend: VirtualMachine`.

---

## What you are demonstrating

agent-sandbox already models a **Sandbox** as a singleton workload with stable identity (name, Service, PVCs). The VirtualMachine backend reuses that same CR shape and swaps the child workload from a Pod to a KubeVirt `VirtualMachine`.

```mermaid
flowchart TB
  SB[Sandbox CR]
  SB --> PVC[PVCs from volumeClaimTemplates]
  SB --> META["Secret sandbox-meta<br/>keys: env, volumes.json"]
  SB --> BOOT["Pod {name}-openshell-bootstrap<br/>(optional OpenShell SA)"]
  SB --> SASEC["Secret {name}-openshell-sa-token"]
  SB --> VM[KubeVirt VirtualMachine]
  SB --> SVC[Service optional]
  BOOT --> SASEC
  META --> DISKMETA["virtio disk serial=sandboxmeta"]
  PVC --> DISKPVC["virtio disks serial=sanitized mount name"]
  SB --> SECRETS["Secret volumeMounts on containers[0]"]
  SECRETS --> DISKSEC["virtio Secret disks + volumes.json entries"]
  SASEC --> DISKSEC
  IMAGE["containers[0].image"] --> CD["containerDisk"]
  CD --> VM
  DISKMETA --> VM
  DISKPVC --> VM
  DISKSEC --> VM
```

The guest OS is responsible for mounting disks and applying `env` / `volumes.json`. The controller does **not** inject cloud-init userdata or run mount logic inside the VM.

---

## Piece 1 — Prerequisites

| Need | Why |
|------|-----|
| KubeVirt installed | Controller creates `VirtualMachine` / watches `VirtualMachineInstance` |
| Optional KubeVirt RBAC bound | Default ClusterRole is Pod-only (`kubevirt.io` is opt-in) |

Enable RBAC (pick one):

```bash
# From an agent-sandbox checkout (fork kubevirt-backend)
kubectl apply -f k8s/kubevirt-rbac.generated.yaml -f k8s/kubevirt.yaml

# Kind
KUBEVIRT=true make deploy-kind

# Helm
helm upgrade --install agent-sandbox ./helm \
  --namespace agent-sandbox-system --create-namespace \
  --set image.tag=<tag> \
  --set controller.kubevirt=true

# Release asset (when published)
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${VERSION}/kubevirt.yaml
```

Code pointers: `controllers/kubevirt/rbac.go` → ClusterRole `agent-sandbox-controller-kubevirt`.

---

## Piece 2 — Minimal Sandbox (containerDisk only)

`spec.runtimeBackend: VirtualMachine` tells the controller to create a VM instead of a Pod. The **first container image** becomes the KubeVirt `containerDisk` source. There is no separate “disk image” API field.

```yaml
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: demo-vm
spec:
  runtimeBackend: VirtualMachine
  podTemplate:
    spec:
      containers:
      - name: sandbox
        # Any OCI image that KubeVirt can use as a containerDisk
        # (qcow2 at /disk/... for custom disks; community containerdisks work for smoke tests)
        image: quay.io/containerdisks/fedora:latest
```

**What the controller creates**

| Object | Name / notes |
|--------|----------------|
| `VirtualMachine` | `demo-vm` (same name as Sandbox) |
| `Secret` | `demo-vm-meta` — keys `env`, `volumes.json` |
| virtio metadata disk | serial **`sandboxmeta`** (always; not listed in `volumes.json`) |
| containerDisk | from `containers[0].image` |

**Fixed VM sizing today (not API-tunable):** 2 CPU, `2048Mi` memory, pod network + masquerade.

**Status:** Sandbox `Ready` tracks VMI phase `Running`; `status.podIPs` comes from the VMI interface IP.

Verify:

```bash
kubectl get sandbox demo-vm -o wide
kubectl get vm,vmi demo-vm
kubectl get secret demo-vm-meta -o jsonpath='{.data}' | jq 'keys'
# Decode guest contract:
kubectl get secret demo-vm-meta -o jsonpath='{.data.env}' | base64 -d
kubectl get secret demo-vm-meta -o jsonpath='{.data.volumes\.json}' | base64 -d | jq .
```

---

## Piece 3 — Guest metadata contract (no cloud-init)

Implementation: `controllers/vm_metadata.go`.

### Secret `<sandboxName>-meta`

| Key | Format | Purpose |
|-----|--------|---------|
| `env` | `KEY=VALUE` lines (EnvironmentFile-style) | All container env from `podTemplate` |
| `volumes.json` | JSON array | How to find and mount PVC / Secret virtio disks |

### Attachment

- KubeVirt Secret volume → virtio disk with **fixed serial `sandboxmeta`**
- Guest discovers it at `/dev/disk/by-id/virtio-sandboxmeta` (typical)
- Guest should **copy** contents off the iso/disk into a writable path (do not leave `/etc/...` as a read-only iso mount if the guest OS uses SELinux)

### `volumes.json` shape

Metadata disk itself is **omitted**. Example after Piece 4 + Piece 5:

```json
[
  {
    "name": "data",
    "serial": "data",
    "mountPath": "/data",
    "source": "persistentVolumeClaim",
    "claimName": "data-demo-vm"
  },
  {
    "name": "tls",
    "serial": "tls",
    "mountPath": "/etc/tls",
    "source": "secret",
    "secretName": "demo-tls"
  }
]
```

| Field | Meaning |
|-------|---------|
| `name` | Volume / mount name from the PodTemplate |
| `serial` | Virtio serial (sanitized; ≤20 alphanumeric) |
| `mountPath` | Intended guest mount path from `volumeMounts` |
| `source` | `persistentVolumeClaim` or `secret` |
| `claimName` / `secretName` | Cluster object the disk was built from |

**Guest bootstrap sketch** (illustrative — not shipped by agent-sandbox):

```bash
# 1) Read metadata disk
mkdir -p /run/sandbox-meta
mount /dev/disk/by-id/virtio-sandboxmeta /run/sandbox-meta
cp /run/sandbox-meta/env /etc/sandbox/env
cp /run/sandbox-meta/volumes.json /etc/sandbox/volumes.json
umount /run/sandbox-meta

# 2) Mount each volumes.json entry by serial
#    /dev/disk/by-id/virtio-${serial} → mountPath
```

---

## Piece 4 — Persistent volumes (`volumeClaimTemplates`)

Same API as the Pod backend (StatefulSet-style). Controller always reconciles PVCs; the VM backend attaches **only** claims referenced by a `volumeMount` on **`containers[0]`**.

```yaml
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: demo-vm
spec:
  runtimeBackend: VirtualMachine
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 5Gi
  podTemplate:
    spec:
      containers:
      - name: sandbox
        image: quay.io/containerdisks/fedora:latest
        volumeMounts:
        - name: data
          mountPath: /data
```

| Cluster object | Name |
|----------------|------|
| PVC | `data-demo-vm` |
| virtio disk serial | `data` (sanitized from mount name) |
| `volumes.json` entry | `source: persistentVolumeClaim`, `claimName: data-demo-vm` |

Unreferenced templates still get a PVC but **no** virtio attachment.

---

## Piece 5 — Secret volumes as virtio disks

Mirror a Pod Secret mount: declare a `volumes[].secret` and a `volumeMount` on the first container. Controller attaches another Secret virtio disk and lists it in `volumes.json` (`source: secret`).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: demo-tls
type: Opaque
stringData:
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    ...
  tls.crt: |
    -----BEGIN CERTIFICATE-----
    ...
  tls.key: |
    -----BEGIN PRIVATE KEY-----
    ...
---
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: demo-vm
spec:
  runtimeBackend: VirtualMachine
  podTemplate:
    spec:
      volumes:
      - name: tls
        secret:
          secretName: demo-tls
      containers:
      - name: sandbox
        image: quay.io/containerdisks/fedora:latest
        env:
        - name: TLS_DIR
          value: /etc/tls
        volumeMounts:
        - name: tls
          mountPath: /etc/tls
```

| Cluster object | Name / notes |
|----------------|--------------|
| User Secret | `demo-tls` (you create it) |
| Meta Secret | `demo-vm-meta` (`env` includes `TLS_DIR=/etc/tls`) |
| virtio Secret disk | serial `tls` |
| `volumes.json` | `source: secret`, `secretName: demo-tls`, `mountPath: /etc/tls` |

**Not attached today:** ConfigMap, EmptyDir, projected volumes, mounts on containers other than `[0]`.

---

## Piece 5b — OpenShell SA token bootstrap (BoundObjectRef)

Pod sandboxes use a kubelet-projected SA token. VMs cannot, so when the Sandbox CR requests a Secret volume named `openshell-sa-token` (secret `{sandbox}-openshell-sa-token`), the controller:

1. Creates a companion Pod `{sandbox}-openshell-bootstrap` (pause image), Sandbox-owned, with `openshell.io/sandbox-id` and the same `serviceAccountName` as the template
2. Mints a `TokenRequest` (`audience: openshell-gateway`, BoundObjectRef → bootstrap Pod)
3. Writes the JWT into Secret `{sandbox}-openshell-sa-token` key `token`, refreshing before expiry
4. Attaches that Secret as a virtio disk (same path as Piece 5)

The guest mounts it at `/var/run/secrets/openshell/token` and calls `IssueSandboxToken` — including after reboot, when a static gateway JWT would have expired.

Implementation: `controllers/vm_openshell_bootstrap.go`. Requires the kubevirt ClusterRole rules for `serviceaccounts` get + `serviceaccounts/token` create.

---

## Piece 6 — Lifecycle (`operatingMode`)

| `spec.operatingMode` | KubeVirt effect |
|----------------------|-----------------|
| `Running` (default) | VM `spec.running: true` |
| `Suspended` | VM `spec.running: false` |

Same field as the Pod backend (Pod path scales/stops differently; VM path maps to KubeVirt run strategy).

```bash
kubectl patch sandbox demo-vm --type=merge -p '{"spec":{"operatingMode":"Suspended"}}'
kubectl get vm demo-vm -o jsonpath='{.spec.running}{"\n"}'
```

---

## Piece 7 — Disk layout on the VirtualMachine (order)

As built by `controllers/vm_backend.go`:

1. **containerdisk** — guest root disk from `containers[0].image`
2. **sandbox-meta** — Secret `<name>-meta`, serial `sandboxmeta`
3. **PVC disks** — from `volumeClaimTemplates` + first-container mounts
4. **Secret disks** — from Secret `volumeMount`s on the first container

```bash
kubectl get vm demo-vm -o jsonpath='{range .spec.template.spec.domain.devices.disks[*]}{.name}{" serial="}{.serial}{"\n"}{end}'
```

---

## Piece 8 — Same shape via SandboxTemplate (extensions)

If extensions are enabled, put `runtimeBackend: VirtualMachine` on the template. Claims / warm pools inherit the blueprint.

```yaml
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxTemplate
metadata:
  name: demo-vm-template
spec:
  runtimeBackend: VirtualMachine
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 5Gi
  podTemplate:
    spec:
      containers:
      - name: sandbox
        image: quay.io/containerdisks/fedora:latest
        volumeMounts:
        - name: data
          mountPath: /data
```

Core demo does **not** require extensions — a bare `Sandbox` is enough.

---

## Suggested live walkthrough (15 minutes)

1. Confirm KubeVirt + apply `kubevirt.yaml` RBAC.
2. Apply **Piece 2** → show `VirtualMachine` + `demo-vm-meta` Secret.
3. Decode `env` / `volumes.json` from the Secret.
4. Apply **Piece 4** (recreate or patch) → show PVC `data-demo-vm` + virtio serial on the VM.
5. Apply **Piece 5** → show second Secret disk + `volumes.json` `source: secret`.
6. Optional: console into the guest (depends on image) and `ls /dev/disk/by-id/virtio-*`.
7. Toggle **Piece 6** Suspended ↔ Running.

---

## Code map

| File | Role |
|------|------|
| `api/v1beta1/sandbox_types.go` | `RuntimeBackend`, `SandboxBlueprint` |
| `controllers/sandbox_controller.go` | Backend branch; shared PVC reconcile |
| `controllers/vm_backend.go` | Build/patch VM; map VMI → Sandbox status |
| `controllers/vm_metadata.go` | Meta Secret + `volumes.json` contract |
| `controllers/kubevirt/rbac.go` | Optional `kubevirt.io` RBAC markers |
| `k8s/kubevirt.yaml` + `kubevirt-rbac.generated.yaml` | Opt-in ClusterRoleBinding / ClusterRole |

---

## Current limitations (call out in the demo)

- VM CPU/memory/network are **hardcoded** in the controller (not CR fields yet).
- Only **first container** `image`, `env`, and `volumeMounts` feed the VM path.
- Guest must implement metadata + disk mounting; stock `quay.io/containerdisks/fedora` will boot but will **not** auto-mount `sandboxmeta` / PVC disks.
- No VirtualMachine examples under upstream `examples/` yet (this doc is the working demo script).
- Warm-pool blueprint comparison may not yet treat `runtimeBackend` as a roll-trigger — prefer a direct `Sandbox` for demos.

---

## Out of scope here

OpenShell drivers, Hermes bootc images, day-2 SSH via `virtctl credentials`, and CRC-specific deploy notes live in [`TRACKING.md`](./TRACKING.md). This document stops at what agent-sandbox owns.
