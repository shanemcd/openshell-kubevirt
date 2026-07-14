#!/usr/bin/env bash
# Thin Hermes gateway entrypoint for OpenShell network-only (or combined) mode.
# No NemoClaw: no config seals, MCP integrity, or shields — Hermes owns ~/.hermes.
set -euo pipefail

export HOME="${HOME:-/sandbox}"
export HERMES_HOME="${HERMES_HOME:-/sandbox/.hermes}"
export PATH="/opt/hermes/.venv/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

if [ -f /run/openshell/provider.env ]; then
  set -a
  # shellcheck disable=SC1091
  . /run/openshell/provider.env
  set +a
fi

cd "$HOME"
exec hermes gateway run
