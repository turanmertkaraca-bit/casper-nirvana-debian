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
else
    echo "ERROR: run from a repo checkout or with the /tmp/casperos payload" >&2
    exit 1
fi

# The two layouts have different SHAPES, not just different roots: the
# /tmp/casperos payload is flat (configs/, packages.list, grub-*.sh) while a
# git checkout keeps everything under build/. B alone cannot describe both, and
# the old code used $B/configs for both — so running the script from a checkout
# (the documented manual-install route) died on the very first cp. Resolve the
# two paths that differ, and fail loudly here rather than half-way through.
if [ -d "$B/configs" ]; then
    CR="$B/configs"
elif [ -d "$B/build/configs" ]; then
    CR="$B/build/configs"
else
    echo "ERROR: no configs/ tree under $B" >&2
    exit 1
fi
if [ -f "$B/grub-casper-postprocess.sh" ]; then
    PP="$B/grub-casper-postprocess.sh"
elif [ -f "$B/build/tools/grub-casper-postprocess.sh" ]; then
    PP="$B/build/tools/grub-casper-postprocess.sh"
else
    PP=""
fi
if [ -f "$B/packages.list" ]; then
    B_LIST="$B/packages.list"
elif [ -f "$B/build/packages.list" ]; then
    B_LIST="$B/build/packages.list"
else
    echo "ERROR: no packages.list under $B" >&2
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
cp -a "$CR/etc/dpkg/dpkg.cfg.d/10-casper" /etc/dpkg/dpkg.cfg.d/

# Ensure non-free-firmware is enabled for the base install to keep working.
# This has to cope with BOTH layouts: d-i's apt-setup writes a one-line
# /etc/apt/sources.list (`deb http://... trixie main...`), while this repo's
# own image build writes deb822 .sources files. The old code only looked at
# .sources: with an empty sources.list.d/ the glob did not expand, sed got a
# literal `*.sources` path, exited 2, and — being the last command of the `||`
# list under `set -e` — killed the whole fixup right here. On every real
# installer run that skipped the config tree, lvy, greetd, the 5.15 kernel,
# GRUB, fstab and all the services, while d-i still reported success.
if [ -f /etc/apt/sources.list ]; then
    sed -i -E 's/^(deb[[:space:]].*[[:space:]]main)([[:space:]]|$)/\1 contrib non-free non-free-firmware\2/' \
        /etc/apt/sources.list 2>/dev/null || true
fi
for s in /etc/apt/sources.list.d/*.sources; do
    [ -e "$s" ] || continue
    grep -q 'non-free-firmware' "$s" 2>/dev/null && continue
    sed -i '/^Components:/s/$/ contrib non-free non-free-firmware/' "$s" 2>/dev/null || true
done

log "apt update + installing package set (long)"
apt-get update -qq
apt-get install -y -qq --no-install-recommends $(grep -v '^#' "$B_LIST" | grep -v '^$')

# ── 2. static configuration tree ───────────────────────────────────────────
log "applying configuration tree"
cp -a "$CR/etc/." /etc/
cp -a "$CR/usr/." /usr/
# Upgraders: earlier versions installed the initramfs tuning into a directory
# mkinitramfs never reads (initramfs.conf.d instead of conf.d), so their
# initrds were built with gzip + MODULES=most. Drop the dead copy; the config
# tree above has already placed the working one in conf.d.
rm -rf /etc/initramfs-tools/initramfs.conf.d
chmod 440 /etc/sudoers.d/90-casper-lvy
chmod +x /usr/local/bin/touchscreen-reset /usr/local/bin/touchscreen-watchdog \
         /usr/local/bin/casper-set-governor /usr/local/bin/casper-growroot \
         /usr/local/bin/casper-nvram /usr/local/bin/casper-session 2>/dev/null || true

# ── 3. user lvy: drop the placeholder preseed password ─────────────────────
log "fixing user lvy (null password)"
passwd -d lvy
usermod -aG audio,video,input,adm,plugdev,dip lvy 2>/dev/null || true
mkdir -p /home/lvy/.config /etc/skel/.config
chown -R lvy:lvy /home/lvy

# ── 4. locale/keyboard defaults (already tr via preseed; make it stick) ────
log "locale/keyboard"
update-locale LANG=tr_TR.UTF-8 LANGUAGE=tr:en 2>/dev/null || true
setupcon --save 2>/dev/null || true

# ── 5. display manager: greetd (autologin -> Hyprland, no greeter, no GNOME) ─
log "greetd"
systemctl enable greetd.service 2>/dev/null || true
# greetd owns VT1; getty@tty1 would fight it for the console
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service 2>/dev/null || true
systemctl enable getty@tty2.service 2>/dev/null || true

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
# This whole section is best-effort: the 5.15 kernel is a *fallback*, and the
# 6.12 kernel from Debian is the default. Losing it must never abort the
# fixup, because everything after here (GRUB, fstab, services) still matters.
log "installing Ubuntu mainline 5.15.165 (fallback kernel)"
mkdir -p /root/k515
cd /root/k515
K515_OK=1
for f in \
    linux-image-unsigned-5.15.165-0515165-generic_5.15.165-0515165.202408190457_amd64.deb \
    linux-modules-5.15.165-0515165-generic_5.15.165-0515165.202408190457_amd64.deb; do
    # `A || B` takes B's status, so an unreachable kernel.ubuntu.com (curl -f
    # exits 22 on a 404) used to kill the whole fixup here.
    [ -f "$f" ] || curl -fsSL -O "https://kernel.ubuntu.com/mainline/v5.15.165/amd64/$f" || {
        log "WARN: could not download $f — no 5.15 fallback kernel"
        K515_OK=0
    }
done
# `dpkg -i *.deb` with an unexpanded glob passes the literal string '*.deb'
# and exits 2 — same defect class as the unexpanded sed above, and equally
# fatal under set -e.
if [ "$K515_OK" = 1 ] && compgen -G '*.deb' >/dev/null; then
    # --force-confdef/--force-confold: dpkg does not read apt's DPkg::options,
    # so pass them here or a conffile prompt can wedge an unattended install.
    dpkg --force-confdef --force-confold -i *.deb || {
        log "WARN: dpkg -i of the 5.15 kernel failed — no fallback kernel"
        K515_OK=0
    }
else
    log "WARN: 5.15 kernel packages unavailable — no fallback kernel"
    K515_OK=0
fi
# `cd /` FIRST: the next command deletes the directory we are standing in, and
# a deleted CWD makes find(1) fail at startup ("Failed to save initial working
# directory") — which silently skipped the module compression below, on every
# install, while the script still reported success.
cd /
rm -rf /root/k515
# See 03-configure.sh: Ubuntu's mainline modules are raw .ko (428 MB tree);
# compressing to .ko.xz is ~300 MB off the installed system and removes no
# module. depmod afterwards so the index matches the new filenames.
if [ "$K515_OK" = 1 ] && find /lib/modules/5.15.165-0515165-generic -name '*.ko' -print -quit 2>/dev/null | grep -q .; then
    log "compressing 5.15 modules"
    find /lib/modules/5.15.165-0515165-generic -name '*.ko' -print0 \
        | xargs -0 -r -n 64 -P "$(nproc 2>/dev/null || echo 2)" xz -9 --quiet 2>/dev/null || true
    depmod -a 5.15.165-0515165-generic 2>/dev/null || true
    # The package postinst built an initrd from the uncompressed modules;
    # regenerate so it matches the compressed tree and the new depmod index.
    update-initramfs -u -k 5.15.165-0515165-generic 2>/dev/null || true
fi

# ── 9. GRUB: regenerate with our params, then per-kernel tweaks ────────────
log "grub"
update-grub
# append the legacy I2C params ONLY to the 5.15 entries.
# $PP is resolved at the top for both layouts (flat payload vs git checkout) —
# the old hardcoded /tmp/casperos path does not exist in a checkout, and the
# `|| true` turned that into a silent no-op.
if [ -n "$PP" ]; then
    bash "$PP" /boot/grub/grub.cfg || log "WARN: grub post-process failed"
else
    log "WARN: grub post-process script not found — 5.15 entry may lack I2C params"
fi
grub-script-check /boot/grub/grub.cfg || log "WARN: grub.cfg failed validation"

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
# These two were enabled only by 03-configure.sh (the image path), so an
# install done through this fixup booted with no network manager and no clock
# sync — the two code paths had drifted.
systemctl enable NetworkManager.service 2>/dev/null || true
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
systemctl set-default graphical.target 2>/dev/null || true

# ── 12. misc cleanup + live sysctl ─────────────────────────────────────────
sysctl -p /etc/sysctl.d/99-casper-perf.conf >/dev/null 2>&1 || true
rm -rf /root/.bash_history

log "fixup complete — CasperOS applied"
# Sentinel for the test harness. The fixup's own output goes through d-i's
# `in-target`, which routes stdout/stderr to syslog — NOT to the serial
# console — so scraping the serial log for "fixup complete" can never work.
# A file on the installed disk is immune to log routing, and it is also the
# only evidence that survives d-i swallowing a non-zero exit.
: > /var/log/casperos-fixup.ok 2>/dev/null || true
