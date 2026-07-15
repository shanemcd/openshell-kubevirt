#!/bin/bash
# Hermes workload for SUPERVISOR_MODE=network (sibling of openshell-sandbox).
# Enters the sandbox netns, registers entrypoint.pid (when supported), sources
# provider.env if present, points TLS/proxy at the OpenShell L7 proxy, then
# execs sandbox-entrypoint (or OPENSHELL_SANDBOX_COMMAND override).
# Variant images symlink sandbox-entrypoint → nemoclaw-start-vm or hermes-start.sh.
set -euo pipefail

NETNS_FILE="${OPENSHELL_NETNS_FILE:-/run/openshell/netns}"
PROVIDER_ENV="${OPENSHELL_PROVIDER_ENV:-/run/openshell/provider.env}"
ENTRYPOINT_PID="${OPENSHELL_ENTRYPOINT_PID:-/run/openshell/entrypoint.pid}"
PROXY_HOST="${NEMOCLAW_PROXY_HOST:-10.200.0.1}"
PROXY_PORT="${NEMOCLAW_PROXY_PORT:-3128}"
COMMAND="${OPENSHELL_SANDBOX_COMMAND:-/usr/local/bin/sandbox-entrypoint}"
SANDBOX_UID="${OPENSHELL_SANDBOX_UID:-10001}"
SANDBOX_GID="${OPENSHELL_SANDBOX_GID:-10001}"

log() { echo "sandbox-workload: $*" >&2; }

# Ensure MITM CA is in the system trust store (idempotent; also ExecStartPost).
if [ -x /usr/local/lib/openshell/trust-openshell-ca.sh ]; then
  /usr/local/lib/openshell/trust-openshell-ca.sh || true
fi

# Already inside the target netns (re-exec via ip netns exec) — do this first.
if [ "${SANDBOX_WORKLOAD_IN_NETNS:-}" = "1" ]; then
  echo $$ >"$ENTRYPOINT_PID" 2>/dev/null || true

  if [ -f "$PROVIDER_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$PROVIDER_ENV"
    set +a
  else
    log "note: $PROVIDER_ENV missing; relying on Hermes .env placeholders + proxy rewrite"
  fi
  # Create-time literals (Signal account, etc.) live in the sandbox env file.
  if [ -f /etc/sandbox/env ]; then
    set -a
    # shellcheck disable=SC1091
    . /etc/sandbox/env
    set +a
  fi

  _PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
  export HTTP_PROXY="$_PROXY_URL" HTTPS_PROXY="$_PROXY_URL"
  export http_proxy="$_PROXY_URL" https_proxy="$_PROXY_URL"
  export NO_PROXY="localhost,127.0.0.1,::1,${PROXY_HOST}"
  export no_proxy="$NO_PROXY"

  for cand in \
    /etc/openshell-tls/ca-bundle.pem \
    /etc/openshell-tls/openshell-ca.pem \
    /run/openshell/ca-bundle.pem \
    /run/openshell/openshell-ca.pem; do
    if [ -s "$cand" ]; then
      export SSL_CERT_FILE="$cand"
      export REQUESTS_CA_BUNDLE="$cand"
      export CURL_CA_BUNDLE="$cand"
      export GIT_SSL_CAINFO="$cand"
      export NODE_EXTRA_CA_CERTS="$cand"
      break
    fi
  done

  export NEMOCLAW_VM_SIDECAR=1
  export NEMOCLAW_PROXY_HOST="$PROXY_HOST"
  export NEMOCLAW_PROXY_PORT="$PROXY_PORT"

  # Rootless podman (and many tools) key off USER / XDG_RUNTIME_DIR. The
  # workload starts as root then drops uid; without rewriting these, podman
  # tries /run/user/0 and fails with "cannot clone" / permission errors.
  # Linger (baked at /var/lib/systemd/linger/sandbox) starts user@UID so the
  # session bus exists; point DBUS at it for systemd cgroup manager.
  export HOME="${HOME:-/sandbox}"
  export HERMES_HOME="${HERMES_HOME:-/sandbox/.hermes}"
  export USER=sandbox
  export LOGNAME=sandbox
  export XDG_RUNTIME_DIR="/run/user/${SANDBOX_UID}"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  mkdir -p "$XDG_RUNTIME_DIR"
  chown "${SANDBOX_UID}:${SANDBOX_GID}" "$XDG_RUNTIME_DIR" 2>/dev/null || true

  # Prefer setpriv (same as NemoClaw); gosu may lack CAP_SETUID inside the netns.
  if [ "$(id -u)" -eq 0 ]; then
    if command -v setpriv >/dev/null 2>&1; then
      exec setpriv --reuid="$SANDBOX_UID" --regid="$SANDBOX_GID" --init-groups -- "$COMMAND"
    fi
    if command -v gosu >/dev/null 2>&1; then
      exec gosu "${SANDBOX_UID}:${SANDBOX_GID}" "$COMMAND"
    fi
    exec runuser -u sandbox -- "$COMMAND"
  fi
  exec "$COMMAND"
fi

# Resolve sandbox netns: prefer published path, else discover sandbox-* via ip netns.
resolve_netns() {
  local path name
  if [ -f "$NETNS_FILE" ]; then
    path="$(tr -d '[:space:]' <"$NETNS_FILE")"
    if [ -n "$path" ] && [ -e "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  fi
  name="$(ip netns list 2>/dev/null | awk '/^sandbox-/ {print $1; exit}')"
  if [ -n "$name" ]; then
    for base in /run/netns /var/run/netns; do
      if [ -e "$base/$name" ]; then
        printf '%s\n' "$base/$name" >"$NETNS_FILE" 2>/dev/null || true
        printf '%s\n' "$base/$name"
        return 0
      fi
    done
  fi
  return 1
}

NETNS_PATH=""
for _ in $(seq 1 120); do
  if NETNS_PATH="$(resolve_netns)"; then
    break
  fi
  NETNS_PATH=""
  sleep 1
done
if [ -z "$NETNS_PATH" ]; then
  log "timed out waiting for sandbox netns ($NETNS_FILE or ip netns sandbox-*)"
  exit 1
fi

log "entering netns $NETNS_PATH"
# Use nsenter (not ip netns exec) so we keep CAP_SETUID for the sandbox drop.
exec nsenter --net="$NETNS_PATH" env SANDBOX_WORKLOAD_IN_NETNS=1 "$0"
