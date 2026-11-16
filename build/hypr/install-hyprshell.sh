#!/usr/bin/env bash
# CasperOS — optional Hyprland + Caelestia shell layer.
#
# Runs INSIDE the image chroot, called at the end of 03-configure.sh.
#
# WHY THIS IS A SEPARATE SCRIPT WITH A PINNED TAG
# Caelestia's CMake hard-gates on Qt: `qt_standard_project_setup(REQUIRES 6.9)`
# from v1.2.0 onwards (verified in v1.2.0, v1.3.0 and v1.6.2), and trixie ships
# Qt 6.8.2 — no version of it is in trixie-backports either. From v1.2.0 the
# plugin also links libcava/aubio/libqalculate via pkg-config, and Debian has
# no libcava development package at all.
#
# v1.1.0 is therefore the only tag that can be built here: no Qt gate, and its
# plugin links nothing but Qt::Core/Qml/Gui/Concurrent. It is the last release
# from the era when quickshell 0.2.x was current, while Debian's quickshell is
# 0.3.0 (built against Qt 6.8.2, so the toolkit itself matches trixie) — that
# version skew is the main risk in this layer, and it shows up as QML errors
# in the session, not at build time.
#
# FAILURE POLICY
# Best effort, never fatal. If anything here fails the image is still a
# complete, bootable GNOME system: the reason goes to report.txt and to
# /etc/casperos/hyprshell.status, and the guarded autostart in
# /etc/xdg/hypr/hyprland.conf leaves a usable bare Hyprland session.
set -uo pipefail

REPORT=/build/report.txt
STATUS=/etc/casperos/hyprshell.status
CAELESTIA_TAG="v1.1.0"
CAELESTIA_REPO="https://github.com/caelestia-dots/shell.git"
QMLDIR="/usr/lib/x86_64-linux-gnu/qt6/qml"
LIBDIR="/usr/lib/caelestia"
FONTDIR="/usr/share/fonts/truetype/casper"

# Packages from trixie-backports: the compositor, the QML toolkit and the
# Hyprland desktop services. All confirmed present in trixie-backports.
BPO_PKGS=(
    hyprland
    quickshell
    hypridle
    hyprlock
    hyprpaper
    hyprpolkitagent
    xdg-desktop-portal-hyprland
    hyprland-qtutils
    hyprpicker
)

# Runtime helpers the shell calls, Qt Quick modules its QML imports, and the
# build toolchain. All confirmed present in trixie main.
TRIXIE_PKGS=(
    brightnessctl
    ddcutil
    lm-sensors
    qalc
    foot
    thunar
    swappy
    cmake
    ninja-build
    g++
    pkgconf
    git
    qt6-base-dev
    qt6-declarative-dev
    qt6-svg-dev
    libpipewire-0.3-dev
    libaubio-dev
    qml6-module-qtquick
    qml6-module-qtquick-controls
    qml6-module-qtquick-layouts
    qml6-module-qtquick-effects
    qml6-module-qtquick-shapes
    qml6-module-qtquick-templates
    qml6-module-qtquick-dialogs
    qml6-module-qtquick-window
    qml6-module-qtqml
    qml6-module-qt5compat-graphicaleffects
    fonts-cascadia-code
)

# Build-only packages, purged again afterwards (the 32 GB eMMC is not the
# constraint, but there is no reason to ship a compiler toolchain).
BUILD_ONLY=(cmake ninja-build g++ pkgconf git qt6-base-dev qt6-declarative-dev qt6-svg-dev libpipewire-0.3-dev libaubio-dev)

# Runtime libraries that only our hand-built binaries use: dpkg has no
# dependency edge for them, so `autoremove` would delete them the moment the
# -dev package is purged. Mark them manual first.
RUNTIME_KEEP=(libaubio5 libpipewire-0.3-0t64)

log()  { printf '  %s\n' "$*"; }

fail() {
    log "HYPRSHELL: $*"
    echo "HYPRSHELL-FAIL: $*" >> "$REPORT"
    printf 'failed: %s\n' "$*" > "$STATUS"
    exit 0
}

mkdir -p /etc/casperos

# ── 1. trixie-backports, pinned to priority 100 by 99-casper-backports ──────
log "adding trixie-backports (pinned: only what we explicitly ask for)"
cat > /etc/apt/sources.list.d/debian-backports.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

apt-get update -qq || fail "apt-get update with trixie-backports failed"

# ── 2. compositor + QML toolkit (backports) ────────────────────────────────
log "installing Hyprland + Quickshell from trixie-backports"
apt-get install -y -qq --no-install-recommends -t trixie-backports "${BPO_PKGS[@]}" \
    || fail "backports package install failed"

# ── 3. runtime helpers + build toolchain (trixie) ──────────────────────────
log "installing shell runtime helpers and build toolchain"
apt-get install -y -qq --no-install-recommends "${TRIXIE_PKGS[@]}" \
    || fail "trixie package install failed"

# ── 4. fonts ───────────────────────────────────────────────────────────────
# Every icon in Caelestia is a ligature glyph from Material Symbols, and that
# font is not packaged in Debian — without it the bar renders as tofu. Rubik
# is the default UI font and fonts-rubik does not exist on trixie either.
# Both URLs are pinned raw files, not release assets that can be re-tagged.
log "installing Material Symbols + Rubik"
mkdir -p "$FONTDIR"
curl -fsSL --max-time 180 -o "$FONTDIR/MaterialSymbolsOutlined.ttf" \
    "https://raw.githubusercontent.com/google/material-design-icons/master/variablefont/MaterialSymbolsOutlined%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf" \
    || fail "Material Symbols font download failed"
curl -fsSL --max-time 180 -o "$FONTDIR/Rubik.ttf" \
    "https://raw.githubusercontent.com/googlefonts/rubik/main/fonts/variable/Rubik%5Bwght%5D.ttf" \
    || fail "Rubik font download failed"
chmod 644 "$FONTDIR"/*.ttf
fc-cache -f >/dev/null 2>&1 || true

# ── 5. build Caelestia (pinned) ────────────────────────────────────────────
WORK=/tmp/caelestia-build
rm -rf "$WORK"
mkdir -p "$WORK"

log "cloning caelestia-shell $CAELESTIA_TAG"
git clone --depth 1 --branch "$CAELESTIA_TAG" "$CAELESTIA_REPO" "$WORK/src" >/dev/null 2>&1 \
    || fail "git clone of caelestia-shell $CAELESTIA_TAG failed"
CAELESTIA_SHA=$(git -C "$WORK/src" rev-parse --short HEAD)

# VERSION/GIT_REVISION are passed explicitly: the CMakeLists falls back to
# `git describe`, which a --depth 1 clone cannot answer.
log "configuring + building caelestia-shell $CAELESTIA_TAG ($CAELESTIA_SHA)"
cmake -B "$WORK/src/build" -G Ninja -S "$WORK/src" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/ \
    -DVERSION="${CAELESTIA_TAG#v}" \
    -DGIT_REVISION="$CAELESTIA_SHA" \
    -DDISTRIBUTOR=CasperOS \
    -DINSTALL_QMLDIR="${QMLDIR#/}" \
    -DINSTALL_LIBDIR="${LIBDIR#/}" \
    -DINSTALL_QSCONFDIR="etc/xdg/quickshell/caelestia" \
    > "$WORK/configure.log" 2>&1 || { tail -30 "$WORK/configure.log"; fail "cmake configure failed"; }

cmake --build "$WORK/src/build" > "$WORK/build.log" 2>&1 \
    || { tail -30 "$WORK/build.log"; fail "compile failed"; }

cmake --install "$WORK/src/build" > "$WORK/install.log" 2>&1 \
    || { tail -30 "$WORK/install.log"; fail "install failed"; }

# ── 6. verify what actually landed ─────────────────────────────────────────
[ -f "$QMLDIR/Caelestia/qmldir" ] || fail "Caelestia QML module missing after install"
[ -f /etc/xdg/quickshell/caelestia/shell.qml ] || fail "Caelestia shell.qml missing after install"
[ -x "$LIBDIR/version" ] || log "note: $LIBDIR/version helper not installed"
[ -x /usr/bin/qs ] || fail "quickshell binary missing (qs)"

# ── 7. drop the toolchain, keep the runtime ────────────────────────────────
log "purging build-only packages (keeping the runtime libs they pulled in)"
apt-mark manual "${RUNTIME_KEEP[@]}" >/dev/null 2>&1 || true
apt-get purge -y -qq "${BUILD_ONLY[@]}" >/dev/null 2>&1 || true
apt-get autoremove --purge -y -qq >/dev/null 2>&1 || true
rm -rf "$WORK"
apt-get clean

# ── 8. status ──────────────────────────────────────────────────────────────
log "OK: Caelestia $CAELESTIA_TAG ($CAELESTIA_SHA) -> $QMLDIR/Caelestia"
{
    printf 'ok: caelestia-shell %s (%s)\n' "$CAELESTIA_TAG" "$CAELESTIA_SHA"
    printf 'quickshell: %s\n' "$(dpkg-query -W -f='${Version}' quickshell 2>/dev/null || echo unknown)"
    printf 'hyprland:   %s\n' "$(dpkg-query -W -f='${Version}' hyprland 2>/dev/null || echo unknown)"
    printf 'note: NOT verified at runtime — requires on-device test\n'
} > "$STATUS"
printf 'HYPRSHELL-OK: caelestia %s (%s), quickshell %s, hyprland %s\n' \
    "$CAELESTIA_TAG" "$CAELESTIA_SHA" \
    "$(dpkg-query -W -f='${Version}' quickshell 2>/dev/null || echo unknown)" \
    "$(dpkg-query -W -f='${Version}' hyprland 2>/dev/null || echo unknown)" >> "$REPORT"
