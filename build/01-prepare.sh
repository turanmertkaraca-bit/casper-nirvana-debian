#!/usr/bin/env bash
# Stage 1 — create the raw image, partition it (GPT: FAT32 ESP + ext4 root),
#           format both partitions and mount the root for bootstrapping.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/lib.sh"

ROOT=""; IMG=""; SIZE="6G"
while [ $# -gt 0 ]; do
    case "$1" in --root) ROOT="$2"; shift 2;; --img) IMG="$2"; shift 2;; --size) SIZE="$2"; shift 2;; *) shift;; esac
done

rm -rf "$ROOT" && mkdir -p "$ROOT"

info "Creating raw image ${IMG} (${SIZE})"
truncate -s "$SIZE" "$IMG"
parted -s "$IMG" mklabel gpt
parted -s "$IMG" mkpart ESP fat32 1MiB 513MiB
parted -s "$IMG" set 1 esp on
parted -s "$IMG" mkpart root ext4 513MiB 100%

LOOP=$(losetup -f)
losetup -P "$LOOP" "$IMG"
ok "loop device: $LOOP (${LOOP}p1=ESP ${LOOP}p2=root)"

mkfs.vfat -F32 -n CASPER_ESP "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L casper-root "${LOOP}p2"
ok "formatted ESP (FAT32) + root (ext4)"

mount "${LOOP}p2" "$ROOT"
info "root partition mounted at $ROOT"

# persist build state for later stages
cat > /tmp/casper-env.sh <<EOF
ROOT="$ROOT"
IMG="$IMG"
LOOP="$LOOP"
EOF
