#!/bin/bash
# Prepare writable roots and virtio disks every boot.
# Mounts agent-sandbox metadata disk (serial sandboxmeta) then claim/secret
# disks from /etc/sandbox/volumes.json. Product-specific Hermes/OpenShell
# guest logic lives here (bootc image), not in the controller.
#
# KubeVirt Secret disks are iso9660 (iso9660_t). SELinux blocks systemd
# services from sourcing/reading those paths, so we stage-mount and copy
# onto normal filesystem locations under /etc.
set -euo pipefail

sysctl -q -w kernel.printk="3 4 1 7" 2>/dev/null || true

META_SERIAL="${SANDBOX_META_SERIAL:-sandboxmeta}"
META_DEST="${SANDBOX_META_MOUNT:-/etc/sandbox}"
VOLUMES_JSON="${SANDBOX_VOLUMES_JSON:-${META_DEST}/volumes.json}"
STAGE_ROOT="${SANDBOX_STAGE_ROOT:-/run/sandbox-disks}"

wait_for_virtio() {
  local serial="$1"
  local device="/dev/disk/by-id/virtio-${serial}"
  for _ in $(seq 1 60); do
    [ -e "$device" ] && break
    sleep 1
  done
  if [ ! -e "$device" ]; then
    echo "virtio disk serial=${serial} not found at $device" >&2
    return 1
  fi
  printf '%s' "$device"
}

mount_ro_stage() {
  local device="$1"
  local mount_path="$2"
  mkdir -p "$mount_path"
  if mountpoint -q "$mount_path" 2>/dev/null; then
    return 0
  fi
  if mount -t iso9660 -o ro,uid=0,gid=0,mode=0644 "$device" "$mount_path" 2>/dev/null; then
    return 0
  fi
  mount -o ro "$device" "$mount_path"
}

# Copy Secret/iso contents to a normal directory (skip KubeVirt ..data / ..YYYY dirs).
copy_secret_tree() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"
  local f base
  for f in "$src"/*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
      ..*) continue ;;
    esac
    if [ -f "$f" ]; then
      cp -f "$f" "$dst/$base"
    elif [ -d "$f" ]; then
      cp -a "$f" "$dst/$base"
    fi
  done
  # Prefer KubeVirt projected ..data symlinks if present (resolve real files).
  if [ -d "$src/..data" ]; then
    for f in "$src/..data"/*; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      cp -f "$f" "$dst/$base"
    done
  fi
}

mount_sandbox_meta() {
  local device stage
  device=$(wait_for_virtio "$META_SERIAL") || return 1
  stage="${STAGE_ROOT}/meta"
  mount_ro_stage "$device" "$stage"
  mkdir -p "$META_DEST"
  if [ -f "$stage/env" ]; then
    install -m 0600 "$stage/env" "${META_DEST}/env"
  elif [ -f "$stage/..data/env" ]; then
    install -m 0600 "$stage/..data/env" "${META_DEST}/env"
  else
    echo "sandbox meta disk missing env" >&2
    return 1
  fi
  if [ -f "$stage/volumes.json" ]; then
    install -m 0644 "$stage/volumes.json" "${META_DEST}/volumes.json"
  elif [ -f "$stage/..data/volumes.json" ]; then
    install -m 0644 "$stage/..data/volumes.json" "${META_DEST}/volumes.json"
  else
    echo "sandbox meta disk missing volumes.json" >&2
    return 1
  fi
  # Relabel so services can read under /etc.
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF "$META_DEST" 2>/dev/null || true
  fi
}

mount_pvc_disk() {
  local serial="$1"
  local mount_path="$2"
  local device seed
  device=$(wait_for_virtio "$serial") || return 1
  if ! blkid "$device" >/dev/null 2>&1; then
    mkfs.ext4 -F "$device"
  fi
  seed=$(mktemp -d)
  if [ -d "$mount_path" ] && ! mountpoint -q "$mount_path" 2>/dev/null; then
    tar -C "$mount_path" -cf - . 2>/dev/null | tar -C "$seed" -xpf - 2>/dev/null || true
  fi
  mkdir -p "$mount_path"
  if ! mountpoint -q "$mount_path" 2>/dev/null; then
    mount "$device" "$mount_path"
  fi
  if [ ! -f "$mount_path/.workspace-initialized" ]; then
    if [ -n "$(ls -A "$seed" 2>/dev/null)" ]; then
      tar -C "$seed" -cf - . | tar -C "$mount_path" -xpf -
    fi
    touch "$mount_path/.workspace-initialized"
  fi
  rm -rf "$seed"
}

mount_secret_disk() {
  local serial="$1"
  local mount_path="$2"
  local device stage
  device=$(wait_for_virtio "$serial") || return 1
  stage="${STAGE_ROOT}/secret-${serial}"
  # If a previous iso mount is still on the destination, move aside.
  if mountpoint -q "$mount_path" 2>/dev/null; then
    umount "$mount_path" || true
  fi
  mount_ro_stage "$device" "$stage"
  copy_secret_tree "$stage" "$mount_path"
  chmod -R a+rX "$mount_path" 2>/dev/null || true
  # OpenShell SA bootstrap JWT is for the supervisor only (IssueSandboxToken).
  # Do not leave it world-readable for the landlocked sandbox user.
  if [ "$serial" = "openshellsatoken" ] || [ "$mount_path" = "/var/run/secrets/openshell" ]; then
    find "$mount_path" -type f -name token -exec chmod 0400 {} + 2>/dev/null || true
  fi
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF "$mount_path" 2>/dev/null || true
  fi
}

mkdir -p "$STAGE_ROOT"
mount_sandbox_meta

PVC_PATHS=""
if [ -f "$VOLUMES_JSON" ]; then
  while IFS=$'\t' read -r source serial mount_path; do
    [ -n "$serial" ] || continue
    case "$source" in
      secret)
        mount_secret_disk "$serial" "$mount_path"
        ;;
      persistentVolumeClaim|"")
        mount_pvc_disk "$serial" "$mount_path"
        PVC_PATHS="${PVC_PATHS}${mount_path}"$'\n'
        ;;
      *)
        echo "unknown volumes.json source=${source} serial=${serial}; skipping" >&2
        ;;
    esac
  done < <(python3 - "$VOLUMES_JSON" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception as e:
    print(f"failed to parse {path}: {e}", file=sys.stderr)
    sys.exit(0)
for m in data or []:
    serial = m.get("serial") or ""
    mount = m.get("mountPath") or ""
    source = m.get("source") or "persistentVolumeClaim"
    if serial and mount:
        print(f"{source}\t{serial}\t{mount}")
PY
)
fi

tmpfs_dirs=""
for dir in /sandbox /opt/data; do
  if printf '%s' "$PVC_PATHS" | grep -qxF "$dir"; then
    continue
  fi
  tmpfs_dirs="$tmpfs_dirs $dir"
done
tmpfs_dirs="${tmpfs_dirs# }"

if [ -n "$tmpfs_dirs" ]; then
  # shellcheck disable=SC2086
  for dir in $tmpfs_dirs; do
    mkdir -p "$dir" 2>/dev/null || true
    if ! touch "$dir/.write-test" 2>/dev/null; then
      tmp=$(mktemp -d)
      cp -a "$dir/." "$tmp/" 2>/dev/null || true
      mount -t tmpfs tmpfs "$dir"
      cp -a "$tmp/." "$dir/" 2>/dev/null || true
      rm -rf "$tmp"
    else
      rm -f "$dir/.write-test"
    fi
  done
fi

# Layout only — do not seal trust anchors here. OpenShell's prepare_filesystem
# recursively chowns /sandbox, drops to sandbox, then Landlock + exec
# (same as the Pod path; no OPENSHELL_DEFER_PRIVILEGE_DROP).
chown root:sandbox /sandbox 2>/dev/null || true
chmod 1775 /sandbox 2>/dev/null || true
if [ -d /sandbox/.hermes ]; then
  chown -R sandbox:sandbox /sandbox/.hermes 2>/dev/null || true
  chown root:sandbox /sandbox/.hermes 2>/dev/null || true
  chmod 1775 /sandbox/.hermes 2>/dev/null || true
  if [ -e /sandbox/.hermes/.config-hash ]; then
    chown sandbox:sandbox /sandbox/.hermes/.config-hash 2>/dev/null || true
    chmod 640 /sandbox/.hermes/.config-hash 2>/dev/null || true
  fi
  if [ -e /sandbox/.hermes/.env ]; then
    chown sandbox:sandbox /sandbox/.hermes/.env 2>/dev/null || true
    chmod 640 /sandbox/.hermes/.env 2>/dev/null || true
  fi
fi
mkdir -p /run/nemoclaw /run/openshell /etc/openshell/auth /etc/openshell-tls/client
