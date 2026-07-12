# Signal (signal-cli) on CRC

In-cluster [signal-cli](https://github.com/AsamK/signal-cli) HTTP daemon for Hermes. Avoids a host-local CLI and the blocked `host.containers.internal` path.

Service DNS (from the Hermes guest / OpenShell policy):

```text
http://signal-cli.default.svc.cluster.local:8080
```

## Deploy + link

```bash
export KUBECONFIG=~/.crc/machines/crc/kubeconfig
chmod +x signal/link.sh
./signal/link.sh HermesCRC
```

That applies `signal-cli.yaml`, chowns the hostpath PVC for uid `101`, runs a one-shot link pod (QR in the terminal), then scales the Deployment to 1 and checks `/api/v1/check`.

If you previously saw `Failed to read local accounts list`, re-run `./signal/link.sh` after pulling the updated manifests (PVC perms + explicit `-d /var/lib/signal-cli`).

Re-link later: `./signal/link.sh` again (scales daemon down first; same PVC).

## Wire Hermes

Enable Signal in config (`platforms.signal.enabled: true`). Do **not** bake `SIGNAL_ACCOUNT` / allowlists into the image `.env` — Hermes `load_dotenv(override=True)` would clobber create-time env. Pass literals at create (never commit real numbers; not `openshell:resolve:` — Hermes reads these via `os.getenv`):

```bash
openshell sandbox create ... \
  --env "SIGNAL_HTTP_URL=http://signal-cli.default.svc.cluster.local:8080" \
  --env "SIGNAL_ACCOUNT=+1XXXXXXXXXX" \
  --env "SIGNAL_ALLOWED_USERS=+1YYYYYYYYYY" \
  --env "SLACK_ALLOWED_USERS=U…"
```

`SIGNAL_HTTP_URL` alone may be baked (see `hermes.env.example`). Account / allowlist keys must come from `--env` only.

OpenShell policy must allow the Service host for Hermes python, e.g.:

```yaml
  signal:
    name: signal
    endpoints:
      - host: signal-cli.default.svc.cluster.local
        port: 8080
        protocol: rest
        enforcement: enforce
        access: full
    binaries:
      - path: /opt/hermes/.venv/bin/python
```

SSE to signal-cli is HTTP long-poll style; `protocol: rest` is the usual OpenShell choice for this path.

## Notes

- Daemon binds `0.0.0.0:8080` **inside** the pod only; the Service is ClusterIP (not a Route). Do not expose it publicly — the HTTP API has no auth.
- Account data lives on PVC `signal-cli-data`. Back it up if you care about the linked device.
- CRC storage class in the manifest is `crc-csi-hostpath-provisioner`; change if your cluster differs.
- Image: `registry.gitlab.com/packaging/signal-cli/signal-cli-native:latest` (same as the old host podman flow).
