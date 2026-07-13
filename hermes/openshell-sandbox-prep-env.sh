#!/bin/bash
# Map /etc/sandbox/env into OpenShell supervisor runtime files and drop-in env.
# Runs as ExecStartPre for openshell-sandbox.service.
set -euo pipefail

ENV_FILE="${SANDBOX_ENV_FILE:-/etc/sandbox/env}"
TOKEN_PATH="${OPENSHELL_SANDBOX_TOKEN_PATH:-/etc/openshell/auth/sandbox.jwt}"
TLS_DIR="${OPENSHELL_TLS_DIR:-/etc/openshell-tls/client}"
DROPIN_DIR=/run/openshell
DROPIN_ENV="${DROPIN_DIR}/supervisor.env"

mkdir -p /etc/openshell/auth "$TLS_DIR" "$DROPIN_DIR"
# Recreate the drop-in instead of truncating in place so a leftover
# unwritable/misowned supervisor.env (e.g. after hand-edits) cannot brick restarts.
chown root:root "$DROPIN_DIR" 2>/dev/null || true
chmod 0755 "$DROPIN_DIR" 2>/dev/null || true
rm -f "$DROPIN_ENV"
umask 022
: >"$DROPIN_ENV"
chmod 0644 "$DROPIN_ENV"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
fi

# Defaults the old controller used to inject.
{
  echo "OPENSHELL_LOG_LEVEL=${OPENSHELL_LOG_LEVEL:-info}"
  echo "OPENSHELL_SSH_SOCKET_PATH=${OPENSHELL_SSH_SOCKET_PATH:-/run/openshell/ssh.sock}"
  echo "OPENSHELL_SANDBOX_UID=${OPENSHELL_SANDBOX_UID:-10001}"
  echo "OPENSHELL_SANDBOX_GID=${OPENSHELL_SANDBOX_GID:-10001}"
  # Match the Pod path: OpenShell chowns /sandbox, drops to sandbox, then
  # Landlock/seccomp + exec. Do not set OPENSHELL_DEFER_PRIVILEGE_DROP —
  # a root entrypoint under Landlock cannot mint/write sandbox-owned .env.
} >>"$DROPIN_ENV"

if [ -n "${OPENSHELL_SANDBOX_ID:-}" ]; then
  echo "OPENSHELL_SANDBOX_ID=${OPENSHELL_SANDBOX_ID}" >>"$DROPIN_ENV"
fi
if [ -n "${OPENSHELL_SANDBOX:-}" ]; then
  echo "OPENSHELL_SANDBOX=${OPENSHELL_SANDBOX}" >>"$DROPIN_ENV"
fi
if [ -n "${OPENSHELL_ENDPOINT:-}" ]; then
  echo "OPENSHELL_ENDPOINT=${OPENSHELL_ENDPOINT}" >>"$DROPIN_ENV"
fi
# Guest default entrypoint. Gateway/create may override via metadata
# OPENSHELL_SANDBOX_COMMAND (k8s sandbox_command / create --env).
if [ -n "${OPENSHELL_SANDBOX_COMMAND:-}" ]; then
  echo "OPENSHELL_SANDBOX_COMMAND=${OPENSHELL_SANDBOX_COMMAND}" >>"$DROPIN_ENV"
else
  echo "OPENSHELL_SANDBOX_COMMAND=/usr/local/bin/nemoclaw-start-vm" >>"$DROPIN_ENV"
fi

# Prefer K8s SA bootstrap (rebootstrap-capable) over a static gateway JWT.
# A static OPENSHELL_SANDBOX_TOKEN / TOKEN_FILE wins in the supervisor and
# cannot rebootstrap after reboot once the JWT expires — only use it when
# no SA token path is configured.
if [ -n "${OPENSHELL_K8S_SA_TOKEN_FILE:-}" ]; then
  echo "OPENSHELL_K8S_SA_TOKEN_FILE=${OPENSHELL_K8S_SA_TOKEN_FILE}" >>"$DROPIN_ENV"
elif [ -n "${OPENSHELL_SANDBOX_TOKEN:-}" ]; then
  umask 077
  printf '%s' "$OPENSHELL_SANDBOX_TOKEN" >"$TOKEN_PATH"
  chmod 0400 "$TOKEN_PATH"
  echo "OPENSHELL_SANDBOX_TOKEN_FILE=${TOKEN_PATH}" >>"$DROPIN_ENV"
fi

# Optional PEM material in env (legacy / emergency inject).
# Prefer Secret volumeMounts projected by the controller into TLS_DIR;
# path env vars (OPENSHELL_TLS_CA/CERT/KEY) are set by the driver.
write_pem() {
  local dest="$1" content="${2:-}"
  [ -n "$content" ] || return 0
  printf '%s\n' "$content" >"$dest"
}

write_pem_b64() {
  local dest="$1" b64="${2:-}"
  [ -n "$b64" ] || return 0
  printf '%s' "$b64" | base64 -d >"$dest"
}

write_pem "${TLS_DIR}/ca.crt" "${OPENSHELL_TLS_CA_PEM:-${SANDBOX_TLS_CA_PEM:-}}"
write_pem "${TLS_DIR}/tls.crt" "${OPENSHELL_TLS_CERT_PEM:-${SANDBOX_TLS_CERT_PEM:-}}"
write_pem "${TLS_DIR}/tls.key" "${OPENSHELL_TLS_KEY_PEM:-${SANDBOX_TLS_KEY_PEM:-}}"
write_pem_b64 "${TLS_DIR}/ca.crt" "${OPENSHELL_TLS_CA_B64:-${SANDBOX_TLS_CA_B64:-}}"
write_pem_b64 "${TLS_DIR}/tls.crt" "${OPENSHELL_TLS_CERT_B64:-${SANDBOX_TLS_CERT_B64:-}}"
write_pem_b64 "${TLS_DIR}/tls.key" "${OPENSHELL_TLS_KEY_B64:-${SANDBOX_TLS_KEY_B64:-}}"
[ -f "${TLS_DIR}/tls.key" ] && chmod 0400 "${TLS_DIR}/tls.key" || true
[ -f "${TLS_DIR}/ca.crt" ] && chmod 0444 "${TLS_DIR}/ca.crt" || true
[ -f "${TLS_DIR}/tls.crt" ] && chmod 0444 "${TLS_DIR}/tls.crt" || true

if [ -f "${TLS_DIR}/ca.crt" ] && [ -f "${TLS_DIR}/tls.crt" ] && [ -f "${TLS_DIR}/tls.key" ]; then
  echo "OPENSHELL_TLS_CA=${TLS_DIR}/ca.crt" >>"$DROPIN_ENV"
  echo "OPENSHELL_TLS_CERT=${TLS_DIR}/tls.crt" >>"$DROPIN_ENV"
  echo "OPENSHELL_TLS_KEY=${TLS_DIR}/tls.key" >>"$DROPIN_ENV"
elif [ -n "${OPENSHELL_ENDPOINT:-}" ] && [[ "${OPENSHELL_ENDPOINT}" == https://* ]]; then
  echo "openshell-sandbox-prep-env: OPENSHELL_ENDPOINT is https but ${TLS_DIR} is incomplete; mTLS to gateway will fail until the client TLS Secret is mounted" >&2
fi

# Forward any other KEY=VALUE from the sandbox env file into the drop-in
# (skip ones we already handled specially).
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      OPENSHELL_SANDBOX_TOKEN=*|OPENSHELL_K8S_SA_TOKEN_FILE=*|OPENSHELL_TLS_CA_PEM=*|OPENSHELL_TLS_CERT_PEM=*|OPENSHELL_TLS_KEY_PEM=*|OPENSHELL_TLS_CA_B64=*|OPENSHELL_TLS_CERT_B64=*|OPENSHELL_TLS_KEY_B64=*|SANDBOX_TLS_CA_PEM=*|SANDBOX_TLS_CERT_PEM=*|SANDBOX_TLS_KEY_PEM=*|SANDBOX_TLS_CA_B64=*|SANDBOX_TLS_CERT_B64=*|SANDBOX_TLS_KEY_B64=*) continue ;;
      *=*)
        key="${line%%=*}"
        case "$key" in
          OPENSHELL_SANDBOX_ID|OPENSHELL_SANDBOX|OPENSHELL_ENDPOINT|OPENSHELL_SANDBOX_COMMAND|OPENSHELL_LOG_LEVEL|OPENSHELL_SSH_SOCKET_PATH|OPENSHELL_SANDBOX_UID|OPENSHELL_SANDBOX_GID)
            continue
            ;;
        esac
        echo "$line" >>"$DROPIN_ENV"
        ;;
    esac
  done <"$ENV_FILE"
fi

# Gate sibling Hermes (sandbox-workload) for SUPERVISOR_MODE=network.
# Must run in ExecStartPre so the file exists before Type=simple marks this
# unit active — After=openshell-sandbox + WantedBy=openshell-sandbox then
# start the workload without a path unit or systemctl-from-script.
if [ "${SUPERVISOR_MODE:-}" = "network" ]; then
  touch "${DROPIN_DIR}/want-workload"
else
  rm -f "${DROPIN_DIR}/want-workload"
fi
