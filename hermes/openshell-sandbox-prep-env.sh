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
: >"$DROPIN_ENV"

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
if [ -n "${OPENSHELL_SANDBOX_COMMAND:-}" ]; then
  echo "OPENSHELL_SANDBOX_COMMAND=${OPENSHELL_SANDBOX_COMMAND}" >>"$DROPIN_ENV"
  echo "OPENSHELL_PRESERVE_SANDBOX_OWNERSHIP=1" >>"$DROPIN_ENV"
fi

# Prefer token file over putting the JWT on the process environment long-term.
if [ -n "${OPENSHELL_SANDBOX_TOKEN:-}" ]; then
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
      OPENSHELL_SANDBOX_TOKEN=*|OPENSHELL_TLS_CA_PEM=*|OPENSHELL_TLS_CERT_PEM=*|OPENSHELL_TLS_KEY_PEM=*|OPENSHELL_TLS_CA_B64=*|OPENSHELL_TLS_CERT_B64=*|OPENSHELL_TLS_KEY_B64=*|SANDBOX_TLS_CA_PEM=*|SANDBOX_TLS_CERT_PEM=*|SANDBOX_TLS_KEY_PEM=*|SANDBOX_TLS_CA_B64=*|SANDBOX_TLS_CERT_B64=*|SANDBOX_TLS_KEY_B64=*) continue ;;
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
