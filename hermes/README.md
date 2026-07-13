# Hermes bootc (KubeVirt guest)

Build context for `ghcr.io/shanemcd/hermes-sandbox-bootc`. Keep this image **lean**
(Hermes runtime, supervisor, podman, pandoc). Site CLIs (`gh`, `glab`, `gws`,
`jirahhh`, `oc`/`kubectl`, node/npm) live in
[`shanemcd/toolbox`](https://github.com/shanemcd/toolbox) `openshell-kubevirt/`.

Only files `COPY`d by `Containerfile.kubevirt` live here (plus `hermes.env.example` for CI).

```bash
cp -n hermes.env.example hermes.env
: > extra-ca-certs.pem
podman build \
  --build-arg OPENSHELL_SUPERVISOR_IMAGE=localhost/openshell-supervisor:kubevirt \
  -f Containerfile.kubevirt \
  -t localhost/hermes-sandbox-bootc:latest .
```

NemoClaw stage expects `localhost/nemoclaw-hermes:kubevirt` (or rewrite the `FROM` like CI does for GHCR).

## Supervisor modes (runtime switch)

| Mode | How | Hermes | Landlock |
|------|-----|--------|----------|
| **combined** (default) | `openshell-sandbox` `--mode network,process` | child of supervisor | yes |
| **network** | `openshell-sandbox` `--mode network` + `sandbox-workload` | sibling in sandbox netns | no |

```bash
# On the guest (root):
openshell-supervisor-mode status
openshell-supervisor-mode network    # split / no Landlock
openshell-supervisor-mode combined   # default Pod-like path
# Symlinked to /usr/local/sbin when the image is baked.

# Persist across recreate:
openshell sandbox create ... --env "SUPERVISOR_MODE=network"   # network
# omit SUPERVISOR_MODE for combined
```

Network mode forces Hermes through the OpenShell proxy by entering the sandbox
netns (`nsenter`), sourcing snapshotted `provider.env` + `/etc/sandbox/env`,
and trusting `/etc/openshell-tls/{ca-bundle,openshell-ca}.pem`.

L7 identity: network-only never spawns a process leaf, so the supervisor must
adopt the sibling workload PID. OpenShell (`vm-runtime-backend`) watches
`/run/openshell/entrypoint.pid` (written by `sandbox-workload-run.sh`) and uses
that PID as the `/proc/<pid>/net/tcp` anchor — the network leaf stays in the
host netns while Hermes is in the sandbox netns.

Boot: `openshell-sandbox` runs prep as `ExecStartPre` (writes
`/run/openshell/want-workload` when `SUPERVISOR_MODE=network`).
`sandbox-workload` is `WantedBy=openshell-sandbox` with `After=` +
`ConditionPathExists` on that gate — no path unit or scripted `systemctl start`.

Rootless podman: image enables linger for `sandbox` (`/var/lib/systemd/linger/sandbox`)
so `user@10001` provides `/run/user/10001` + session bus at boot.
`sandbox-workload-run.sh` sets `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`
after the uid drop context is prepared.
