#!/usr/bin/env bash
# Stage 2 — mmdebstrap a minimal amd64 trixie rootfs into the mounted image.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/lib.sh"

ROOT=""; SUITE="trixie"; MIRROR="http://deb.debian.org/debian"
while [ $# -gt 0 ]; do
    case "$1" in --root) ROOT="$2"; shift 2;; --suite) SUITE="$2"; shift 2;; --mirror) MIRROR="$2"; shift 2;; *) shift;; esac
done

info "Bootstrapping $SUITE (amd64, minbase) into $ROOT"
mmdebstrap \
    --variant=minbase \
    --arch=amd64 \
    --components="main,contrib,non-free,non-free-firmware" \
    --include="ca-certificates,debian-archive-keyring,locales" \
    --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
    --aptopt='APT::Install-Recommends "false";' \
    --aptopt='APT::Install-Suggests "false";' \
    "$SUITE" "$ROOT" "$MIRROR"
ok "bootstrap done"
