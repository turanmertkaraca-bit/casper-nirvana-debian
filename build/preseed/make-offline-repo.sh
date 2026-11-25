#!/usr/bin/env bash
# Build a self-contained apt repository from THIS machine's package downloads,
# so the installer can complete with no network at all.
#
# Why this exists
# ---------------
# The preseeded install runs `apt-get install <the whole package set>` inside
# the target. On the tablet that needs Wi-Fi, a working mirror and a stable
# connection for ~2 GB — and the RTL8723BS is exactly the chip that makes that
# unreliable. It also means an install cannot finish offline, which is what we
# want: the ISO carries everything.
#
# What it does
# ------------
#   1. mmdebstrap a throwaway trixie rootfs to learn the EXACT resolved
#      dependency closure of build/packages.list (same solver, same pins).
#   2. Copy those .deb files into a flat apt repository.
#   3. Write a Release file and sign nothing (the ISO is a local medium; apt is
#      told to trust it via the installer's own source list, see
#      build/preseed/preseed.cfg's apt-setup lines).
#
# Usage: sudo ./make-offline-repo.sh <outdir>
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: make-offline-repo.sh <outdir>}"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

info() { echo -e "\033[1;36m→\033[0m $*"; }
ok()   { echo -e "\033[1;32m✓\033[0m $*"; }
die()  { echo -e "\033[1;31m✗\033[0m $*" >&2; exit 1; }

command -v mmdebstrap >/dev/null || die "mmdebstrap required"
command -v apt-ftparchive >/dev/null || die "apt-utils required (apt-ftparchive)"

rm -rf "$OUT"
mkdir -p "$OUT/pool"

WORK=/tmp/casper-offline-work
rm -rf "$WORK"
mkdir -p "$WORK"

# ── 1. resolve the closure ─────────────────────────────────────────────────
# --variant=apt keeps it to the packages (no docs/config steps), and
# apt-get --download-only with the SAME options the build uses
# (--no-install-recommends, matching 03-configure.sh) reproduces exactly the set
# the image would install. NOTE: mmdebstrap already downloads into its own
# cache, but that cache is pruned; asking apt explicitly is what makes the set
# inspectable and copyable.
info "resolving the package closure for build/packages.list"
PKGS=$(grep -v '^#' "$SRC/build/packages.list" | grep -v '^[[:space:]]*$' | tr '\n' ' ')
[ -n "$PKGS" ] || die "packages.list produced an empty package set"

# A minimal bootstrap rootfs to run apt in, with the same components so that
# non-free-firmware (firmware-realtek, intel-microcode) resolves.
mmdebstrap \
    --variant=apt \
    --arch=amd64 \
    --components="main,contrib,non-free,non-free-firmware" \
    --include="ca-certificates,debian-archive-keyring" \
    --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
    trixie "$WORK/root" "http://deb.debian.org/debian" \
    >/dev/null

info "downloading the exact .deb set (this is the big step)"
# /proc must be mounted: apt reads /proc/mounts and dpkg-query wants a sane
# environment. Leaving it unmounted makes this step fail in confusing ways.
mount -t proc proc "$WORK/root/proc" 2>/dev/null || true
chroot "$WORK/root" /bin/sh -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    cat > /etc/apt/apt.conf.d/99offline <<'EOF'
APT::Install-Recommends \"false\";
APT::Install-Suggests \"false\";
EOF
    apt-get update -qq
    mkdir -p /debs
    # --download-only resolves the SAME way the real install will, so the repo
    # we produce cannot be missing a dependency the install later asks for.
    cd /debs
    apt-get install -y --no-install-recommends --download-only $PKGS
"
umount "$WORK/root/proc" 2>/dev/null || true

# ── 2. collect the .debs ───────────────────────────────────────────────────
info "collecting packages"
find "$WORK/root" -name '*.deb' -type f | while IFS= read -r deb; do
    cp -a "$deb" "$OUT/pool/"
done
# also take the apt cache, in case apt left some there instead
if [ -d "$WORK/root/var/cache/apt/archives" ]; then
    find "$WORK/root/var/cache/apt/archives" -name '*.deb' -type f -exec cp -a {} "$OUT/pool/" \; 2>/dev/null || true
fi
count=$(find "$OUT/pool" -name '*.deb' -type f | wc -l)
ok "$count .deb files"
[ "$count" -gt 100 ] || die "only $count packages collected — the closure did not resolve"

# ── 3. index it with apt-ftparchive ────────────────────────────────────────
# A flat repo (all .debs in one directory, Packages/Release at the root) is the
# simplest form apt understands and needs no dists/ tree.
info "indexing the repository"
cd "$OUT"
cat > apt-ftparchive.conf <<'EOF'
Dir {
  ArchiveDir ".";
};
Default {
  Packages::Compress ". gzip";
  Release::Compress ". gzip";
};
TreeDefault {
  Directory "pool";
};
EOF
apt-ftparchive -c apt-ftparchive.conf packages pool > Packages
gzip -9c Packages > Packages.gz
apt-ftparchive -c apt-ftparchive.conf release . > Release 2>/dev/null || \
    apt-ftparchive release . > Release
# No Release.gpg: the ISO is local install media. The preseed points apt at it
# with [trusted=yes] so no signature is needed, which is the same trust model
# as the rest of the installer media.
rm -f apt-ftparchive.conf

ok "offline repo: $OUT ($count packages, $(du -sh "$OUT" | cut -f1))"
ls -la "$OUT" | head
rm -rf "$WORK"
