#!/bin/bash
# Install the OpenShell MITM CA into the Fedora/RHEL system trust store.
#
# OpenShell writes:
#   openshell-ca.pem  — sandbox MITM CA only (use as trust anchor)
#   ca-bundle.pem     — system CAs + MITM CA (for SSL_CERT_FILE replacement)
#
# Anchoring the full ca-bundle would duplicate every system root. We install
# openshell-ca.pem so tools that ignore SSL_CERT_FILE / CURL_CA_BUNDLE
# (podman, some Go/Java) still trust the L7 proxy.
set -euo pipefail

ANCHOR="${OPENSHELL_CA_ANCHOR:-/etc/pki/ca-trust/source/anchors/openshell-ca.crt}"
TIMEOUT_SEC="${OPENSHELL_CA_TRUST_TIMEOUT_SEC:-60}"

find_ca() {
  local cand
  for cand in \
    /etc/openshell-tls/openshell-ca.pem \
    /run/openshell/openshell-ca.pem; do
    if [ -s "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

CA=""
for _ in $(seq 1 "$TIMEOUT_SEC"); do
  if CA="$(find_ca)"; then
    break
  fi
  sleep 1
done

if [ -z "$CA" ]; then
  echo "trust-openshell-ca: OpenShell CA not found after ${TIMEOUT_SEC}s; skipping" >&2
  exit 0
fi

mkdir -p "$(dirname "$ANCHOR")"
if [ -f "$ANCHOR" ] && cmp -s "$CA" "$ANCHOR"; then
  exit 0
fi

install -m 0644 "$CA" "$ANCHOR"
update-ca-trust extract
echo "trust-openshell-ca: installed $CA -> $ANCHOR" >&2

# Podman/buildah: ensure containers (and build RUN steps) see the CA.
# /etc/containers is writable on the Hermes guest even when /usr is RO.
if [ -d /etc/containers ]; then
  mkdir -p /etc/containers/containers.conf.d
  if [ ! -f /etc/containers/mounts.conf ] || ! grep -q openshell-tls /etc/containers/mounts.conf 2>/dev/null; then
    cat > /etc/containers/mounts.conf <<'EOF'
# OpenShell MITM: copy host CA bundle into common trust paths inside containers.
/etc/openshell-tls/ca-bundle.pem:/etc/ssl/certs/ca-certificates.crt
/etc/openshell-tls/ca-bundle.pem:/etc/ssl/cert.pem
/etc/openshell-tls/ca-bundle.pem:/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
/etc/openshell-tls/openshell-ca.pem:/etc/pki/ca-trust/source/anchors/openshell-ca.crt
EOF
    echo "trust-openshell-ca: wrote /etc/containers/mounts.conf" >&2
  fi
  if [ ! -f /etc/containers/containers.conf.d/50-openshell-tls.conf ]; then
    cat > /etc/containers/containers.conf.d/50-openshell-tls.conf <<'EOF'
[containers]
env = [
  "SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem",
  "REQUESTS_CA_BUNDLE=/etc/openshell-tls/ca-bundle.pem",
  "CURL_CA_BUNDLE=/etc/openshell-tls/ca-bundle.pem",
  "GIT_SSL_CAINFO=/etc/openshell-tls/ca-bundle.pem",
  "NODE_EXTRA_CA_CERTS=/etc/openshell-tls/openshell-ca.pem",
]
volumes = [
  "/etc/openshell-tls:/etc/openshell-tls:ro",
]
EOF
    echo "trust-openshell-ca: wrote containers.conf.d/50-openshell-tls.conf" >&2
  fi
  # Allow containers to read host cert files under SELinux.
  if command -v setsebool >/dev/null 2>&1; then
    setsebool -P container_read_certs 1 2>/dev/null || setsebool container_read_certs 1 2>/dev/null || true
  fi
fi
