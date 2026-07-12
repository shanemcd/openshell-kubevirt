#!/usr/bin/env bash
# Pin CRC agent-sandbox controller + OpenShell gateway to GHCR digests.
set -euo pipefail

TAG="${TAG:-nightly}"
OWNER="${OWNER:-shanemcd}"
CTRL_IMAGE="ghcr.io/${OWNER}/agent-sandbox-controller:${TAG}"
GW_IMAGE="ghcr.io/${OWNER}/openshell-gateway:${TAG}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need oc
need crane

echo "Resolving digests for tag '${TAG}'…"
CTRL_DIG="$(crane digest "${CTRL_IMAGE}")"
GW_DIG="$(crane digest "${GW_IMAGE}")"
CTRL_REF="ghcr.io/${OWNER}/agent-sandbox-controller@${CTRL_DIG}"
GW_REF="ghcr.io/${OWNER}/openshell-gateway@${GW_DIG}"

echo "Controller → ${CTRL_REF}"
oc -n agent-sandbox-system set image deploy/agent-sandbox-controller "*=${CTRL_REF}"
oc -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=180s

echo "Gateway    → ${GW_REF}"
oc -n openshell patch sts openshell --type=json -p="[{
  \"op\":\"replace\",
  \"path\":\"/spec/template/spec/containers/0/image\",
  \"value\":\"${GW_REF}\"
}]"
oc -n openshell delete pod openshell-0 --wait=false
oc -n openshell rollout status sts/openshell --timeout=300s

echo "Done. Smoke with:"
echo "  export OPENSHELL_GATEWAY=crc"
echo "  unset OPENSHELL_GATEWAY_ENDPOINT"
echo "  openshell gateway info && openshell sandbox list"
