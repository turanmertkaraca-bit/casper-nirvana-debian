#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  CasperOS image builder — entry point.
#  Produces a dd-able raw disk image for the Casper Nirvana N220 / N240:
#    - Debian 13 trixie, amd64 userland, 32-bit UEFI bootloader (Bay Trail)
#    - Dual kernel: Debian 6.12 (default) + Ubuntu mainline 5.15.165 (fallback)
#    - User "lvy" (no password), Turkey locale, Hyprland session, pre-tuned
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
# A bare "exit code 1" in CI tells you nothing about which of the four stages
# died, and the stages echo hundreds of lines each. Announce the failure where
# it happens, and keep the stage's own exit status so apt's 100 still shows.
run_stage() {
    local n="$1" script="$2"; shift 2
    local rc=0 t0 t1
    t0=$(date +%s)
    info "stage $n/5: $script"
    bash "$script" "$@" || rc=$?
    t1=$(date +%s)
    # a stage that finishes implausibly fast did not do its work: stage 3 alone
    # downloads and unpacks ~1 GB, so seconds there means something was skipped
    printf '::notice::stage %s (%s) took %ss\n' \
        "$n" "${script##*/}" "$((t1 - t0))" >&2
    if [ "$rc" -ne 0 ]; then
        printf '\n\033[1;31m✗ STAGE %s FAILED (%s) with exit code %s\033[0m\n' \
            "$n" "$script" "$rc" >&2
        printf '\033[1;31m  the failing command is the last one printed above\033[0m\n' >&2
        # also as an annotation, so CI shows the stage without scrolling
        printf '::error::STAGE %s failed: %s (exit %s)\n' \
            "$n" "${script##*/}" "$rc" >&2
        exit "$rc"
    fi
    ok "stage $n/5 done in $((t1 - t0))s"
}

run_stage 1 "$SRC/01-prepare.sh"   --root "$ROOT" --img "$IMG" --size "$SIZE"
run_stage 2 "$SRC/02-bootstrap.sh" --root "$ROOT" --suite "$SUITE" --mirror "$MIRROR"
run_stage 3 "$SRC/04-assemble.sh"  --root "$ROOT" --img "$IMG" --build "$SRC"
run_stage 4 "$SRC/05-finalize.sh"  --root "$ROOT" --img "$IMG"

# ── surface the report ─────────────────────────────────────────────────────
# report.txt and the hypr layer's status only exist inside the artifact (or
# inside the image), so a build that "succeeds" while half its soft-failing
# steps did not run looks identical to a healthy one. Echo the lines that
# matter as annotations, which are readable without downloading anything.
REPORT_FILE="$(dirname "$IMG")/casper-build-report.txt"
if [ -f "$REPORT_FILE" ]; then
    info "build report: $REPORT_FILE"
    grep -E '^(WARN|FATAL|WINE|IMAGE_ROOTFS_BYTES|HYPR)' "$REPORT_FILE" 2>/dev/null | head -12 | \
        while IFS= read -r line; do printf '::warning::%s\n' "$line" >&2; done || true
else
    printf '::warning::no build report at %s\n' "$REPORT_FILE" >&2
fi
if [ -f "$ROOT/etc/casperos/hyprshell.status" ]; then
    printf '::warning::hyprshell: %s\n' \
        "$(tr '\n' ' ' < "$ROOT/etc/casperos/hyprshell.status" | cut -c1-200)" >&2
fi

ok "BUILD COMPLETE → ${IMG}"
info "report: $REPORT_FILE"
