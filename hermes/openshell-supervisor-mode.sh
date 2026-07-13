#!/bin/bash
# Switch Hermes between combined (network,process) and network-only (+ workload).
#
# Usage:
#   openshell-supervisor-mode              # show current mode
#   openshell-supervisor-mode combined     # Landlock + Hermes under supervisor
#   openshell-supervisor-mode network      # proxy leaf + sibling Hermes workload
#
# Persist across recreate with create --env SUPERVISOR_MODE=network (or omit for combined).
set -euo pipefail

ENV_FILE="${SANDBOX_ENV_FILE:-/etc/sandbox/env}"

usage() {
  cat <<'EOF' >&2
Usage: openshell-supervisor-mode [combined|network|status]

  combined  Default: openshell-sandbox --mode network,process (Landlock + Hermes child)
  network   Split: openshell-sandbox --mode network + sandbox-workload (no Landlock)
  status    Print current mode (default if no argument)

EOF
  exit 2
}

current_mode() {
  local m=""
  if [ -f "$ENV_FILE" ]; then
    m="$(grep -E '^SUPERVISOR_MODE=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  fi
  case "$m" in
    network) echo network ;;
    network,process|process,network|process|"") echo combined ;;
    *) echo "${m:-combined}" ;;
  esac
}

set_env_mode() {
  local want="$1"
  mkdir -p "$(dirname "$ENV_FILE")"
  touch "$ENV_FILE"
  if grep -q '^SUPERVISOR_MODE=' "$ENV_FILE" 2>/dev/null; then
    grep -v '^SUPERVISOR_MODE=' "$ENV_FILE" >"${ENV_FILE}.tmp" || true
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
  fi
  if [ "$want" = network ]; then
    echo 'SUPERVISOR_MODE=network' >>"$ENV_FILE"
  fi
  # combined: leave SUPERVISOR_MODE unset → binary default network,process
}

cmd="${1:-status}"
case "$cmd" in
  -h|--help|help) usage ;;
  status)
    echo "mode=$(current_mode)"
    if systemctl is-active --quiet openshell-sandbox 2>/dev/null; then
      echo -n "openshell-sandbox: "; systemctl is-active openshell-sandbox
      tr '\0' ' ' </proc/"$(pgrep -n -f '/opt/openshell/bin/openshell-sandbox' || echo 0)"/cmdline 2>/dev/null || true
      echo
    else
      echo "openshell-sandbox: inactive"
    fi
    echo -n "sandbox-workload: "
    systemctl is-active sandbox-workload 2>/dev/null || echo inactive
    if [ -e /run/openshell/want-workload ]; then
      echo "want-workload: present"
    else
      echo "want-workload: absent"
    fi
    exit 0
    ;;
  combined|network) ;;
  *) usage ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "openshell-supervisor-mode: must run as root" >&2
  exit 1
fi

echo "switching to $cmd (was $(current_mode))"

# When leaving combined mode, snapshot provider-like env from the live Hermes
# process so the sibling workload can source it (current supervisor builds do
# not always publish /run/openshell/provider.env).
if [ "$cmd" = network ]; then
  mkdir -p /run/openshell
  : >/run/openshell/provider.env
  hermes_pid="$(pgrep -n -f '/opt/hermes/.venv/bin/hermes gateway' || true)"
  if [ -n "${hermes_pid}" ] && [ -r "/proc/${hermes_pid}/environ" ]; then
    tr '\0' '\n' <"/proc/${hermes_pid}/environ" \
      | grep -E '^(SLACK_|SIGNAL_|GOOGLE_|GITHUB_|GH_|JIRA_|ATLASSIAN_|DISCORD_|TELEGRAM_|API_SERVER_|ANTHROPIC_|HERMES_)' \
      >>/run/openshell/provider.env || true
    chmod 0644 /run/openshell/provider.env
    echo "snapshotted $(grep -c '=' /run/openshell/provider.env || echo 0) provider env keys from pid ${hermes_pid}"
  fi
fi

systemctl stop sandbox-workload 2>/dev/null || true
systemctl stop openshell-sandbox 2>/dev/null || true
# Drop stale netns markers from the previous mode (keep provider.env snapshot).
rm -f /run/openshell/want-workload /run/openshell/entrypoint.pid /run/openshell/netns

set_env_mode "$cmd"

systemctl start openshell-sandbox
# Wait until supervisor is up (and want-workload written for network mode).
for _ in $(seq 1 30); do
  systemctl is-active --quiet openshell-sandbox && break
  sleep 1
done
systemctl is-active openshell-sandbox

if [ "$cmd" = network ]; then
  for _ in $(seq 1 30); do
    [ -e /run/openshell/want-workload ] && break
    sleep 1
  done
  if [ ! -e /run/openshell/want-workload ]; then
    echo "openshell-supervisor-mode: want-workload not created; is SUPERVISOR_MODE=network in $ENV_FILE?" >&2
    exit 1
  fi
  systemctl start sandbox-workload
  systemctl is-active sandbox-workload
else
  systemctl stop sandbox-workload 2>/dev/null || true
  systemctl reset-failed sandbox-workload 2>/dev/null || true
fi

echo "mode=$(current_mode)"
pgrep -af '/opt/openshell/bin/openshell-sandbox' || true
pgrep -af 'nemoclaw-start|hermes gateway' || true
