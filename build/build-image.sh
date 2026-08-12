#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  CasperOS image builder — entry point.
#  Produces a dd-able raw disk image for the Casper Nirvana N220 / N240:
#    - Debian 13 trixie, amd64 userland, 32-bit UEFI bootloader (Bay Trail)
#    - Dual kernel: Debian 6.12 (default) + Ubuntu mainline 5.15.165 (fallback)
#    - User "lvy" (no password), Turkey locale, GNOME/Wayland, pre-tuned
#  Requires: root, ~12 GB free disk, network. Tested on Debian/Ubuntu hosts.
#  Usage: sudo ./build-image.sh [--root DIR] [--img FILE] [--size 6G]
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="/tmp/casper-root"
IMG="/tmp/casper-n220.img"
SIZE="6G"
SUITE="trixie"
MIRROR="http://deb.debian.org/debian"

while [ $# -gt 0 ]; do
    case "$1" in
        --root)   ROOT="$2";  shift 2 ;;
        --img)    IMG="$2";   shift 2 ;;
        --size)   SIZE="$2";  shift 2 ;;
        --suite)  SUITE="$2"; shift 2 ;;
        --mirror) MIRROR="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# shellcheck source=lib.sh
source "$SRC/lib.sh"

[ "$(id -u)" = 0 ] || die "run as root: sudo $0 $*"
command -v curl >/dev/null || die "curl required"

info "CasperOS build starting: root=$ROOT img=$IMG size=$SIZE suite=$SUITE"
rm -rf "$ROOT" /tmp/casper-env.sh

# ── host dependencies ──────────────────────────────────────────────────────
if ! command -v mmdebstrap >/dev/null 2>&1 || ! command -v parted >/dev/null 2>&1; then
    info "Installing host build tools (mmdebstrap, parted, e2fsprogs, ...)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq mmdebstrap debootstrap debian-archive-keyring \
        parted dosfstools e2fsprogs xz-utils curl ca-certificates \
        qemu-system-x86 qemu-utils ovmf >/dev/null
fi
ok "host tools present"

# debootstrap script shim for newer suites (trixie = sid layout)
[ -e /usr/share/debootstrap/scripts/"$SUITE" ] || ln -sf sid /usr/share/debootstrap/scripts/"$SUITE"

# ── stages ─────────────────────────────────────────────────────────────────
bash "$SRC/01-prepare.sh"   --root "$ROOT" --img "$IMG" --size "$SIZE"
bash "$SRC/02-bootstrap.sh" --root "$ROOT" --suite "$SUITE" --mirror "$MIRROR"
bash "$SRC/04-assemble.sh"  --root "$ROOT" --img "$IMG" --build "$SRC"
bash "$SRC/05-finalize.sh"  --root "$ROOT" --img "$IMG"

ok "BUILD COMPLETE → ${IMG}"
info "report: $(dirname "$IMG")/casper-build-report.txt"
