#!/usr/bin/env bash
# Stage 5 — strip build residue, clear logs/machine-id, zero free space,
#           unmount, and report.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/lib.sh"

ROOT=""; IMG=""
while [ $# -gt 0 ]; do
    case "$1" in --root) ROOT="$2"; shift 2;; --img) IMG="$2"; shift 2;; *) shift;; esac
done

info "finalizing image"

# unbind the build dir and remove it
umount "$ROOT/build" 2>/dev/null || true
rm -rf "$ROOT/build"

# inside the image: strip everything not needed at runtime
rm -rf "$ROOT/var/lib/apt/lists" "$ROOT/var/cache/apt"
rm -f "$ROOT/root/k515"/*.deb 2>/dev/null || true
rmdir "$ROOT/root/k515" 2>/dev/null || true
find "$ROOT/var/log" -type f -delete 2>/dev/null || true
rm -f "$ROOT/root/.bash_history" "$ROOT/home/lvy/.bash_history"
: > "$ROOT/etc/machine-id"
rm -f "$ROOT/var/lib/systemd/random-seed"
rm -rf "$ROOT/tmp/"* 2>/dev/null || true

# zero free space so the image compresses well
info "zeroing free space (for compression)"
dd if=/dev/zero of="$ROOT/.zerofile" bs=1M status=none 2>/dev/null || true
rm -f "$ROOT/.zerofile"

ROOTFS_BYTES=$(du -sx "$ROOT" 2>/dev/null | awk '{print $1*1024}')

# unmount everything
sync
umount -R "$ROOT" 2>/dev/null || umount -l "$ROOT" 2>/dev/null || true
losetup -d "$(losetup -j "$IMG" | cut -d: -f1)" 2>/dev/null || true
sync

IMG_BYTES=$(stat -c %s "$IMG")
REPORT="$(dirname "$IMG")/casper-build-report.txt"
{
    echo "IMAGE_BYTES=$IMG_BYTES"
    echo "ROOTFS_BYTES=$ROOTFS_BYTES"
    echo "IMG=$IMG"
} >> "$REPORT"

ok "image size: $(numfmt --to=iec-i "$IMG_BYTES")  (rootfs used: $(numfmt --to=iec-i "$ROOTFS_BYTES"))"
info "build report: $REPORT"
