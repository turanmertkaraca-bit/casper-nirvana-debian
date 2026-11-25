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
# The directory is conf.d, not initramfs.conf.d. mkinitramfs sources
# $CONFDIR/initramfs.conf and then every file in $CONFDIR/conf.d/* — a file in
# initramfs.conf.d is never read by anything (initramfs.conf(5): "Configuration
# options can be broken out into configuration snippets and placed in
# individual files in the /etc/initramfs-tools/conf.d directory"). It used to
# live in a directory of that name, so the tuning was silently dead and every
# initrd was built with the package defaults.
mkdir -p /etc/initramfs-tools/conf.d
cp -a "$B/configs/etc/initramfs-tools/conf.d/99-casper.conf" /etc/initramfs-tools/conf.d/
chmod 644 /etc/initramfs-tools/conf.d/99-casper.conf

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
# The Wi-Fi blob is the one this tablet cannot work without, and it lives at
# rtlwifi/rtl8723bs_nic.bin (the name the driver's request_firmware() uses).
# Checking only that the rtl_bt directory exists passed even when no Wi-Fi
# firmware was present at all.
[ -f /lib/firmware/rtlwifi/rtl8723bs_nic.bin ] \
    && log "OK rtl8723bs wifi firmware present" \
    || echo "WARN: rtlwifi/rtl8723bs_nic.bin missing — Wi-Fi will not come up" >> "$REPORT"
[ -f /lib/firmware/rtl_bt/rtl8723bs_fw.bin ] \
    && log "OK rtl8723bs bluetooth firmware present" \
    || echo "WARN: rtl_bt/rtl8723bs_fw.bin missing — Bluetooth will not come up" >> "$REPORT"

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
mkdir -p /home/lvy/.config
# The panel is physically portrait, so mutter has to rotate it 90`. This is
# GNOME's own rotation config and it has to be present in three places: the
# user, /etc/skel for future users, and GDM's home (the greeter reads its own
# copy, so without it the LOGIN SCREEN boots sideways).
cp -a "$B/configs/home/skel/.config/monitors.xml" /home/lvy/.config/monitors.xml
chown -R lvy:lvy /home/lvy
mkdir -p /etc/skel/.config
cp -a "$B/configs/home/skel/.config/monitors.xml" /etc/skel/.config/monitors.xml
mkdir -p /var/lib/gdm3/.config
cp -a "$B/configs/home/skel/.config/monitors.xml" /var/lib/gdm3/.config/monitors.xml
chown -R Debian-gdm:Debian-gdm /var/lib/gdm3/.config 2>/dev/null || true

# ── 8. dconf system defaults (UX + extensions + on-screen keyboard) ────────
# screen-keyboard-enabled=true is what brings back the on-screen keyboard that
# GNOME provides and that the Caelestia experiment lost. Discover the extension
# UUIDs that actually got installed rather than hardcoding names that may not
# exist in this release.
log "compiling dconf system databases"
{
    echo "[org/gnome/shell]"
    uuids=""
    for d in /usr/share/gnome-shell/extensions/*/; do
        [ -f "$d/metadata.json" ] || continue
        u=$(grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' "$d/metadata.json" | head -1 | sed 's/.*"uuid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        [ -n "$u" ] || continue
        uuids="$uuids,'$u'"
    done
    if [ -n "$uuids" ]; then
        echo "enabled-extensions=[${uuids#,}]"
    fi
} > /etc/dconf/db/local.d/10-casper-extensions
dconf update 2>/dev/null || true
# Compile the GDM greeter database too. The greeter reads DCONF_PROFILE=gdm,
# and until configs/etc/dconf/profile/gdm existed nothing referenced
# system-db:gdm, so the login-screen OSK setting was compiled and ignored.
dconf update -f 2>/dev/null || true
[ -x /usr/share/gdm/generate-config ] && /usr/share/gdm/generate-config >/dev/null 2>&1 || true

# ── 9. display manager: GDM on Wayland (touch-first) ───────────────────────
log "enabling gdm3 (GNOME session)"
# `systemctl enable gdm3.service` DOES NOTHING in trixie and returns 0 while
# printing only a warning: Debian's packaging (patch 92_systemd_unit.patch)
# strips even upstream's [Install] Alias=, because the display-manager.service
# alias is managed jointly by all DMs through a debconf question. So the unit
# has no [Install] section at all and enable is a total no-op — which is why
# `systemctl is-enabled display-manager.service` reported nothing.
#
# What actually selects the display manager in Debian is the debconf answer
# plus the symlink the postinst creates:
#   /etc/X11/default-display-manager  -> "gdm3"
#   /etc/systemd/system/display-manager.service -> gdm3.service
# and graphical.target has Wants=display-manager.service. Set both explicitly,
# because in a noninteractive chroot build the postinst's own
# `else rm -f $DEFAULT_SERVICE` branch can leave the symlink absent.
mkdir -p /etc/X11
printf '/usr/sbin/gdm3\n' > /etc/X11/default-display-manager
mkdir -p /etc/systemd/system
# Resolve the real unit rather than hardcoding a name: /usr/lib/systemd/system/
# gdm3.service is itself a symlink to gdm.service in trixie, and the unit name
# has changed across releases. Point display-manager.service at whichever exists.
GDM_UNIT=""
for u in /usr/lib/systemd/system/gdm3.service /usr/lib/systemd/system/gdm.service \
         /lib/systemd/system/gdm3.service /lib/systemd/system/gdm.service; do
    [ -e "$u" ] && { GDM_UNIT="$u"; break; }
done
if [ -n "$GDM_UNIT" ]; then
    ln -sf "$GDM_UNIT" /etc/systemd/system/display-manager.service
    log "display-manager.service -> $GDM_UNIT"
else
    echo "WARN: no gdm unit found — GNOME will not start automatically" >> "$REPORT"
fi
# Belt and braces: also record the debconf answer, so a later `dpkg-reconfigure
# x-display-manager` does not silently switch the default away.
echo "shared/default-x-display-manager select gdm3" | debconf-set-selections 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true
# GDM owns the VT it starts on; getty@tty1 fights it for the console.
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service 2>/dev/null || true
# Recovery console. GNOME is the only session, so this is the way back in if
# the shell ever fails to start.
systemctl enable getty@tty2.service 2>/dev/null || true

# ── 10. plymouth splash theme ──────────────────────────────────────────────
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
if ! compgen -G '*.deb' >/dev/null; then
    echo "FATAL: 5.15 kernel packages not downloaded" >> "$REPORT"
    exit 1
fi
dpkg --force-confdef --force-confold -i *.deb
# Leave the download directory before anything else: `cd /` keeps a later
# find(1) from failing with "Failed to save initial working directory" if this
# directory is ever removed while we are still standing in it.
cd /
# Ubuntu's mainline modules ship as *raw* .ko (428 MB unpacked) while Debian's
# own kernel ships the same kind of tree as .ko.xz (89 MB). Compressing them is
# ~300 MB off the rootfs with no module removed: kmod decompresses .ko.xz in
# userspace, and this image already depends on that (the flash ISO's busybox
# path loads .ko.xz too). depmod has to re-run afterwards so the module index
# points at the new filenames.
log "compressing 5.15 modules (428 MB of .ko -> .ko.xz)"
if find /lib/modules/5.15.165-0515165-generic -name '*.ko' -print -quit | grep -q .; then
    find /lib/modules/5.15.165-0515165-generic -name '*.ko' -print0 \
        | xargs -0 -r -n 64 -P "$(nproc 2>/dev/null || echo 2)" xz -9 --quiet || \
        echo "WARN: some 5.15 modules failed to compress" >> "$REPORT"
    depmod -a 5.15.165-0515165-generic 2>/dev/null || true
    log "OK 5.15 modules compressed ($(du -sh /lib/modules/5.15.165-0515165-generic 2>/dev/null | cut -f1))"
    # Rebuild after compressing: the initrd built by the package postinst holds
    # the *uncompressed* .ko copies, and depmod's index just changed under it.
    # Done here rather than relied on from the postinst, because a 5.15 Ubuntu
    # kernel on a Debian system is not the combination that postinst expects.
    update-initramfs -u -k 5.15.165-0515165-generic 2>/dev/null || \
        echo "WARN: could not regenerate the 5.15 initramfs" >> "$REPORT"
fi
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

# ── 12. sizes for the run report ───────────────────────────────────────────
# (There is no longer a build-from-source desktop layer: GNOME comes straight
# from the package set, so nothing here compiles anything.)
du -sx --exclude=build / 2>/dev/null | awk '{printf "IMAGE_ROOTFS_BYTES=%d\n", $1*1024}' >> "$REPORT" || true
log "configuration complete"
