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

# ── point apt at the repository that is ON THE INSTALL MEDIUM ──────────────
# The install must not need the network. The ISO carries a flat apt repository
# ("casperos-offline") holding the exact closure of packages.list, so this
# replaces whatever d-i wrote instead of trying to reach deb.debian.org.
#
# [trusted=yes] because the repo is unsigned local media: there is no key to
# distribute, and the ISO itself is the trust boundary — the same model as any
# Debian install CD. `file:` keeps apt away from any proxy/DNS path.
OFFLINE_REPO=""
for cand in /media/cdrom /cdrom /media/cdrom0; do
    if [ -f "$cand/Packages.gz" ] || [ -f "$cand/Packages" ]; then
        OFFLINE_REPO="$cand"
        break
    fi
done

if [ -n "$OFFLINE_REPO" ]; then
    log "using the offline repository on the install medium: $OFFLINE_REPO"
    rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true
    printf 'deb [trusted=yes] file:%s ./\n' "$OFFLINE_REPO" > /etc/apt/sources.list
else
    # No medium found: fall back to the network rather than fail, but say so
    # loudly — this is the only path that can still need Wi-Fi.
    log "WARN: offline repository not found on the install medium — falling back to the network"
    # d-i's apt-setup writes a one-line /etc/apt/sources.list and this repo's
    # own image build writes deb822 .sources; handle both. (With an empty
    # sources.list.d/ the old code passed a literal glob to sed, which exited 2
    # and killed the fixup under set -e.)
    if [ -f /etc/apt/sources.list ]; then
        sed -i -E 's/^(deb[[:space:]].*[[:space:]]main)([[:space:]]|$)/\1 contrib non-free non-free-firmware\2/' \
            /etc/apt/sources.list 2>/dev/null || true
    fi
    for s in /etc/apt/sources.list.d/*.sources; do
        [ -e "$s" ] || continue
        grep -q 'non-free-firmware' "$s" 2>/dev/null && continue
        sed -i '/^Components:/s/$/ contrib non-free non-free-firmware/' "$s" 2>/dev/null || true
    done
fi

log "apt update + installing package set (long)"
apt-get update -qq
# The package set is installed from the medium when available. Anything the
# offline repo happens to lack still resolves from the mirror if there is one.
apt-get install -y -qq --no-install-recommends $(grep -v '^#' "$B_LIST" | grep -v '^$') || {
    log "ERROR: package set install failed"
    exit 1
}

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
         /usr/local/bin/casper-nvram 2>/dev/null || true

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

# ── 4b. GNOME: panel rotation + dconf defaults + on-screen keyboard ────────
# This block was MISSING from the installer path entirely. The image build
# configured GNOME and the installer did not, so an install done from the ISO
# produced a system with no rotation (sideways desktop), no dconf defaults and
# no on-screen keyboard. The two code paths have to agree.
log "GNOME rotation + dconf defaults"
MON="$CR/home/skel/.config/monitors.xml"
if [ -f "$MON" ]; then
    mkdir -p /home/lvy/.config
    cp -a "$MON" /home/lvy/.config/monitors.xml
    chown -R lvy:lvy /home/lvy 2>/dev/null || true
    mkdir -p /etc/skel/.config
    cp -a "$MON" /etc/skel/.config/monitors.xml
    # GDM reads its own copy; without it the LOGIN SCREEN boots sideways.
    mkdir -p /var/lib/gdm3/.config
    cp -a "$MON" /var/lib/gdm3/.config/monitors.xml
    chown -R Debian-gdm:Debian-gdm /var/lib/gdm3/.config 2>/dev/null || true
else
    log "WARN: monitors.xml missing from the payload — display will not rotate"
fi
# Enable whichever shell extensions actually got installed, rather than naming
# ones this Debian release may not ship.
if [ -d /usr/share/gnome-shell/extensions ]; then
    {
        echo "[org/gnome/shell]"
        uuids=""
        for d in /usr/share/gnome-shell/extensions/*/; do
            [ -f "$d/metadata.json" ] || continue
            u=$(grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' "$d/metadata.json" | head -1 \
                | sed 's/.*"uuid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            [ -n "$u" ] || continue
            uuids="$uuids,'$u'"
        done
        [ -n "$uuids" ] && echo "enabled-extensions=[${uuids#,}]"
    } > /etc/dconf/db/local.d/10-casper-extensions
fi
dconf update 2>/dev/null || true

# ── 5. display manager: GDM on Wayland (touch-first) ───────────────────────
log "gdm3"
systemctl enable gdm3.service 2>/dev/null || true
# GDM owns the VT it starts on; getty@tty1 would fight it for the console.
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service 2>/dev/null || true
systemctl enable getty@tty2.service 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true

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
    # The .debs are BAKED ONTO THE ISO (build/preseed/build-installer-iso.sh
    # puts them in /casperos/k515), so this never needs the network. Curling
    # kernel.ubuntu.com mid-install was both a hang risk and a hard dependency
    # on a third-party host being up.
    if [ ! -f "$f" ] && [ -f "$B/k515/$f" ]; then
        cp -a "$B/k515/$f" .
    fi
    if [ ! -f "$f" ]; then
        # Last resort only, and never fatal: a flaky network must not abort the
        # fixup (see the note in 03-configure.sh about `A || B` status).
        curl -fsSL --max-time 180 -O "https://kernel.ubuntu.com/mainline/v5.15.165/amd64/$f" || {
            log "WARN: $f is neither on the ISO nor downloadable — no 5.15 fallback kernel"
            K515_OK=0
        }
    fi
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
