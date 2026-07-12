#!/usr/bin/env bash
# Wire Hermes (OpenShell sandbox on CRC) to the kube API with cluster-admin.
#
# Why this exists:
#   OpenShell SSRF blocks sandbox egress to port 6443, so Hermes cannot call
#   api.crc.testing:6443 or the apiserver behind kubernetes.default.svc directly.
#   We run an in-cluster `kubectl proxy` on :8080 and point oc at that Service.
#
# Usage:
#   export KUBECONFIG=~/.crc/machines/crc/kubeconfig
#   export OPENSHELL_GATEWAY=crc
#   unset OPENSHELL_GATEWAY_ENDPOINT
#   ./kube-proxy/setup.sh
#
# Options:
#   --skip-oc-copy   Assume /sandbox/.hermes/bin/oc already exists on the guest
#   --no-restart     Update files/policy but do not restart openshell-sandbox
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${ROOT}/.." && pwd)"
NS="${HERMES_NAMESPACE:-default}"
VMI="${HERMES_VMI:-hermes}"
SANDBOX="${HERMES_SANDBOX:-hermes}"
POLICY="${HERMES_POLICY:-${REPO}/hermes/policy.yaml}"
OC_HOST_BIN="${OC_HOST_BIN:-$(command -v oc || true)}"
SKIP_OC_COPY=0
NO_RESTART=0

for arg in "$@"; do
  case "$arg" in
    --skip-oc-copy) SKIP_OC_COPY=1 ;;
    --no-restart) NO_RESTART=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need kubectl
need virtctl
need openshell
need python3

if [[ -z "${KUBECONFIG:-}" ]]; then
  export KUBECONFIG="${HOME}/.crc/machines/crc/kubeconfig"
fi
if [[ -z "${OPENSHELL_GATEWAY:-}" ]]; then
  export OPENSHELL_GATEWAY=crc
fi
unset OPENSHELL_GATEWAY_ENDPOINT || true

ssh_guest() {
  virtctl ssh "root@vmi/${VMI}" -n "$NS" \
    --local-ssh-opts='-o StrictHostKeyChecking=no' \
    --local-ssh-opts='-o BatchMode=yes' \
    -c "$1"
}

echo "==> Applying SA / cluster-admin / kube-proxy"
kubectl apply -f "${ROOT}/hermes-kube-proxy.yaml"
kubectl -n "$NS" rollout status deploy/hermes-kube-proxy --timeout=120s

PROXY_URL="http://hermes-kube-proxy.${NS}.svc.cluster.local:8080"
echo "==> Smoke-test proxy from cluster: ${PROXY_URL}/version"
kubectl -n "$NS" run hermes-kube-proxy-check --rm -i --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest -- \
  curl -sS --max-time 15 "${PROXY_URL}/version" >/dev/null

echo "==> Ensuring OpenShell policy includes kubernetes → hermes-kube-proxy:8080"
if ! grep -q 'hermes-kube-proxy' "$POLICY"; then
  echo "policy missing hermes-kube-proxy rule: ${POLICY}" >&2
  exit 1
fi
openshell policy set "$SANDBOX" --policy "$POLICY" --wait

echo "==> Preparing guest dirs"
ssh_guest 'mkdir -p /sandbox/.hermes/bin /sandbox/.kube && chown -R sandbox:sandbox /sandbox/.hermes/bin /sandbox/.kube'

if [[ "$SKIP_OC_COPY" -eq 0 ]]; then
  if [[ -z "$OC_HOST_BIN" || ! -x "$OC_HOST_BIN" ]]; then
    echo "oc not found on host; set OC_HOST_BIN or pass --skip-oc-copy" >&2
    exit 1
  fi
  echo "==> Copying oc from host (${OC_HOST_BIN}) → /sandbox/.hermes/bin/oc"
  virtctl scp "$OC_HOST_BIN" "root@vmi/${VMI}:/sandbox/.hermes/bin/oc" -n "$NS"
  ssh_guest 'chmod 755 /sandbox/.hermes/bin/oc && chown sandbox:sandbox /sandbox/.hermes/bin/oc && ln -sfn oc /sandbox/.hermes/bin/kubectl && chown -h sandbox:sandbox /sandbox/.hermes/bin/kubectl'
else
  echo "==> Skipping oc copy (--skip-oc-copy)"
fi

echo "==> Writing /sandbox/.kube/config (HTTP via in-cluster proxy)"
# Token unused: kubectl proxy authenticates with hermes-admin SA.
ssh_guest "cat > /sandbox/.kube/config <<'EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${PROXY_URL}
  name: crc-via-proxy
contexts:
- context:
    cluster: crc-via-proxy
    namespace: ${NS}
    user: hermes-admin
  name: hermes-admin@crc
current-context: hermes-admin@crc
users:
- name: hermes-admin
  user:
    token: unused-proxy-uses-sa
EOF
chown sandbox:sandbox /sandbox/.kube/config && chmod 600 /sandbox/.kube/config"

echo "==> Updating Hermes .env PATH/KUBECONFIG + NemoClaw hashes"
# Copy hash helper if missing on guest
if ! ssh_guest 'test -f /tmp/update-config-hashes.py'; then
  virtctl scp "${REPO}/hermes/update-config-hashes.py" \
    "root@vmi/${VMI}:/tmp/update-config-hashes.py" -n "$NS"
fi

ssh_guest 'python3 - <<"PY"
from pathlib import Path
p = Path("/sandbox/.hermes/.env")
lines = p.read_text().splitlines() if p.exists() else []
out = []
seen_path = seen_kube = False
for line in lines:
    if line.startswith("PATH="):
        val = line.split("=", 1)[1]
        parts = [x for x in val.split(":") if x]
        if "/sandbox/.hermes/bin" not in parts:
            parts.insert(0, "/sandbox/.hermes/bin")
        out.append("PATH=" + ":".join(parts))
        seen_path = True
    elif line.startswith("KUBECONFIG="):
        out.append("KUBECONFIG=/sandbox/.kube/config")
        seen_kube = True
    else:
        out.append(line)
if not seen_path:
    out.append("PATH=/sandbox/.hermes/bin:/usr/bin:/bin")
if not seen_kube:
    out.append("KUBECONFIG=/sandbox/.kube/config")
p.write_text("\n".join(out) + "\n")
print("dotenv updated")
PY
python3 /tmp/update-config-hashes.py
chown root:root /etc/nemoclaw/hermes.config-hash && chmod 444 /etc/nemoclaw/hermes.config-hash
chown sandbox:sandbox /sandbox/.hermes/.config-hash /sandbox/.hermes/.env
chmod 640 /sandbox/.hermes/.config-hash /sandbox/.hermes/.env
grep -q "/sandbox/.hermes/bin" /sandbox/.bashrc 2>/dev/null || echo "export PATH=/sandbox/.hermes/bin:\$PATH" >> /sandbox/.bashrc
grep -q KUBECONFIG /sandbox/.bashrc 2>/dev/null || echo "export KUBECONFIG=/sandbox/.kube/config" >> /sandbox/.bashrc
'

if [[ "$NO_RESTART" -eq 0 ]]; then
  echo "==> Restarting openshell-sandbox (pick up .env)"
  ssh_guest 'systemctl reset-failed openshell-sandbox; systemctl restart openshell-sandbox; sleep 10; systemctl is-active openshell-sandbox'
fi

echo "==> Verifying oc through OpenShell sandbox netns"
ssh_guest '
set -e
ns=""
for n in /var/run/netns/*; do
  name=$(basename "$n")
  ip netns exec "$name" ip -4 addr show 2>/dev/null | grep -q 10.200.0.2 || continue
  ns=$name
  break
done
[[ -n "$ns" ]] || { echo "sandbox netns not found"; exit 1; }
who=$(timeout 30 ip netns exec "$ns" env \
  PATH=/sandbox/.hermes/bin:/usr/bin \
  KUBECONFIG=/sandbox/.kube/config \
  HTTP_PROXY=http://10.200.0.1:3128 \
  HTTPS_PROXY=http://10.200.0.1:3128 \
  http_proxy=http://10.200.0.1:3128 \
  https_proxy=http://10.200.0.1:3128 \
  setpriv --reuid=10001 --regid=10001 --clear-groups \
  /sandbox/.hermes/bin/oc whoami)
echo "oc whoami => $who"
[[ "$who" == "system:serviceaccount:default:hermes-admin" ]] || {
  echo "unexpected identity: $who" >&2
  exit 1
}
'

echo
echo "OK. From Hermes terminal tools:"
echo "  export PATH=/sandbox/.hermes/bin:\$PATH"
echo "  export KUBECONFIG=/sandbox/.kube/config"
echo "  oc whoami && oc get nodes"
echo
echo "Docs: ${ROOT}/README.md"
