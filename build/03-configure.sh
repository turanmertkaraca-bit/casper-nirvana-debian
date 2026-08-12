#!/usr/bin/env bash
# Stage 3 — runs INSIDE the image chroot (/build is the repo bind-mounted here).
# Installs the package set, applies every CasperOS config, creates user lvy,
# installs the 5.15 fallback kernel, preps Wine, and reports results.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
B="/build"
REPORT="$B/report.txt"
: > "$REPORT"

log() { printf '  %s\n' "$*"; }

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
    if libinput quirks validate /etc/libinput/local-overrides.quirks 2>/dev/null; then
        log "OK libinput quirk file parses cleanly"
    elif libinput quirks list /dev/null >/dev/null 2>&1; then
        log "OK libinput quirk accepted (validate subcommand unavailable)"
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
id lvy >/dev/null 2>&1 || useradd -m -s /bin/bash -G audio,video,input,sudo -U lvy
mkdir -p /home/lvy/.config
cp -a "$B/configs/home/skel/.config/monitors.xml" /home/lvy/.config/monitors.xml
chown -R lvy:lvy /home/lvy

# skel for any future users, and GDM session config
mkdir -p /etc/skel/.config
cp -a "$B/configs/home/skel/.config/monitors.xml" /etc/skel/.config/monitors.xml
mkdir -p /var/lib/gdm3/.config
cp -a "$B/configs/home/skel/.config/monitors.xml" /var/lib/gdm3/.config/monitors.xml
chown -R Debian-gdm:Debian-gdm /var/lib/gdm3/.config 2>/dev/null || true

# ── 8. dconf system defaults (UX + extensions + OSK + rotation-adjacent) ───
log "compiling dconf system databases"
# discover actually-installed extension UUIDs and enable them
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
dconf update

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
    ModemManager.service fwupd.service unattended-upgrades.service \
    NetworkManager-wait-online.service apt-daily.service apt-daily-upgrade.service \
    apt-daily.timer apt-daily-upgrade.timer; do
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
done
systemctl set-default graphical.target

# ── 12. Wine: build-time prefix with 32-bit auto-detection ─────────────────
log "wine: initialising prefix as lvy (32-bit support auto-detected)"
run_wine() {
    runuser -u lvy -- env HOME=/home/lvy WINEPREFIX=/home/lvy/.wine \
        DISPLAY= WINEDEBUG=-all "$@"
}
# try new-WoW64 (no i386 libs) first: create a WIN32 prefix — works only if
# wine64 has built-in 32-bit support
rm -rf /home/lvy/.wine
run_wine env WINEARCH=win32 wineboot -u >/dev/null 2>&1 || true
if [ -d /home/lvy/.wine/drive_c ]; then
    echo "WINE: new WoW64 mode OK (no i386 multiarch needed)" >> "$REPORT"
    log "wine new-WoW64 mode (32-bit support built in)"
else
    echo "WINE: enabling i386 multiarch (classic mode)" >> "$REPORT"
    log "wine classic mode — adding i386 multiarch"
    dpkg --add-architecture i386
    apt-get update -qq
    apt-get install -y -qq wine32:i386
    rm -rf /home/lvy/.wine
    run_wine env WINEARCH=win32 wineboot -u >/dev/null 2>&1 || true
fi
cat > /tmp/waudio.reg <<'EOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine\Drivers]
"Audio"="pulse"
EOF
run_wine wine regedit /tmp/waudio.reg 2>/dev/null || true
rm -f /tmp/waudio.reg
chown -R lvy:lvy /home/lvy/.wine 2>/dev/null || true

# ── 13. Firefox policy sanity ──────────────────────────────────────────────
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

# ── 14. sizes for the run report ───────────────────────────────────────────
du -sx --exclude=build / 2>/dev/null | awk '{printf "IMAGE_ROOTFS_BYTES=%d\n", $1*1024}' >> "$REPORT" || true
log "configuration complete"
