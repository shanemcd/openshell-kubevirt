#!/bin/bash
# Launch openshell-sandbox with the env drop-in produced by openshell-sandbox-prep-env.sh.
set -euo pipefail

ENV_FILE="${SANDBOX_ENV_FILE:-/etc/sandbox/env}"
DROPIN_ENV="${OPENSHELL_SUPERVISOR_ENV:-/run/openshell/supervisor.env}"

/usr/local/lib/openshell/openshell-sandbox-prep-env.sh

if [ -f "$DROPIN_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$DROPIN_ENV"
  set +a
fi

# Clean leftover sandbox netns from prior runs.
for ns in $(ip netns list 2>/dev/null | grep "^sandbox-" | cut -d" " -f1); do
  ip netns delete "$ns" 2>/dev/null || true
done

# Supervisor leaf mode: omit --mode for binary default (network,process).
# Override at create time with a non-OPENSHELL_ env (CLI reserves OPENSHELL_*):
#   openshell sandbox create --env "SUPERVISOR_MODE=network" ...
# Values: network | process | network,process
MODE_ARGS=()
MODE="${SUPERVISOR_MODE:-}"
if [ -n "$MODE" ]; then
  case "$MODE" in
    network|process|network,process|process,network) ;;
    *)
      echo "openshell-sandbox-run: invalid SUPERVISOR_MODE='$MODE' (expected network, process, or network,process)" >&2
      exit 1
      ;;
  esac
  MODE_ARGS=(--mode "$MODE")
fi

exec /opt/openshell/bin/openshell-sandbox "${MODE_ARGS[@]}"
