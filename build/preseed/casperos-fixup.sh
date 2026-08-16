#!/bin/bash
# CasperOS fixup — turns a stock Debian 13 install into CasperOS.
# Works in two ways:
#   1. Automatically, via the installer's late_command (payload at /tmp/casperos)
#   2. Manually, after any Debian install:
#        git clone https://github.com/turanmertkaraca-bit/casper-nirvana-debian
#        cd casper-nirvana-debian && sudo bash build/preseed/casperos-fixup.sh
# Applies: package set, all configs, 5.15 fallback kernel, GRUB tuning,
#          services, plymouth theme, and the lvy user setup.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if [ -d /tmp/casperos ]; then
    B=/tmp/casperos
elif [ -f "$(dirname "$0")/../configs/etc/hostname" ]; then
    B="$(cd "$(dirname "$0")/../.." && pwd)"
    ln -sfn "$B/build/packages.list" "$B/packages.list" 2>/dev/null || true
else
    echo "ERROR: run from a repo checkout or with the /tmp/casperos payload" >&2
    exit 1
fi

log() { echo "casperos-fixup: $*"; }

# ── 1. apt + dpkg options, then the full package set ───────────────────────
log "configuring apt/dpkg"
cat > /etc/apt/apt.conf.d/99casper <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
DPkg::options:: "--force-confdef";
DPkg::options:: "--force-confold";
EOF
mkdir -p /etc/dpkg/dpkg.cfg.d
cp -a "$B/configs/etc/dpkg/dpkg.cfg.d/10-casper" /etc/dpkg/dpkg.cfg.d/

# ensure non-free-firmware is enabled for the base install to keep working
sed -i 's/^deb /deb /' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
grep -rq 'non-free-firmware' /etc/apt/sources.list.d/ || \
    sed -i '/^Components:/s/$/ non-free-firmware/' /etc/apt/sources.list.d/*.sources

log "apt update + installing package set (long)"
apt-get update -qq
apt-get install -y -qq --no-install-recommends $(grep -v '^#' "$B/packages.list" | grep -v '^$')

# ── 2. static configuration tree ───────────────────────────────────────────
log "applying configuration tree"
cp -a "$B/configs/etc/." /etc/
cp -a "$B/configs/usr/." /usr/
chmod 440 /etc/sudoers.d/90-casper-lvy
chmod +x /usr/local/bin/touchscreen-reset /usr/local/bin/touchscreen-watchdog \
         /usr/local/bin/casper-set-governor /usr/local/bin/casper-growroot \
         /usr/local/bin/casper-nvram 2>/dev/null || true

# ── 3. user lvy: drop the placeholder preseed password ─────────────────────
log "fixing user lvy (null password)"
passwd -d lvy
usermod -aG audio,video,input,adm,plugdev,dip lvy 2>/dev/null || true
mkdir -p /home/lvy/.config /etc/skel/.config
cp -a "$B/configs/home/skel/.config/monitors.xml" /home/lvy/.config/monitors.xml
cp -a "$B/configs/home/skel/.config/monitors.xml" /etc/skel/.config/monitors.xml
chown -R lvy:lvy /home/lvy
# GDM (login screen) gets the same landscape rotation
mkdir -p /var/lib/gdm3/.config
cp -a "$B/configs/home/skel/.config/monitors.xml" /var/lib/gdm3/.config/monitors.xml
chown -R Debian-gdm:Debian-gdm /var/lib/gdm3/.config 2>/dev/null || true

# ── 4. locale/keyboard defaults (already tr via preseed; make it stick) ────
log "locale/keyboard"
update-locale LANG=tr_TR.UTF-8 LANGUAGE=tr:en 2>/dev/null || true
setupcon --save 2>/dev/null || true

# ── 5. dconf system defaults + extension list ──────────────────────────────
log "dconf databases"
{
    echo "[org/gnome/shell]"
    uuids=""
    for d in /usr/share/gnome-shell/extensions/*/; do
        [ -f "$d/metadata.json" ] || continue
        u=$(grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' "$d/metadata.json" | head -1 | sed 's/.*"uuid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        [ -n "$u" ] || continue
        uuids="$uuids,'$u'"
    done
    [ -n "$uuids" ] && echo "enabled-extensions=[${uuids#,}]"
} > /etc/dconf/db/local.d/10-casper-extensions
dconf update

# ── 6. plymouth theme ──────────────────────────────────────────────────────
log "plymouth theme"
cp -a /usr/share/plymouth/themes/spinner/spinner-*.png /usr/share/plymouth/themes/casper-splash/ 2>/dev/null || true
plymouth-set-default-theme casper-splash 2>/dev/null || true

# ── 7. libinput quirk validation ───────────────────────────────────────────
if command -v libinput >/dev/null 2>&1; then
    libinput quirks validate >/dev/null 2>&1 \
        && log "libinput quirks valid" \
        || log "WARN: libinput quirk rejected"
fi

# ── 8. fallback kernel: Ubuntu mainline 5.15.165 ───────────────────────────
log "installing Ubuntu mainline 5.15.165 (fallback kernel)"
mkdir -p /root/k515
cd /root/k515
for f in \
    linux-image-unsigned-5.15.165-0515165-generic_5.15.165-0515165.202408190457_amd64.deb \
    linux-modules-5.15.165-0515165-generic_5.15.165-0515165.202408190457_amd64.deb; do
    [ -f "$f" ] || curl -fsSL -O "https://kernel.ubuntu.com/mainline/v5.15.165/amd64/$f"
done
dpkg -i *.deb
rm -rf /root/k515

# ── 9. GRUB: regenerate with our params, then per-kernel tweaks ────────────
log "grub"
update-grub
# append the legacy I2C params ONLY to the 5.15 entries
bash /tmp/casperos/grub-casper-postprocess.sh /boot/grub/grub.cfg || true
grub-script-check /boot/grub/grub.cfg || true

# ── 10. fstab: tmpfs /tmp ──────────────────────────────────────────────────
if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
    echo "tmpfs /tmp tmpfs defaults,noatime,size=512M,mode=1777 0 0" >> /etc/fstab
fi

# ── 11. services: enable / mask ────────────────────────────────────────────
log "services"
systemctl enable serial-getty@ttyS0.service 2>/dev/null || true
systemctl enable casper-touchscreen-watchdog.service 2>/dev/null || true
systemctl enable casper-cpu-governor.service 2>/dev/null || true
systemctl enable casper-growroot.service 2>/dev/null || true
systemctl enable casper-nvram.service 2>/dev/null || true
systemctl enable zramswap.service 2>/dev/null || true
systemctl enable earlyoom.service 2>/dev/null || true
systemctl enable fstrim.timer 2>/dev/null || true
systemctl enable power-profiles-daemon.service 2>/dev/null || true
for svc in \
    tracker-miner-fs-3.service tracker-miner-rss-3.service tracker-extract-3.service tracker-writeback-3.service \
    evolution-addressbook-factory.service evolution-calendar-factory.service evolution-source-registry.service \
    ModemManager.service fwupd.service unattended-upgrades.service \
    NetworkManager-wait-online.service apt-daily.service apt-daily-upgrade.service \
    apt-daily.timer apt-daily-upgrade.timer; do
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
done
systemctl set-default graphical.target 2>/dev/null || true

# ── 12. wine prefix (as lvy) — best effort ─────────────────────────────────
log "wine prefix (best effort)"
runuser -u lvy -- env HOME=/home/lvy WINEPREFIX=/home/lvy/.wine \
    DISPLAY= WINEDEBUG=-all WINEARCH=win32 wineboot -u >/dev/null 2>&1 || true
if [ -d /home/lvy/.wine/drive_c ]; then
    cat > /tmp/waudio.reg <<'EOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine\Drivers]
"Audio"="pulse"
EOF
    runuser -u lvy -- env HOME=/home/lvy WINEPREFIX=/home/lvy/.wine \
        WINEDEBUG=-all wine regedit /tmp/waudio.reg >/dev/null 2>&1 || true
    rm -f /tmp/waudio.reg
    chown -R lvy:lvy /home/lvy/.wine 2>/dev/null || true
fi

# ── 13. misc cleanup + live sysctl ─────────────────────────────────────────
sysctl -p /etc/sysctl.d/99-casper-perf.conf >/dev/null 2>&1 || true
rm -rf /root/.bash_history

log "fixup complete — CasperOS applied"
