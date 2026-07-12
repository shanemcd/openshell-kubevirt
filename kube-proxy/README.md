# Hermes kube API access (CRC)

Give the Hermes OpenShell sandbox **cluster-admin** `oc`/`kubectl` against CRC without fighting OpenShell’s control-plane SSRF guard.

## One command

```bash
export KUBECONFIG=~/.crc/machines/crc/kubeconfig
export OPENSHELL_GATEWAY=crc
unset OPENSHELL_GATEWAY_ENDPOINT

chmod +x kube-proxy/setup.sh
./kube-proxy/setup.sh
```

That will:

1. Apply [`hermes-kube-proxy.yaml`](./hermes-kube-proxy.yaml) (SA `hermes-admin` + `cluster-admin` + in-cluster `kubectl proxy`)
2. Apply the `kubernetes` rule from [`hermes/policy.yaml`](../hermes/policy.yaml)
3. Copy host `oc` → `/sandbox/.hermes/bin/oc` on the Hermes VMI
4. Write `/sandbox/.kube/config` aimed at the proxy Service
5. Add `PATH` / `KUBECONFIG` to Hermes `.env`, re-hash NemoClaw seals, restart `openshell-sandbox`
6. Verify `oc whoami` **inside** the OpenShell sandbox netns

Flags: `--skip-oc-copy`, `--no-restart`. Override VMI/sandbox with `HERMES_VMI`, `HERMES_SANDBOX`, `HERMES_NAMESPACE`.

## Why not dial the apiserver directly?

| Target | Result from Hermes sandbox |
|--------|----------------------------|
| `https://api.crc.testing:6443` | **DENIED** — OpenShell SSRF: *port 6443 is a blocked control-plane port* |
| `https://kubernetes.default.svc.cluster.local:443` | Policy can ALLOW, then **NET:FAIL** — upstream still lands on `:6443` |
| `http://hermes-kube-proxy.default.svc.cluster.local:8080` | **Works** — same pattern as in-cluster signal-cli |

So we front the API with `kubectl proxy` on **:8080**. Auth to the real apiserver is the proxy pod’s SA (`hermes-admin`). Clients talking to the Service do not need a kube token.

## Architecture

```text
Hermes (OpenShell netns)
  oc / kubectl
    → HTTP_PROXY 10.200.0.1:3128  (OpenShell egress)
      → hermes-kube-proxy.default.svc:8080
        → kubernetes.default.svc:443 (:6443) as SA hermes-admin
```

Kubeconfig on the guest:

```text
server: http://hermes-kube-proxy.default.svc.cluster.local:8080
```

## Manual pieces (if you skip the script)

```bash
kubectl apply -f kube-proxy/hermes-kube-proxy.yaml
openshell policy set hermes --policy hermes/policy.yaml --wait

# oc must live under /sandbox (Landlock: /usr/local is read-only)
virtctl scp "$(command -v oc)" root@vmi/hermes:/sandbox/.hermes/bin/oc -n default
```

Policy snippet (already in `hermes/policy.yaml`):

```yaml
kubernetes:
  name: kubernetes
  endpoints:
    - host: hermes-kube-proxy.default.svc.cluster.local
      port: 8080
      protocol: rest
      enforcement: enforce
      access: full
  binaries:
    - path: /sandbox/.hermes/bin/oc
    - path: /sandbox/**/bin/oc
    - path: /sandbox/.hermes/bin/kubectl
```

After editing `/sandbox/.hermes/.env`, always run `hermes/update-config-hashes.py` on the guest (both `/sandbox/.hermes/.config-hash` and `/etc/nemoclaw/hermes.config-hash`) or NemoClaw crash-loops with `HERMES_MCP_CONFIG_DRIFT`.

## Using it from Hermes

```bash
export PATH=/sandbox/.hermes/bin:$PATH
export KUBECONFIG=/sandbox/.kube/config
oc whoami   # system:serviceaccount:default:hermes-admin
oc get nodes
```

From the host (outside the sandbox netns), the same binary works against CRC’s normal API if you point at `api.crc.testing:6443` with a real kubeconfig — the guest file is proxy-oriented on purpose.

## Security

- The proxy Service is **unauthenticated cluster-admin** to anyone who can reach ClusterIP `hermes-kube-proxy:8080`.
- Fine for local CRC. Do **not** create a Route/Ingress or expose it outside the cluster.
- Rotate by deleting the SA token bindings / redeploying the proxy; recreate with `./setup.sh` if needed.

## Related footguns

- **Landlock:** install tools under `/sandbox/.hermes/bin`, not `/usr/local/bin`.
- **OpenShell egress:** sandbox processes must use the proxy (`HTTP(S)_PROXY=http://10.200.0.1:3128`); Hermes already has this for agent tools.
- **NemoClaw hashes:** any live `.env` / `config.yaml` edit needs `update-config-hashes.py` before restarting `openshell-sandbox`.
