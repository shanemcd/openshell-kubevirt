# Hermes bootc (KubeVirt guest)

Build context for `ghcr.io/shanemcd/hermes-sandbox-bootc`. Only files `COPY`d by `Containerfile.kubevirt` live here (plus `hermes.env.example` for CI).

```bash
cp -n hermes.env.example hermes.env
: > extra-ca-certs.pem
podman build \
  --build-arg OPENSHELL_SUPERVISOR_IMAGE=localhost/openshell-supervisor:kubevirt \
  -f Containerfile.kubevirt \
  -t localhost/hermes-sandbox-bootc:latest .
```

NemoClaw stage expects `localhost/nemoclaw-hermes:kubevirt` (or rewrite the `FROM` like CI does for GHCR).
