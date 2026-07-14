#!/bin/bash
# Launch openshell-sandbox with the env drop-in produced by ExecStartPre
# (openshell-sandbox-prep-env.sh).
set -euo pipefail

DROPIN_ENV="${OPENSHELL_SUPERVISOR_ENV:-/run/openshell/supervisor.env}"

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
# Or at runtime: openshell-supervisor-mode {combined|network}
# Values: network | process | network,process
#
# network → proxy leaf only; sandbox-workload.service runs Hermes in the netns.
# (combined / unset) → single binary runs netns + Landlock + Hermes child.
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

# Entrypoint comes from OPENSHELL_SANDBOX_COMMAND in the drop-in (guest default
# sandbox_command / create --env). Do not pass argv here so an
# explicit metadata command wins via env; empty metadata uses the guest default.
# In network-only mode the binary ignores process spawn; Hermes is sandbox-workload.
exec /opt/openshell/bin/openshell-sandbox "${MODE_ARGS[@]}"
