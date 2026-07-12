#!/usr/bin/env bash
# Link Signal as a secondary device onto the CRC PVC, then start the daemon.
#
# Usage:
#   export KUBECONFIG=~/.crc/machines/crc/kubeconfig
#   ./signal/link.sh [DeviceName]
#
# Scan the QR with Signal → Settings → Linked Devices → Link New Device.
set -euo pipefail

DEVICE_NAME="${1:-HermesCRC}"
NS="${SIGNAL_NAMESPACE:-default}"
IMAGE="${SIGNAL_CLI_IMAGE:-registry.gitlab.com/packaging/signal-cli/signal-cli-native:latest}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need oc
need qrencode

echo "Applying PVC/Service/Deployment/SA…"
oc apply -f "${ROOT}/signal-cli.yaml"

echo "Scaling daemon to 0 so the link pod can mount the RWO volume…"
oc -n "$NS" scale deploy/signal-cli --replicas=0
oc -n "$NS" delete pod -l app.kubernetes.io/name=signal-cli --wait=false --ignore-not-found >/dev/null 2>&1 || true
# Wait until no daemon pods remain
for _ in $(seq 1 60); do
  left=$(oc -n "$NS" get pods -l app.kubernetes.io/name=signal-cli --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "$left" == "0" ]] && break
  sleep 2
done

POD="signal-cli-link"
oc -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo "Starting link pod (${DEVICE_NAME})…"
# Same UID/data-dir contract as the Deployment. Init chowns the hostpath PVC.
oc -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: signal-cli-link
spec:
  serviceAccountName: signal-cli
  restartPolicy: Never
  securityContext:
    fsGroup: 101
    runAsUser: 101
    runAsGroup: 101
    fsGroupChangePolicy: OnRootMismatch
  initContainers:
    - name: fix-data-perms
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sh", "-c", "mkdir -p /var/lib/signal-cli && chown -R 101:101 /var/lib/signal-cli"]
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      volumeMounts:
        - name: data
          mountPath: /var/lib/signal-cli
  containers:
    - name: link
      image: ${IMAGE}
      args: ["-d", "/var/lib/signal-cli", "link", "-n", "${DEVICE_NAME}"]
      volumeMounts:
        - name: data
          mountPath: /var/lib/signal-cli
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: signal-cli-data
    - name: tmp
      emptyDir:
        medium: Memory
EOF

cleanup() {
  oc -n "$NS" delete pod "$POD" --wait=false --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Waiting for sgnl:// URI in logs…"
URI=""
for _ in $(seq 1 90); do
  URI="$(oc -n "$NS" logs "$POD" -c link 2>/dev/null | grep -E '^sgnl://' | tail -1 || true)"
  if [[ -n "$URI" ]]; then
    break
  fi
  phase="$(oc -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo Pending)"
  if [[ "$phase" == Failed || "$phase" == Succeeded ]]; then
    echo "--- init ---" >&2
    oc -n "$NS" logs "$POD" -c fix-data-perms >&2 || true
    echo "--- link ---" >&2
    oc -n "$NS" logs "$POD" -c link >&2 || true
    oc -n "$NS" get pod "$POD" -o wide >&2 || true
    echo "link pod ended before emitting URI (phase=${phase})" >&2
    exit 1
  fi
  sleep 2
done

if [[ -z "$URI" ]]; then
  oc -n "$NS" logs "$POD" -c link || true
  echo "timed out waiting for link URI" >&2
  exit 1
fi

echo
echo "Scan this QR in Signal → Settings → Linked Devices → Link New Device:"
echo
qrencode -t ANSIUTF8 "$URI"
echo
echo "$URI"
echo
echo "Waiting for link to complete (pod Succeeded)…"
oc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$POD" --timeout=300s

trap - EXIT
oc -n "$NS" delete pod "$POD" --wait=false --ignore-not-found >/dev/null 2>&1 || true

echo "Starting daemon…"
oc -n "$NS" scale deploy/signal-cli --replicas=1
oc -n "$NS" rollout status deploy/signal-cli --timeout=180s

echo
echo "Health:"
oc -n "$NS" run signal-cli-check --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
  curl -sf "http://signal-cli.${NS}.svc.cluster.local:8080/api/v1/check"
echo
echo "OK. Point Hermes at:"
echo "  SIGNAL_HTTP_URL=http://signal-cli.${NS}.svc.cluster.local:8080"
echo "  SIGNAL_ACCOUNT=+E.164 of the linked phone"
echo "  SIGNAL_ALLOWED_USERS=+E.164 allowlist"
