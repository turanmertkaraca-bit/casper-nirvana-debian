#!/usr/bin/env bash
# Stage 3 — runs INSIDE the image chroot (/build is the repo bind-mounted here).
# Installs the package set, applies every CasperOS config, creates user lvy,
# installs the 5.15 fallback kernel, and reports results.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
B="/build"
REPORT="$B/report.txt"
: > "$REPORT"

log() { printf '  %s\n' "$*"; }

# ── failure reporting ──────────────────────────────────────────────────────
# This script runs chrooted inside the half-built image, where lib.sh's trap
# does not apply, and it is the longest, least observable stage: "exit 1"
# from here could be any of ~200 commands. Name the command that died, both
# on the console and as a CI annotation.
casper_inner_fail() {           # $1 = exit status, $2 = line number
    local rc="$1" line="$2"
    printf '\n\033[1;31m✗ FAILED (exit %s) inside the image at line %s\033[0m\n  command: %s\n' \
        "$rc" "$line" "$BASH_COMMAND" >&2
    printf '::error::03-configure exit %s at line %s -> %s\n' \
        "$rc" "$line" "$BASH_COMMAND" >&2
}
set -o errtrace 2>/dev/null || true
# $LINENO inside the trap is the line of the command that failed;
# ${BASH_LINENO[0]} is 0 for top-level commands, so it is useless here.
trap 'rc=$?; ln=$LINENO; casper_inner_fail "$rc" "$ln"' ERR

# ── 1. apt sources (deb822, updateable image) ──────────────────────────────
log "writing apt sources (trixie + security, all components)"
# remove the one-liner mmdebstrap wrote so there's no duplicate-source noise
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

# never prompt on conffile changes (keep the existing file) — so any config
# we pre-place can never wedge an install
cat > /etc/apt/apt.conf.d/99casper <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::AutoRemove::RecommendsImportant "false";
DPkg::options:: "--force-confdef";
DPkg::options:: "--force-confold";
EOF

# ── 2. dpkg + initramfs tuning BEFORE any packages are installed ──────────
# dpkg path-excludes (man/doc/locale) so even the first install is lean
mkdir -p /etc/dpkg/dpkg.cfg.d
cp -a "$B/configs/etc/dpkg/dpkg.cfg.d/10-casper" /etc/dpkg/dpkg.cfg.d/
mkdir -p /etc/initramfs-tools/initramfs.conf.d
cp -a "$B/configs/etc/initramfs-tools/initramfs.conf.d/99-casper.conf" /etc/initramfs-tools/initramfs.conf.d/
chmod 644 /etc/initramfs-tools/initramfs.conf.d/99-casper.conf

# ── 3. main package install ────────────────────────────────────────────────
log "apt update"
apt-get update -qq
log "installing package set (this is the long step)"
apt-get install -y -qq --no-install-recommends $(grep -v '^#' "$B/packages.list" | grep -v '^$') || \
    apt-get install -y --no-install-recommends $(grep -v '^#' "$B/packages.list" | grep -v '^$')

# ── 4. static configuration tree (configs/ mirrors the image root) ─────────
# applied AFTER package install: our tuned files simply win over the
# packages' defaults, and dpkg never sees a conflict.
log "applying static configuration tree"
cp -a "$B/configs/etc/." /etc/
cp -a "$B/configs/usr/." /usr/
chmod 440 /etc/sudoers.d/90-casper-lvy
# ensure our helper scripts are executable (dpkg/cp may have stripped modes)
chmod +x /usr/local/bin/touchscreen-reset /usr/local/bin/touchscreen-watchdog \
         /usr/local/bin/casper-set-governor /usr/local/bin/casper-growroot \
         /usr/local/bin/casper-nvram 2>/dev/null || true

# ── 5. firmware sanity ─────────────────────────────────────────────────────
[ -f /lib/firmware/intel/fw_sst_0f28.bin ] \
    && log "OK SST firmware present" \
    || echo "WARN: fw_sst_0f28.bin missing — audio card will not probe" >> "$REPORT"
ls /lib/firmware/rtl_bt >/dev/null 2>&1 \
    && log "OK rtl bluetooth firmware present" \
    || echo "WARN: rtl_bt firmware missing" >> "$REPORT"

# ── 5b. libinput quirk validation — a rejected file silently disables ALL
#       quirks, so the build FAILS instead of shipping a dead fix. ─────────
if command -v libinput >/dev/null 2>&1; then
    if libinput quirks validate; then
        log "OK libinput quirks database validates"
    else
        echo "FATAL: libinput rejected the quirk file" >> "$REPORT"
        exit 1
    fi
fi

# ── 6. locale / timezone / keyboard / hostname ─────────────────────────────
log "locale tr_TR.UTF-8 + en_US.UTF-8, tz Europe/Istanbul, kb tr"
sed -i 's/^# *tr_TR.UTF-8 UTF-8/tr_TR.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
grep -q '^tr_TR.UTF-8' /etc/locale.gen || echo "tr_TR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen >/dev/null
update-locale LANG=tr_TR.UTF-8 LANGUAGE=tr:en 2>/dev/null || true
ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
echo "Europe/Istanbul" > /etc/timezone
setupcon --save 2>/dev/null || true

# ── 7. user lvy ────────────────────────────────────────────────────────────
log "creating user lvy (no password, sudo NOPASSWD, audio/video/input)"
id lvy >/dev/null 2>&1 || useradd -m -s /bin/bash -G audio,video,input,sudo,adm,plugdev,dip -U lvy
# useradd leaves the password field unusable ("!") — make it a real null
# password so login works with just Enter (PAM nullok default on Debian)
passwd -d lvy
mkdir -p /home/lvy/.config /etc/skel/.config
chown -R lvy:lvy /home/lvy
# No monitors.xml: that was mutter's rotation config. Rotation lives in
# /etc/xdg/hypr/hyprland.conf now (monitor = , preferred, auto, 1, transform, 1),
# and mutter's file is ignored by Hyprland.

# ── 8. display manager: greetd, autologin straight into Hyprland ───────────
# No greeter and no GNOME. The session itself is a static file in the config
# tree (/etc/greetd/config.toml), so there is nothing to generate here — the
# machine boots, greetd drops to lvy and starts the compositor.
log "enabling greetd (autologin -> Hyprland)"
systemctl enable greetd.service 2>/dev/null || true
# nothing to disable: gdm3 is not installed in this image at all
# greetd owns VT1. Debian enables getty@tty1 by default, and two things
# fighting over one VT means greetd fails to take the console.
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service 2>/dev/null || true
# Text console as the recovery path: with no login screen left, this is the
# only way back in if the compositor refuses to start on the GPU.
systemctl enable getty@tty2.service 2>/dev/null || true

# ── 9. plymouth splash theme ───────────────────────────────────────────────
log "setting plymouth theme: casper-splash"
cp -a /usr/share/plymouth/themes/spinner/spinner-*.png /usr/share/plymouth/themes/casper-splash/ 2>/dev/null || true
plymouth-set-default-theme casper-splash 2>/dev/null || true
cat /etc/plymouth/plymouthd.conf

# ── 10. fallback kernel: Ubuntu mainline 5.15.165 ──────────────────────────
log "installing Ubuntu mainline 5.15.165 (fallback kernel)"
mkdir -p /root/k515
cd /root/k515
for f in \
    linux-image-unsigned-5.15.165-0515165-generic_5.15.165-0515165.202408190457_amd64.deb \
    linux-modules-5.15.165-0515165-generic_5.15.165-0515165.202408190457_amd64.deb; do
    [ -f "$f" ] || curl -fsSL -O "https://kernel.ubuntu.com/mainline/v5.15.165/amd64/$f"
done
dpkg -i *.deb
if find /lib/modules/5.15.165-0515165-generic -name 'r8723bs*' 2>/dev/null | grep -q .; then
    log "OK r8723bs driver present in 5.15 kernel"
else
    echo "WARN: r8723bs wifi driver NOT in 5.15 modules (wifi only on 6.12 kernel)" >> "$REPORT"
fi

# ── 11. services: enable / mask ────────────────────────────────────────────
log "configuring services"
systemctl enable serial-getty@ttyS0.service 2>/dev/null || true
systemctl enable casper-touchscreen-watchdog.service 2>/dev/null || true
systemctl enable casper-cpu-governor.service 2>/dev/null || true
systemctl enable casper-growroot.service 2>/dev/null || true
systemctl enable casper-nvram.service 2>/dev/null || true
systemctl enable zramswap.service 2>/dev/null || true
systemctl enable earlyoom.service 2>/dev/null || true
systemctl enable NetworkManager.service 2>/dev/null || true
systemctl enable fstrim.timer 2>/dev/null || true
systemctl enable power-profiles-daemon.service 2>/dev/null || true
systemctl enable systemd-timesyncd.service 2>/dev/null || true

for svc in \
    tracker-miner-fs-3.service tracker-miner-rss-3.service tracker-extract-3.service tracker-writeback-3.service \
    evolution-addressbook-factory.service evolution-calendar-factory.service evolution-source-registry.service \
    ModemManager.service fwupd.service unattended-upgrades.service apparmor.service \
    colord.service packagekit.service packagekit-offline-update.service \
    NetworkManager-wait-online.service apt-daily.service apt-daily-upgrade.service \
    apt-daily.timer apt-daily-upgrade.timer; do
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
done
systemctl set-default graphical.target

# ── 12. Firefox policy sanity ──────────────────────────────────────────────
# Debian's firefox-esr reads policies from /etc/firefox-esr (or the
# distribution dir next to the binary); put policies.json wherever fits.
FFP="/build/configs/usr/share/firefox-policies/policies.json"
if [ -d /etc/firefox-esr ]; then
    cp -a "$FFP" /etc/firefox-esr/policies.json
    log "OK firefox policies.json -> /etc/firefox-esr/"
elif [ -d /usr/lib/firefox-esr/distribution ]; then
    cp -a "$FFP" /usr/lib/firefox-esr/distribution/policies.json
    log "OK firefox policies.json -> /usr/lib/firefox-esr/distribution/"
else
    echo "WARN: firefox-esr not found — policies not applied" >> "$REPORT"
fi
[ -f /etc/firefox-esr/policies.json ] || [ -f /usr/lib/firefox-esr/distribution/policies.json ] \
    || echo "WARN: firefox policies.json missing" >> "$REPORT"

# ── 12b. optional Hyprland + Caelestia shell layer ────────────────────────
# Best-effort: writes to report.txt and never fails the build, so a shell that
# does not compile still leaves a bootable system (greetd falls back to a
# shell on VT1, and getty@tty2 is always available).
log "installing Hyprland + Caelestia shell layer (experimental)"
bash "$B/hypr/install-hyprshell.sh" || echo "WARN: hyprshell layer failed" >> "$REPORT"

# ── 13. sizes for the run report ───────────────────────────────────────────
du -sx --exclude=build / 2>/dev/null | awk '{printf "IMAGE_ROOTFS_BYTES=%d\n", $1*1024}' >> "$REPORT" || true
log "configuration complete"
