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

exec /opt/openshell/bin/openshell-sandbox
