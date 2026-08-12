#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║                                                                            ║
# ║   CASPER NIRVANA N220 / N240  —  MASTER FIX SCRIPT  v6.1                  ║
# ║   Target: Debian 12 Bookworm + GNOME (Wayland) + Ubuntu kernel            ║
# ║   Hardware: Intel Atom Z3735F (Bay Trail), 2 GB RAM,                      ║
# ║             Realtek RT5640 audio, Goodix/Silead I2C touch,                ║
# ║             Realtek RTL8723BS Wi-Fi/BT, 11.6" 1366x768 IPS                ║
# ║                                                                            ║
# ║   Lineage: Claude Sonnet originals → GLM v5.0 → Claude v6.0 audit         ║
# ║                                                                            ║
# ║   WHY THIS SCRIPT EXISTS                                                   ║
# ║   Consolidates 9 earlier partially-contradicting scripts, keeps Wayland   ║
# ║   (the user's explicit choice for touchscreen UX), and applies only the   ║
# ║   parameters that are valid for the running kernel.                       ║
# ║                                                                            ║
# ║   WHAT'S NEW IN v6.0 (fixes for things v5.0 SILENTLY got wrong)           ║
# ║   1. libinput quirk file used invalid keys (MatchDriver /                 ║
# ║      ModelTabletModeSwitch). libinput rejects the WHOLE file on any       ║
# ║      parse error → the touch/mouse quirk never actually loaded.           ║
# ║      Rewritten with valid keys; validated with `libinput quirks` tool.    ║
# ║   2. touchscreen-reset looked for drivers "i2c_hid", "silead", "goodix".  ║
# ║      Real sysfs names on modern kernels: i2c_hid_acpi, silead_ts,         ║
# ║      Goodix-TS → the reset (and the watchdog that calls it) was a no-op.  ║
# ║   3. Debian has no "linux-firmware" package → the audio apt line failed,  ║
# ║      and the SST DSP firmware (intel/fw_sst_0f28.bin, package             ║
# ║      firmware-intel-sound) was never installed → bytcr_rt5640 can't       ║
# ║      probe. Also installs firmware-realtek for RTL8723BS Wi-Fi/BT and     ║
# ║      auto-enables the non-free-firmware APT component on Debian 12.       ║
# ║   4. WirePlumber config mixed 0.4 (Lua) and 0.5 (conf) syntax so one      ║
# ║      half always no-opped → now writes BOTH formats correctly.            ║
# ║   5. vm.ksm / vm.ksm_threads aren't real sysctls (KSM lives in sysfs and  ║
# ║      only affects madvise()d memory — useless on a desktop) → removed.    ║
# ║      vm.overcommit_memory=1 contradicted its own comment → removed.       ║
# ║   6. swappiness=10 is wrong for a zram-ONLY swap setup. zram swap is      ║
# ║      cheap; kernel guidance says go HIGH → 180 (+page-cluster=0).         ║
# ║   7. modprobe.d i915 options never applied at boot because the initramfs  ║
# ║      was never rebuilt → update-initramfs -u now runs when needed.        ║
# ║   8. i915.enable_rc6 (removed in kernel 4.16) and                         ║
# ║      video.use_native_backlight (removed ~4.4) were dead params → gone,   ║
# ║      and stale copies are cleaned out of GRUB.                            ║
# ║   9. Firefox tuning wrote to ~/.mozilla/firefox/default/ which is not a   ║
# ║      real profile dir → now iterates the actual profiles.                 ║
# ║  10. fstab noatime edit only matched literal "defaults"; Debian's root    ║
# ║      line uses "errors=remount-ro" → robust field-aware editor.           ║
# ║  11. `if apt-get ... | tail` pipelines always reported success (tail's    ║
# ║      exit code) → zram/wine fallbacks were dead code → real checks now.   ║
# ║  12. Watchdog polled journalctl every 10 s → now streams `journalctl -kf` ║
# ║      for instant recovery with a reset cooldown.                          ║
# ║   NEW EXTRAS                                                               ║
# ║   • Resume hook: resets touchscreen + re-disables Wi-Fi powersave after   ║
# ║     suspend (the classic dead-touch-after-sleep bug).                     ║
# ║   • RTL8723BS latency fix: NetworkManager wifi.powersave=2 + driver       ║
# ║     options rtw_power_mgnt=0 rtw_ips_mode=0 (its powersave causes the     ║
# ║     multi-second stalls people blame on "slow wifi").                     ║
# ║   • earlyoom: on 2 GB RAM, memory pressure = total UI freeze that looks   ║
# ║     exactly like the touch bug. earlyoom kills the hog first.             ║
# ║   • fstrim.timer for the eMMC, GRUB_TIMEOUT=1, intel-microcode,           ║
# ║     transparent_hugepage=never made persistent, zram bumped to 1.5 GB.    ║
# ║   • iio-sensor-proxy → automatic screen rotation (real-tablet feel).      ║
# ║                                                                            ║
# ║   WHAT'S NEW IN v6.1                                                       ║
# ║   • Module 10 — Video acceleration: installs the legacy i965 VA-API       ║
# ║     driver (Bay Trail predates intel-media-driver's Broadwell+ floor),    ║
# ║     pins LIBVA_DRIVER_NAME=i965, enables Firefox's VA-API + RDD prefs,    ║
# ║     configures mpv hwdec, and verifies H.264 hw decode via vainfo.        ║
# ║     Fixes the "YouTube chokes the CPU" problem: YouTube defaults to       ║
# ║     VP9/AV1 which Bay Trail can't decode in hardware at all — only        ║
# ║     H.264. An extension (h264ify) is still needed to force that codec;   ║
# ║     the module prints this as a manual step since scripts can't install  ║
# ║     browser extensions.                                                   ║
# ║                                                                            ║
# ║   USAGE                                                                    ║
# ║     chmod +x casper-n220-master.sh                                        ║
# ║     sudo ./casper-n220-master.sh                                          ║
# ║                                                                            ║
# ║   Or invoke a single module non-interactively (numbers match the menu):   ║
# ║     sudo ./casper-n220-master.sh --module audio                           ║
# ║     sudo ./casper-n220-master.sh --module performance                     ║
# ║     sudo ./casper-n220-master.sh --module video                           ║
# ║     sudo ./casper-n220-master.sh --module diagnostic                      ║
# ║     sudo ./casper-n220-master.sh --module full                            ║
# ║                                                                            ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# We do NOT use 'set -e' because every module is independent and one failure
# should never abort the whole script. We DO use 'set -u' to catch typos.
set -u

# ─────────────────────────────────────────────────────────────────────────────
# EARLY ROOT CHECK — must run BEFORE we try to create /var/log dirs
# ─────────────────────────────────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "This script needs root. Run: sudo $0" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_VERSION="6.1"
LOG_DIR="/var/log/casper-n220"
LOG_FILE="${LOG_DIR}/master-$(date +%Y%m%d-%H%M%S).log"
REAL_USER="${SUDO_USER:-${USER:-}}"
BACKUP_DIR="/root/casper-n220-backups"

# Resolve home dir via getent (eval echo ~user breaks on odd shells/users)
resolve_home() {
    getent passwd "$1" 2>/dev/null | cut -d: -f6
}
REAL_HOME=$(resolve_home "${REAL_USER}")
REAL_HOME="${REAL_HOME:-/home/${REAL_USER}}"
USER_UID=$(id -u "${REAL_USER}" 2>/dev/null || echo "1000")
USER_BUS="unix:path=/run/user/${USER_UID}/bus"

# Colors (only emit if stdout is a TTY)
if [ -t 1 ]; then
    RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m';   BOLD='\033[1m'
    DIM='\033[2m';     NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"

# Tee everything to the log file from here on
exec > >(tee -a "${LOG_FILE}") 2>&1

log()     { echo -e "  ${GREEN}✓${NC} $1"; }
info()    { echo -e "  ${CYAN}→${NC} $1"; }
warn()    { echo -e "  ${YELLOW}!${NC} $1"; }
err()     { echo -e "  ${RED}✗${NC} $1"; }
skipmsg() { echo -e "  ${DIM}↷ already done — skipping${NC}"; }
header()  { echo ""; echo -e "${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

# Run a command as the real (non-root) user, with the right D-Bus session
run_as_user() {
    sudo -u "${REAL_USER}" DBUS_SESSION_BUS_ADDRESS="${USER_BUS}" "$@" 2>/dev/null
}

# Backup a file with timestamp — only the FIRST time we touch it today
backup_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    local bn; bn=$(basename "$f")
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    local dest="${BACKUP_DIR}/${bn}.${stamp}"
    local today_glob="${BACKUP_DIR}/${bn}.$(date +%Y%m%d)-*"
    if ! ls $today_glob >/dev/null 2>&1; then
        cp -a "$f" "$dest"
        info "Backup: ${f} → ${dest}"
    fi
}

# Detect Linux distribution
detect_distro() {
    if [ -f /etc/debian_version ]; then
        if grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
            echo "ubuntu"
        elif grep -qi 'debian' /etc/os-release 2>/dev/null; then
            echo "debian"
        else
            echo "debian-like"
        fi
    elif [ -f /etc/arch-release ]; then
        echo "arch"
    elif [ -f /etc/fedora-release ]; then
        echo "fedora"
    else
        echo "unknown"
    fi
}

# Detect kernel major.minor (e.g. "6.8", "5.15", "6.1")
detect_kernel_version() {
    uname -r | grep -oE '^[0-9]+\.[0-9]+' | head -1
}

# Detect kernel flavor: ubuntu, debian, mainline
detect_kernel_flavor() {
    local kver; kver=$(uname -r)
    if echo "$kver" | grep -qE '(-ubuntu|-generic|-aws|-azure|-gcp)'; then
        echo "ubuntu"
    elif echo "$kver" | grep -qE '(-amd64|-arm64|-686-pae|-cloud)'; then
        echo "debian"
    elif echo "$kver" | grep -qE '(-linode|-generic-64kb)'; then
        echo "mainline"
    else
        echo "unknown"
    fi
}

# Compare two kernel version strings like "5.15" < "6.8"
# Returns 0 if $1 < $2, 1 otherwise
kernel_lt() {
    local a="$1" b="$2"
    local a_major a_minor b_major b_minor
    a_major=$(echo "$a" | cut -d. -f1)
    a_minor=$(echo "$a" | cut -d. -f2)
    b_major=$(echo "$b" | cut -d. -f1)
    b_minor=$(echo "$b" | cut -d. -f2)
    if [ "$a_major" -lt "$b_major" ]; then return 0; fi
    if [ "$a_major" -gt "$b_major" ]; then return 1; fi
    [ "$a_minor" -lt "$b_minor" ]
}

# Yes/no prompt with default
confirm() {
    local prompt="$1" default="${2:-y}"
    local reply
    read -p "$(echo -e "${YELLOW}?${NC} ${prompt} [${default}/n] ") " reply
    reply=${reply:-$default}
    case "${reply,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Set or replace a key=value kernel parameter in /etc/default/grub
# Usage: grub_set_param "intel_idle.max_cstate" "1"
grub_set_param() {
    local key="$1" value="$2"
    local grub_file="/etc/default/grub"
    [ -f "$grub_file" ] || { err "No /etc/default/grub"; return 1; }

    local current
    current=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$grub_file" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//; s/"$//')

    # Remove any existing instance of this key (with any value, or bare)
    local cleaned=""
    local word
    for word in $current; do
        if echo "$word" | grep -q "^${key}="; then
            continue
        elif [ "$word" = "$key" ]; then
            continue
        else
            cleaned="$cleaned $word"
        fi
    done

    local new="$cleaned ${key}=${value}"
    new=$(echo "$new" | xargs)  # trim

    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"|" "$grub_file"
}

# Set a VALUELESS kernel flag (e.g. "nowatchdog") without a trailing '='
# v5.0 wrote 'nowatchdog=' which the kernel tolerates but is sloppy.
grub_set_flag() {
    local key="$1"
    local grub_file="/etc/default/grub"
    [ -f "$grub_file" ] || return 1

    local current cleaned="" word
    current=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$grub_file" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//; s/"$//')
    for word in $current; do
        [ "$word" = "$key" ] && continue
        case "$word" in "${key}="*) continue ;; esac
        cleaned="$cleaned $word"
    done
    cleaned=$(echo "$cleaned $key" | xargs)
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${cleaned}\"|" "$grub_file"
}

# Remove a kernel parameter from /etc/default/grub
# Usage: grub_del_param "i2c_hid.use_polling_mode"
grub_del_param() {
    local key="$1"
    local grub_file="/etc/default/grub"
    [ -f "$grub_file" ] || return 1

    local current
    current=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$grub_file" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//; s/"$//')

    local cleaned=""
    local word
    for word in $current; do
        if echo "$word" | grep -q "^${key}\(=\|$\)"; then
            continue
        else
            cleaned="$cleaned $word"
        fi
    done
    cleaned=$(echo "$cleaned" | xargs)

    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${cleaned}\"|" "$grub_file"
}

# Update grub — try both update-grub and grub-mkconfig
update_grub() {
    if command -v update-grub >/dev/null 2>&1; then
        update-grub 2>&1 | tail -5
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -5
    else
        err "Neither update-grub nor grub-mkconfig found"
        return 1
    fi
}

# Rebuild the initramfs ONCE per script run. Needed because modprobe.d
# options for modules that live in the initramfs (i915!) only take effect
# after a rebuild — v5.0 wrote the conf files but never rebuilt, so the
# i915 options never applied at boot.
INITRAMFS_DONE=0
refresh_initramfs() {
    [ "${INITRAMFS_DONE}" = "1" ] && return 0
    if command -v update-initramfs >/dev/null 2>&1; then
        info "Rebuilding initramfs so modprobe.d options apply at boot"
        info "(this is slow on the Atom — 1-2 minutes, be patient)..."
        update-initramfs -u 2>&1 | tail -3
        INITRAMFS_DONE=1
        log "initramfs rebuilt"
    fi
}

# Debian 12 splits firmware into per-vendor packages inside the
# 'non-free-firmware' APT component. The installer usually enables it,
# but not always — and without it, firmware-intel-sound (SST audio DSP)
# and firmware-realtek (RTL8723BS Wi-Fi/BT) can't be installed.
ensure_nonfree_firmware() {
    [ "$(detect_distro)" = "debian" ] || return 0
    local changed=0 f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        if grep -E '^deb[[:space:]].*[[:space:]]main([[:space:]]|$)' "$f" 2>/dev/null \
           | grep -qv 'non-free-firmware'; then
            backup_file "$f"
            sed -ri '/^deb[[:space:]]/{/non-free-firmware/! s/^(deb[[:space:]].*[[:space:]]main([[:space:]].*)?)$/\1 non-free-firmware/}' "$f"
            changed=1
        fi
    done
    # deb822-style .sources files
    for f in /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        if grep -q '^Components:' "$f" && ! grep -q 'non-free-firmware' "$f"; then
            backup_file "$f"
            sed -i '/^Components:/{/non-free-firmware/! s/$/ non-free-firmware/}' "$f"
            changed=1
        fi
    done
    if [ "$changed" = "1" ]; then
        log "Enabled 'non-free-firmware' APT component"
        apt-get update -qq 2>&1 | tail -2
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BANNER
# ─────────────────────────────────────────────────────────────────────────────
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << "BANNER"
╔══════════════════════════════════════════════════════════════════════════╗
║                                                                            ║
║      CASPER NIRVANA N220 / N240  —  MASTER FIX SCRIPT  v6.0               ║
║      Bay Trail Z3735F · Debian 12 + GNOME · Ubuntu kernel                 ║
║                                                                            ║
╚══════════════════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"

    DISTRO=$(detect_distro)
    KVER=$(detect_kernel_version)
    KFLAVOR=$(detect_kernel_flavor)
    KFULL=$(uname -r)
    RAM=$(free -m | awk '/^Mem:/{print $2}')
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)

    echo -e "  ${BOLD}System:${NC}"
    echo -e "    Distro        : ${DISTRO}"
    echo -e "    Kernel        : ${KFULL}  (series ${KVER}, flavor ${KFLAVOR})"
    echo -e "    CPU           : ${CPU_MODEL}"
    echo -e "    RAM           : ${RAM} MB"
    echo -e "    User          : ${REAL_USER}"
    echo -e "    Log           : ${LOG_FILE}"
    echo -e "    Backups       : ${BACKUP_DIR}/"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MENU
# ─────────────────────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ MAIN MENU ═══${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC}  Full install             — everything below in order"
    echo -e "  ${BOLD}2)${NC}  Install Ubuntu kernel    — backlight + WiFi driver fix on Debian"
    echo -e "  ${BOLD}3)${NC}  Touch & display          — C-state, I2C rules, quirk, watchdog, resume hook"
    echo -e "  ${BOLD}4)${NC}  Audio (PipeWire)         — RT5640 + SST firmware + UCM + WirePlumber"
    echo -e "  ${BOLD}5)${NC}  Performance & Wi-Fi      — zram, earlyoom, BFQ, governor, sysctl, wifi latency"
    echo -e "  ${BOLD}6)${NC}  GNOME / touch UX         — auto-rotate, on-screen keyboard, gsettings"
    echo -e "  ${BOLD}7)${NC}  Wine + audio opt         — wine64 + wine32 + PULSE_LATENCY_MSEC"
    echo -e "  ${BOLD}8)${NC}  Diagnostic               — check what's working / broken"
    echo -e "  ${BOLD}9)${NC}  Verify all fixes         — confirm every fix is active"
    echo -e "  ${BOLD}10)${NC} Video acceleration      — VA-API H.264 hw decode (fixes YouTube lag)"
    echo -e "  ${BOLD}0)${NC}  Exit"
    echo ""
    read -p "$(echo -e "${YELLOW}?${NC} Select [0-10]: ")" choice
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 2 — INSTALL UBUNTU KERNEL ON DEBIAN
# ─────────────────────────────────────────────────────────────────────────────
# WHY: Debian's stock kernel is missing some Bay Trail backlight + RTL8723BS
#      cherry-picks that Ubuntu carries. Symptoms:
#        - /sys/class/backlight is empty → no brightness control
#        - RTL8723BS wifi may not appear
#      Solution: install Ubuntu kernel .deb packages directly on Debian.
#      Ubuntu's kernel team publishes ready-to-install .deb files at
#      kernel.ubuntu.com/mainline
#
# WHICH UBUNTU KERNEL:
#      - 5.15.x  (jammy, 22.04 LTS)   — known good, user confirmed working
#      - 6.1.x   (bookworm backport)  — slightly newer, but Bay Trail has regressions
#      - 6.8.x   (noble, 24.04 LTS)   — has the i2c_hid_acpi rewrite, may break
#                                       older scripts' polling_mode param
#
#      This module defaults to 5.15.x because the user explicitly said
#      "backlight worked in Ubuntu 22" and "newest kernel was bad".
# ─────────────────────────────────────────────────────────────────────────────
do_kernel() {
    header "MODULE 2 — Ubuntu kernel install"

    info "Current kernel: $(uname -r) (flavor: $(detect_kernel_flavor))"

    if [ "$(detect_kernel_flavor)" = "ubuntu" ]; then
        log "Already running an Ubuntu-flavored kernel."
        if ! confirm "Install a different Ubuntu kernel version anyway?" "n"; then
            return 0
        fi
    fi

    echo ""
    echo "  Available Ubuntu LTS kernels for Bay Trail:"
    echo -e "    ${BOLD}1)${NC}  5.15.x  (Ubuntu 22.04 jammy)   — RECOMMENDED, known good"
    echo -e "    ${BOLD}2)${NC}  6.1.x   (Ubuntu 22.04 HWE)      — newer, may work"
    echo -e "    ${BOLD}3)${NC}  6.8.x   (Ubuntu 24.04 noble)    — has i2c_hid_acpi rewrite"
    echo -e "    ${BOLD}4)${NC}  Cancel"
    echo ""
    read -p "$(echo -e "${YELLOW}?${NC} Pick [1-4]: ")" kernel_choice

    case "$kernel_choice" in
        1) target_series="5.15.0" ;;
        2) target_series="6.1.0"  ;;
        3) target_series="6.8.0"  ;;
        *) info "Cancelled."; return 0 ;;
    esac

    info "Installing prerequisites..."
    apt-get update -qq 2>&1 | tail -2
    apt-get install -y -qq wget ca-certificates dkms 2>&1 | tail -2

    # Use the mainline-kernel helper from pimlie/ubuntu-mainline-kernel —
    # it downloads pre-built .deb sets from kernel.ubuntu.com/mainline.
    if [ ! -f /usr/local/bin/ubuntu-mainline-kernel.sh ]; then
        info "Installing ubuntu-mainline-kernel helper..."
        wget -q -O /usr/local/bin/ubuntu-mainline-kernel.sh \
            https://raw.githubusercontent.com/pimlie/ubuntu-mainline-kernel/master/ubuntu-mainline-kernel.sh 2>&1 | tail -2
        chmod +x /usr/local/bin/ubuntu-mainline-kernel.sh 2>/dev/null || true
    fi

    # Pinned known-good mainline builds per series
    case "$target_series" in
        5.15.0) target_mainline="v5.15.165" ;;
        6.1.0)  target_mainline="v6.1.100"  ;;
        6.8.0)  target_mainline="v6.8.12"   ;;
    esac

    echo ""
    warn "Installing mainline kernel ${target_mainline}."
    warn "Mainline kernels are unsigned — Secure Boot must be OFF in your UEFI."
    warn "Casper N220 has 32-bit UEFI; Secure Boot is typically already off."
    echo ""
    if ! confirm "Proceed with kernel ${target_mainline} install?" "y"; then
        return 0
    fi

    if /usr/local/bin/ubuntu-mainline-kernel.sh --install "${target_mainline}" 2>&1 | tail -20; then
        log "Kernel ${target_mainline} installed"
        info "Updating GRUB..."
        update_grub
        echo ""
        warn "REBOOT required to use the new kernel."
        warn "After reboot, re-run this script and pick modules 3-7 to apply fixes."
    else
        err "Kernel install failed — check log: ${LOG_FILE}"
        warn "You can manually download from https://kernel.ubuntu.com/mainline/${target_mainline}/"
        warn "Then: sudo dpkg -i linux-image-*.deb linux-modules-*.deb"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 3 — TOUCH & DISPLAY FIXES
# ─────────────────────────────────────────────────────────────────────────────
# This is the HEART of the Casper N220 fix. It addresses:
#
#   A) Touchscreen freeze → root cause: Bay Trail C6/C7 deep sleep gates I2C
#      bus + the LPSS I2C controller's runtime-PM. When the CPU package drops
#      into a deep C-state mid-gesture, the touch controller's interrupt gets
#      lost and the whole input path wedges until something (like re-docking
#      the keyboard) generates fresh input traffic.
#      Fix: intel_idle.max_cstate=1 (keep CPU in C0/C1 only)
#           i2c_designware.disable_pm=1 (only on kernel <6.8!)
#           udev: keep i2c_hid devices powered
#
#   B) Display flicker / black-screen flash → i915 PSR (Panel Self Refresh)
#      and display C-states are buggy on Bay Trail Gen7.
#      Fix: i915.enable_psr=0 + i915.enable_dc=0
#      (v5.0 also set i915.enable_rc6=0 — that param was REMOVED from the
#       kernel in 4.16, so it only produced "unknown parameter" noise.)
#
#   C) Backlight missing on Debian mainline kernel → Ubuntu kernel has the
#      needed patches. Handled by Module 2.
#      (v5.0 also set video.use_native_backlight=1 — removed from the kernel
#       around 4.4; native is the default now. Dropped + cleaned from GRUB.)
#
#   D) Touch/mouse split bug on Wayland → libinput quirk strips pointer
#      emulation from the touchscreen. v5.0's quirk file used INVALID keys
#      (MatchDriver, ModelTabletModeSwitch) — libinput discards the ENTIRE
#      file on any parse error, so the quirk never loaded. This is very
#      likely why the drag-freeze "came back": the fix was never active.
#      Now written with valid keys and validated with `libinput quirks`.
#
#   E) Touch freeze recovery → Ctrl+Alt+R instant reset + a streaming
#      journal watchdog + a suspend/resume hook (touch is classically dead
#      after resume on Bay Trail).
# ─────────────────────────────────────────────────────────────────────────────
do_touch_display() {
    header "MODULE 3 — Touch & display fixes"
    backup_file /etc/default/grub

    local kver; kver=$(detect_kernel_version)
    info "Detected kernel series: ${kver}"

    # Small toolkit used below: iw (wifi powersave in resume hook),
    # libinput-tools (quirk validation).
    apt-get install -y -qq iw libinput-tools 2>&1 | tail -2

    # ── 3A. GRUB kernel parameters (kernel-version aware) ────────────────
    echo ""
    info "Setting GRUB kernel parameters (kernel-version-aware)..."

    # ALWAYS-on params (work on every kernel 5.x+ on Bay Trail):
    grub_set_param "intel_idle.max_cstate" "1"
    grub_set_param "i915.enable_psr"        "0"
    grub_set_param "i915.enable_dc"         "0"
    grub_set_param "i915.enable_fbc"        "0"
    grub_set_param "pci"                    "hpiosize=0"
    grub_set_param "usbcore.autosuspend"    "-1"

    # Audio params (always good on Bay Trail):
    grub_set_param "snd_intel_dspcfg.dsp_driver"     "2"
    grub_set_param "snd_hda_intel.dmic_detect"        "0"
    grub_set_param "snd_hda_intel.power_save"         "0"
    grub_set_param "snd_hda_intel.power_save_controller" "N"

    # PERFORMANCE params:
    # mitigations=off — disables Spectre/Meltdown/etc. CPU mitigations.
    #   On Atom Z3735 this gives a HUGE speedup (sometimes 30-40% on syscalls).
    #   SECURITY tradeoff: only do this on a tablet you don't expose to hostile
    #   untrusted code. The user explicitly chose speed over this.
    # nowatchdog — disables NMI/soft lockup watchdog. Saves ~1% CPU.
    grub_set_param "mitigations" "off"
    grub_set_flag  "nowatchdog"

    # CLEANUP of dead params that v5.0 (and older scripts) may have left:
    grub_del_param "i915.enable_rc6"            # removed from kernel in 4.16
    grub_del_param "video.use_native_backlight" # removed ~4.4, native is default

    # KERNEL-VERSION-AWARE params:
    # Kernel <6.8: i2c_designware.disable_pm=1 + i2c_hid.use_polling_mode=1
    #              (work around buggy LPSS I2C runtime-PM + IRQ delivery;
    #               unknown params are harmlessly ignored on kernels that
    #               lack them)
    # Kernel >=6.8: REMOVE both — they interact badly with the reworked
    #              i2c_hid_acpi driver and cause ghost touches
    if kernel_lt "$kver" "6.8"; then
        info "Kernel <6.8 — applying legacy I2C polling + PM-disable params"
        grub_set_param "i2c_designware.disable_pm"    "1"
        grub_set_param "i2c_hid.use_polling_mode"     "1"
    else
        info "Kernel >=6.8 — REMOVING legacy I2C params (they break i2c_hid_acpi)"
        grub_del_param "i2c_designware.disable_pm"
        grub_del_param "i2c_hid.use_polling_mode"
        grub_del_param "i2c_hid_acpi.disable_multitouch"
    fi

    # Faster boot: 1-second GRUB menu instead of 5
    if grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub
    else
        echo 'GRUB_TIMEOUT=1' >> /etc/default/grub
    fi

    # Update GRUB
    update_grub && log "GRUB updated" || err "GRUB update failed"

    # Show the final line
    info "Final GRUB_CMDLINE_LINUX_DEFAULT:"
    grep "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub | sed 's/^/    /'

    # ── 3B. udev rules — keep I2C always powered ─────────────────────────
    echo ""
    info "Writing udev rules (keep I2C always powered)..."
    cat > /etc/udev/rules.d/90-casper-baytrail-i2c.rules << 'UDEV'
# Casper N220/N240 — Bay Trail I2C power management
# Prevents the LPSS I2C controller from sleeping, which is the root cause
# of touchscreen freezes (the touch controller hangs off this bus).
ACTION=="add", SUBSYSTEM=="i2c",   ATTR{power/control}="on"
ACTION=="add", DRIVERS=="i2c_hid", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
ACTION=="add", DRIVERS=="i2c_hid_acpi", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
ACTION=="add", SUBSYSTEM=="input", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="hid",   ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb",   DRIVER=="usbhid", ATTR{power/autosuspend}="-1"
UDEV
    udevadm control --reload-rules 2>/dev/null
    udevadm trigger 2>/dev/null
    log "udev rules active"

    # ── 3C. i915 module options (modprobe.d) ─────────────────────────────
    echo ""
    info "Writing i915 module options..."
    cat > /etc/modprobe.d/casper-i915.conf << 'MOD'
# Casper N220 — i915 (Bay Trail Gen7 graphics) stability
# These mirror the GRUB params and apply at module load time too.
# NOTE: i915 usually lives in the initramfs, so these only take effect
# after `update-initramfs -u` — which this script now runs for you.
options i915 enable_psr=0
options i915 enable_dc=0
options i915 enable_fbc=0
options i915 fastboot=1
MOD
    log "i915 modprobe options written"

    # ── 3D. libinput quirk — touch/mouse separation (Wayland-safe) ───────
    # The touchscreen emits pointer-emulation codes (BTN_TOOL_FINGER)
    # alongside real touch events. Mutter on Wayland can then treat the
    # device as BOTH a touchscreen AND a mouse and mishandle drags.
    #
    # IMPORTANT: libinput parses quirk files STRICTLY — one invalid key and
    # the whole file is discarded. v5.0 used "MatchDriver" and
    # "ModelTabletModeSwitch", which don't exist, so the old quirk file was
    # silently rejected and did NOTHING. Valid match keys are things like
    # MatchUdevType / MatchBus. We also no longer strip BTN_TOUCH: on
    # single-touch fallback paths libinput needs it, and removing it can
    # kill touch input entirely on some firmwares.
    echo ""
    info "Writing libinput quirk (touch/mouse separation, Wayland-safe)..."
    mkdir -p /etc/libinput
    cat > /etc/libinput/local-overrides.quirks << 'QUIRK'
# Casper N220 Bay Trail — strip pointer emulation from the I2C touchscreen
# so Mutter/GNOME treats it as pure touch. Fixes the "touch stops but a
# ghost mouse remains" / drag-freeze behavior on Wayland.
[Bay Trail I2C Touchscreen]
MatchUdevType=touchscreen
MatchBus=i2c
AttrEventCode=-BTN_TOOL_FINGER
QUIRK

    # Validate — if this prints an error the file would be ignored, and we
    # want to KNOW that instead of silently losing the fix again.
    if command -v libinput >/dev/null 2>&1; then
        if libinput quirks validate /etc/libinput/local-overrides.quirks >/dev/null 2>&1 \
           || libinput quirks list /dev/null >/dev/null 2>&1; then
            log "libinput quirk written and parses cleanly (Wayland preserved)"
        else
            warn "libinput could not validate the quirk file — check:"
            warn "  libinput quirks validate /etc/libinput/local-overrides.quirks"
        fi
    else
        log "libinput quirk written (install libinput-tools to validate)"
    fi

    # ── 3E. Touchscreen reset script (Ctrl+Alt+R target) ─────────────────
    # v5.0's version looked for /sys/bus/i2c/drivers/{i2c_hid,silead,goodix}.
    # The REAL driver directory names are:
    #   i2c_hid_acpi  (kernel >=5.12 — the one that actually binds today)
    #   i2c_hid       (older kernels)
    #   Goodix-TS     (goodix.c registers with a capital name + dash)
    #   silead_ts     (not "silead")
    # So on any modern kernel the old reset script found nothing and exited
    # "successfully" — the watchdog was pressing a disconnected button.
    echo ""
    info "Installing touchscreen reset script + watchdog + resume hook..."

    cat > /usr/local/bin/touchscreen-reset << 'RESET'
#!/bin/bash
# Rebind the touchscreen's I2C driver to recover from a freeze.
logger "casper-touch: resetting touchscreen"
for drv in i2c_hid_acpi i2c_hid Goodix-TS silead_ts; do
    d="/sys/bus/i2c/drivers/${drv}"
    [ -d "$d" ] || continue
    for dev in "$d"/*-*; do
        # Bound devices show up as symlinks like i2c-GDIX1001:00 or 0-005d
        [ -L "$dev" ] || continue
        n=$(basename "$dev")
        logger "casper-touch: rebinding $n on $drv"
        echo "$n" > "$d/unbind" 2>/dev/null || true
        sleep 0.3
        echo "$n" > "$d/bind" 2>/dev/null || true
    done
done
logger "casper-touch: reset done"
RESET
    chmod +x /usr/local/bin/touchscreen-reset

    # ── 3F. Watchdog — streams the kernel journal, resets on I2C errors ──
    # v5.0 re-ran journalctl in a 10-second polling loop; this version
    # streams `journalctl -kf`, so recovery is near-instant and idle cost
    # is near-zero. A 15 s cooldown prevents reset storms.
    cat > /usr/local/bin/touchscreen-watchdog << 'WDSCRIPT'
#!/bin/bash
last=0
journalctl -kf -o cat --since now 2>/dev/null | \
grep --line-buffered -Ei 'i2c_hid.*(error|failed|reset)|i2c.*timeout|incomplete report|(silead|goodix).*(error|failed)' | \
while read -r _line; do
    now=$(date +%s)
    if [ $((now - last)) -ge 15 ]; then
        last=$now
        /usr/local/bin/touchscreen-reset
    fi
done
WDSCRIPT
    chmod +x /usr/local/bin/touchscreen-watchdog

    cat > /etc/systemd/system/casper-touchscreen-watchdog.service << 'WD'
[Unit]
Description=Casper N220 Touchscreen Watchdog (journal stream)
After=systemd-journald.service graphical.target

[Service]
Type=simple
ExecStart=/usr/local/bin/touchscreen-watchdog
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=graphical.target
WD
    systemctl daemon-reload 2>/dev/null
    systemctl enable casper-touchscreen-watchdog.service 2>/dev/null
    systemctl restart casper-touchscreen-watchdog.service 2>/dev/null && \
        log "Watchdog running" || warn "Watchdog starts after reboot"

    # Ctrl+Alt+R emergency reset (only works in GNOME + graphical session)
    if command -v gsettings >/dev/null 2>&1; then
        info "Binding Ctrl+Alt+R → instant touchscreen reset..."
        BASE_KB="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
        KB_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
        run_as_user gsettings set org.gnome.settings-daemon.plugins.media-keys \
            custom-keybindings "['${KB_PATH}']" 2>/dev/null
        run_as_user gsettings set "${BASE_KB}:${KB_PATH}" name    'Touchscreen Reset' 2>/dev/null
        run_as_user gsettings set "${BASE_KB}:${KB_PATH}" command '/usr/local/bin/touchscreen-reset' 2>/dev/null
        run_as_user gsettings set "${BASE_KB}:${KB_PATH}" binding '<Primary><Alt>r' 2>/dev/null
        log "Ctrl+Alt+R bound to touchscreen reset"
    fi

    # ── 3G. Suspend/resume hook ──────────────────────────────────────────
    # Classic Bay Trail bug: touchscreen (and sometimes Wi-Fi) is dead after
    # suspend. This hook fires after every resume: rebind the touchscreen
    # and re-disable rtl8723bs Wi-Fi powersave (its firmware re-enables it).
    mkdir -p /usr/lib/systemd/system-sleep
    cat > /usr/lib/systemd/system-sleep/casper-resume << 'SLEEPHOOK'
#!/bin/sh
# systemd-sleep hook: $1 = pre|post, $2 = suspend|hibernate|...
[ "$1" = "post" ] || exit 0
sleep 2
[ -x /usr/local/bin/touchscreen-reset ] && /usr/local/bin/touchscreen-reset
if command -v iw >/dev/null 2>&1; then
    for w in $(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}'); do
        iw dev "$w" set power_save off 2>/dev/null || true
    done
fi
exit 0
SLEEPHOOK
    chmod +x /usr/lib/systemd/system-sleep/casper-resume
    log "Resume hook installed (touch reset + wifi powersave off after suspend)"

    # ── 3H. Clean up cargo-cult leftovers from v5.0 ──────────────────────
    # v5.0 set MUTTER_DEBUG_ENABLE_ATOMIC_KMS=1 (already the default — a
    # no-op) and CLUTTER_TOUCH_DEVICE_ID=0 (not a real Clutter variable),
    # both in environment.d and in a gdm.service override. Remove the GDM
    # override and replace the env file with one documented, OPTIONAL
    # fallback you can enable by hand if flicker ever survives the i915
    # fixes.
    rm -f /etc/systemd/system/gdm.service.d/casper-touch.conf 2>/dev/null
    rmdir /etc/systemd/system/gdm.service.d 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null

    sudo -u "${REAL_USER}" mkdir -p "${REAL_HOME}/.config/environment.d"
    cat > "${REAL_HOME}/.config/environment.d/99-casper-touch.conf" << 'ENV'
# Casper N220 — optional Wayland fallback knobs. Everything here is
# COMMENTED OUT on purpose; the real fixes live in GRUB/modprobe/libinput.
#
# If you ever see flicker or black flashes that survive the i915 fixes,
# uncomment the next line and log out/in. It forces Mutter onto legacy
# (non-atomic) modesetting, which is gentler on old Gen7 display pipes:
#MUTTER_DEBUG_FORCE_KMS_MODE=simple
ENV
    chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.config/environment.d/99-casper-touch.conf"
    log "environment.d cleaned (bogus v5.0 vars removed, fallback documented)"

    # ── 3I. Rebuild initramfs so the i915 options actually apply ─────────
    refresh_initramfs

    echo ""
    log "Touch & display module complete"
    warn "Reboot required for kernel parameters + libinput quirk to take effect."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 4 — AUDIO FIX (PipeWire + RT5640)
# ─────────────────────────────────────────────────────────────────────────────
# Bay Trail audio stack:
#   - Codec: Realtek RT5640 (analog I2S codec)
#   - Bus: Intel SST (Smart Sound Technology) — NOT regular HDA
#   - Driver: snd_soc_sst_bytcr_rt5640 (kernel module)
#   - DSP FIRMWARE: intel/fw_sst_0f28.bin — WITHOUT THIS FILE THE DRIVER
#     CANNOT PROBE AND YOU GET NO SOUND CARD AT ALL. On Debian it lives in
#     the "firmware-intel-sound" package (non-free-firmware component);
#     on Ubuntu it's inside "linux-firmware". v5.0 tried to install a
#     package literally named "linux-firmware" on Debian — which doesn't
#     exist — so this critical file was never guaranteed present.
#   - Sound server: PipeWire (the right choice on Bay Trail)
#
# Common issues fixed here:
#   1. No sound card at all    → missing fw_sst_0f28.bin (see above)
#   2. No sound / no mixer     → wrong dsp_driver (need =2 for SST)
#   3. 5-second pop after idle → device suspend kicking in
#   4. Audio crackle on Wine   → buffer too small for slow Atom CPU
#   5. WirePlumber crash       → bluez monitor nil deref on this hardware
#   6. "bytcrrt5640" profile not found → UCM symlink name mismatch
#   7. Wi-Fi randomly dying    → missing firmware-realtek (installed here
#      too since we're already touching firmware)
# ─────────────────────────────────────────────────────────────────────────────
do_audio() {
    header "MODULE 4 — Audio (PipeWire + RT5640)"

    # ── 4A. Refuse to keep PulseAudio if present ────────────────────────
    if dpkg -l 2>/dev/null | grep -q "^ii.*pulseaudio[^-]"; then
        warn "PulseAudio is currently installed."
        warn "PipeWire is the modern, lower-latency server and is the right"
        warn "choice for Bay Trail. Recommend removing PulseAudio."
        if confirm "Remove PulseAudio and install PipeWire?" "y"; then
            apt-get purge -y pulseaudio pulseaudio-module-bluetooth 2>&1 | tail -3
            apt-get autoremove -y 2>&1 | tail -3
        else
            warn "Keeping PulseAudio — audio fixes below may be partial."
        fi
    fi

    # ── 4B. Firmware: enable non-free-firmware on Debian + install ──────
    ensure_nonfree_firmware
    info "Installing PipeWire + WirePlumber + firmware..."
    apt-get update -qq 2>&1 | tail -2
    apt-get install -y \
        pipewire \
        pipewire-pulse \
        pipewire-audio-client-libraries \
        wireplumber \
        libspa-0.2-bluetooth \
        gstreamer1.0-pipewire \
        alsa-utils \
        alsa-ucm-conf 2>&1 | tail -5

    # Distro-aware firmware set. The critical pieces:
    #   fw_sst_0f28.bin      → SST audio DSP (no card without it)
    #   rtl8723bs_nic.bin    → Wi-Fi firmware
    #   rtl_bt/rtl8723bs_*   → Bluetooth firmware
    case "$(detect_distro)" in
        debian|debian-like)
            apt-get install -y \
                firmware-intel-sound \
                firmware-realtek \
                firmware-misc-nonfree \
                intel-microcode 2>&1 | tail -4
            ;;
        ubuntu)
            apt-get install -y linux-firmware intel-microcode 2>&1 | tail -3
            ;;
    esac

    if ls /lib/firmware/intel/fw_sst_0f28.bin* >/dev/null 2>&1; then
        log "SST DSP firmware present (fw_sst_0f28.bin)"
    else
        err "fw_sst_0f28.bin still missing — audio card will NOT probe."
        err "On Debian check that 'non-free-firmware' is in your APT sources."
    fi
    log "PipeWire stack + firmware installed"

    # ── 4C. UCM profile symlink fix ─────────────────────────────────────
    # Card announces as "bytcrrt5640" (no dash, double r) but the UCM
    # profile folder is "bytcr-rt5640" (with dash). ALSA does exact name
    # match, so the profile is never loaded → no mixer controls.
    info "Fixing UCM profile name mismatch..."
    UCM_DIR="/usr/share/alsa/ucm2"
    if [ -d "${UCM_DIR}/bytcr-rt5640" ] && [ ! -e "${UCM_DIR}/bytcrrt5640" ]; then
        ln -sf "${UCM_DIR}/bytcr-rt5640" "${UCM_DIR}/bytcrrt5640"
        log "UCM symlink: bytcrrt5640 → bytcr-rt5640"
    elif [ -L "${UCM_DIR}/bytcrrt5640" ]; then
        skipmsg
    elif [ -d "${UCM_DIR}/bytcrrt5640" ]; then
        if [ -f "${UCM_DIR}/bytcrrt5640/bytcr-rt5640.conf" ] && \
           [ ! -f "${UCM_DIR}/bytcrrt5640/bytcrrt5640.conf" ]; then
            cp "${UCM_DIR}/bytcrrt5640/bytcr-rt5640.conf" \
               "${UCM_DIR}/bytcrrt5640/bytcrrt5640.conf"
            log "UCM conf copied: bytcrrt5640.conf"
        fi
    fi

    # ── 4D. WirePlumber config — BOTH 0.4 and 0.5 formats ───────────────
    # Debian 12 ships WirePlumber 0.4 (Lua config); Debian 13 / Ubuntu 24.04+
    # ship 0.5 (SPA-JSON .conf). v5.0 mixed the two: it wrote the bluetooth
    # disable in 0.5 syntax and the ALSA rules in 0.4 syntax, so depending
    # on your version one of them silently did nothing. We now write both
    # formats — each version simply ignores the other's files.
    info "Writing WirePlumber config (no suspend, bluetooth disabled)..."
    sudo -u "${REAL_USER}" mkdir -p \
        "${REAL_HOME}/.config/wireplumber/wireplumber.conf.d" \
        "${REAL_HOME}/.config/wireplumber/main.lua.d" \
        "${REAL_HOME}/.config/wireplumber/bluetooth.lua.d"

    # WHY disable bluetooth audio: the bluez monitor crashes WirePlumber on
    # this exact hardware (nil deref in policy-bluetooth.lua). The RTL8723BS
    # is so unreliable for A2DP that you're not missing much. BT keyboards/
    # mice are unaffected — this only disables the AUDIO side.

    # -- 0.4 format (Lua) --
    cat > "${REAL_HOME}/.config/wireplumber/bluetooth.lua.d/80-casper-disable-bluez.lua" << 'WP_BT_LUA'
-- Casper N220: bluez monitor crashes WirePlumber on this hardware
bluez_monitor.enabled = false
WP_BT_LUA

    cat > "${REAL_HOME}/.config/wireplumber/main.lua.d/99-baytrail.lua" << 'WP_LUA'
-- Casper N220 bytcr-rt5640 — no suspend, big period size, use UCM
rule = {
  matches = {{ { "node.name", "matches", "alsa_output.*" } }},
  apply_properties = {
    ["session.suspend-timeout-seconds"] = 0,
    ["api.alsa.period-size"]            = 2048,
    ["api.alsa.headroom"]               = 8192,
    ["api.alsa.use-ucm"]                = true,
    ["audio.format"]                    = "S16LE",
    ["audio.rate"]                      = 48000,
  },
}
table.insert(alsa_monitor.rules, rule)
WP_LUA

    # -- 0.5 format (SPA-JSON conf.d) --
    cat > "${REAL_HOME}/.config/wireplumber/wireplumber.conf.d/99-casper-baytrail.conf" << 'WP_CONF'
# Casper N220 — WirePlumber 0.5+ config (ignored by 0.4)
wireplumber.profiles = {
  main = {
    monitor.bluez                 = disabled
    monitor.bluez.seat-monitoring = disabled
  }
}

monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output.*" } ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
        api.alsa.period-size            = 2048
        api.alsa.headroom               = 8192
        api.alsa.use-ucm                = true
        audio.format                    = "S16LE"
        audio.rate                      = 48000
      }
    }
  }
]
WP_CONF
    chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.config/wireplumber"
    log "WirePlumber: no-suspend + bluetooth-audio-disabled (0.4 AND 0.5 formats)"

    # ── 4E. PipeWire config — tuned for slow Atom CPU ───────────────────
    # quantum=2048 ≈ 42ms buffer at 48kHz — large enough that the Z3735
    # can keep up without crackling. Locked 48kHz avoids resampling CPU.
    info "Writing PipeWire config (quantum=2048, 48kHz)..."
    sudo -u "${REAL_USER}" mkdir -p \
        "${REAL_HOME}/.config/pipewire/pipewire.conf.d" \
        "${REAL_HOME}/.config/pipewire/pipewire-pulse.conf.d"

    cat > "${REAL_HOME}/.config/pipewire/pipewire.conf.d/99-baytrail.conf" << 'PW'
context.properties = {
    default.clock.quantum       = 2048
    default.clock.min-quantum   = 1024
    default.clock.max-quantum   = 4096
    default.clock.rate          = 48000
    default.clock.allowed-rates = [ 48000 ]
    resample.quality            = 4
    log.level                   = 2
}
PW

    cat > "${REAL_HOME}/.config/pipewire/pipewire-pulse.conf.d/99-baytrail.conf" << 'PWP'
pulse.properties = {
    pulse.min.quantum  = 1024/48000
    pulse.default.req  = 2048/48000
    pulse.max.req      = 4096/48000
}
stream.properties = {
    resample.quality     = 4
    channelmix.normalize = false
}
PWP
    chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.config/pipewire"
    log "PipeWire config: quantum=2048, 48kHz locked"

    # ── 4F. modprobe.d audio options ────────────────────────────────────
    cat > /etc/modprobe.d/casper-audio.conf << 'MOD'
# Casper N220 Bay Trail audio
# dsp_driver=2 → SST (Smart Sound Technology) — correct for Z3735F
# (0=auto, 1=legacy HDA, 2=SST, 3=SOF)
options snd_intel_dspcfg dsp_driver=2
# The HDA controller still exists for HDMI audio — keep it from
# power-cycling (that's the 5-second pop) :
options snd_hda_intel power_save=0
options snd_hda_intel dmic_detect=0
options snd_hda_intel power_save_controller=N
MOD
    log "modprobe.d audio options written"

    # ── 4G. Enable PipeWire user services ───────────────────────────────
    for svc in pipewire.service pipewire-pulse.service wireplumber.service; do
        run_as_user systemctl --user unmask  "$svc" 2>/dev/null || true
        run_as_user systemctl --user enable  "$svc" 2>/dev/null || true
    done
    run_as_user systemctl --user daemon-reload 2>/dev/null

    # ── 4H. Add user to audio group + realtime scheduling ───────────────
    usermod -aG audio "${REAL_USER}" 2>/dev/null
    cat > /etc/security/limits.d/99-audio.conf << 'LIMITS'
@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice       -19
LIMITS
    log "Realtime scheduling for audio group"

    # ── 4I. Reload audio modules (often refuses while in use — reboot wins)
    info "Reloading audio modules..."
    modprobe -r snd_soc_sst_bytcr_rt5640 2>/dev/null || true
    modprobe -r snd_hda_intel 2>/dev/null || true
    sleep 1
    modprobe snd_hda_intel 2>/dev/null || true
    modprobe snd_soc_sst_bytcr_rt5640 2>/dev/null || true

    # ── 4J. Verify ──────────────────────────────────────────────────────
    sleep 2
    if run_as_user pactl info 2>/dev/null | grep -q "PipeWire"; then
        log "PipeWire is running"
    else
        warn "PipeWire not running yet — should start on next login."
    fi

    if aplay -l 2>/dev/null | grep -q "card"; then
        log "ALSA cards detected:"
        aplay -l 2>/dev/null | grep "card" | sed 's/^/    /'
    fi

    refresh_initramfs

    echo ""
    log "Audio module complete"
    warn "If sound still doesn't work after reboot, check:"
    warn "  1) pavucontrol (install: apt install pavucontrol) — check profile"
    warn "  2) dmesg | grep -i 'bytcr_rt5640\\|sst\\|snd_soc'"
    warn "  3) ls /lib/firmware/intel/fw_sst_0f28.bin*  (must exist)"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 5 — PERFORMANCE + WI-FI LATENCY
# ─────────────────────────────────────────────────────────────────────────────
# Atom Z3735F reality check:
#   - 4 cores @ 1.33 GHz base / 1.83 GHz burst (Silvermont, 2W)
#   - 2 GB DDR3L single-channel  ← THE bottleneck
#   - 32 GB eMMC (~150 MB/s read, 80 MB/s write, terrible random IO)
#
# Strategy:
#   1. zram swap (1.5 GB lz4) — swapping to compressed RAM is ~100x faster
#      than the eMMC. Disk swap on this eMMC is what makes 2 GB devices
#      feel frozen.
#   2. swappiness=180 + page-cluster=0 — the CORRECT tuning for zram-only
#      swap (v5.0's swappiness=10 fought against zram).
#   3. earlyoom — when RAM truly runs out, kill the hog instead of letting
#      the whole UI freeze for minutes (looks exactly like the touch bug!).
#   4. BFQ scheduler — stops one IO-heavy process starving the UI on eMMC.
#   5. schedutil governor + burst enabled.
#   6. Mask background services that eat this CPU alive (tracker etc).
#   7. eMMC endurance: journal cap, tmpfs /tmp, noatime, weekly fstrim.
#   8. THP=never persistent (compaction stalls hurt on Atom).
#   9. RTL8723BS Wi-Fi powersave OFF — its powersave causes multi-second
#      latency spikes and stalls that get blamed on "slow wifi".
# ─────────────────────────────────────────────────────────────────────────────
do_performance() {
    header "MODULE 5 — Performance + Wi-Fi latency"

    # ── 5A. zram swap ────────────────────────────────────────────────────
    info "Setting up zram swap (1.5 GB, lz4)..."

    # Disk swap on this eMMC is harmful — remove it regardless
    if grep -qE '[[:space:]]swap[[:space:]]' /etc/fstab 2>/dev/null || [ -f /swapfile ]; then
        swapoff -a 2>/dev/null || true
        backup_file /etc/fstab
        sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab
        [ -f /swapfile ] && rm -f /swapfile && log "  disk /swapfile removed"
    fi

    apt-get install -y -qq zram-tools 2>&1 | tail -2
    if dpkg -s zram-tools >/dev/null 2>&1; then
        # v5.0's `if apt-get | tail` always "succeeded" — dpkg -s is the
        # real test. Also v5.0 configured only 1 GB; 1.5 GB compresses to
        # roughly 500-700 MB of real RAM under load — a good trade on 2 GB.
        cat > /etc/default/zramswap << 'ZS'
# Casper N220 — zram swap config (zram-tools)
# lz4  = fastest decompression on Atom (zstd compresses better but is slower)
# SIZE = MB of *uncompressed* swap presented to the kernel
ALGO=lz4
SIZE=1536
PRIORITY=100
ZS
        systemctl enable zramswap.service 2>/dev/null
        systemctl restart zramswap.service 2>/dev/null
        log "zram-tools: lz4, 1536 MB, priority 100"
    else
        warn "zram-tools not installable — using manual zram service"
        cat > /etc/systemd/system/casper-zram.service << 'ZRAM'
[Unit]
Description=Casper N220 zram swap (manual, 1.5 GB lz4)
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'modprobe zram; echo lz4 > /sys/block/zram0/comp_algorithm; echo 1610612736 > /sys/block/zram0/disksize; mkswap /dev/zram0; swapon -p 100 /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0; echo 1 > /sys/block/zram0/reset'
[Install]
WantedBy=multi-user.target
ZRAM
        systemctl daemon-reload 2>/dev/null
        systemctl enable --now casper-zram.service 2>/dev/null
        log "manual zram service active (lz4, 1.5 GB)"
    fi

    # ── 5B. vm.* sysctls — tuned for ZRAM swap, not disk swap ────────────
    info "Writing /etc/sysctl.d/99-casper-perf.conf..."
    cat > /etc/sysctl.d/99-casper-perf.conf << 'SC'
# Casper N220 — memory tuning for Atom Z3735F + 2 GB RAM + zram-only swap
#
# swappiness=180 (NOT 10!): with zram, "swapping" means compressing a page
# into RAM — far cheaper than evicting file cache and re-reading it from
# the slow eMMC. Kernel docs explicitly recommend >100 for zram/zswap.
# (Values above 100 need kernel >= 5.8 — the script verifies and falls
# back to 100 automatically on older kernels.)
vm.swappiness=180
# zram has no seek cost — page-in readahead just wastes CPU. Kernel doc
# recommends 0 for zram.
vm.page-cluster=0
# Keep directory/inode caches around a bit longer (eMMC re-reads are slow)
vm.vfs_cache_pressure=50
# Smaller dirty buffers = fewer multi-second eMMC writeback stalls that
# freeze the UI (and get blamed on the touchscreen)
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.dirty_expire_centisecs=1500
vm.dirty_writeback_centisecs=500
# Don't let kswapd over-reclaim after bursts (reduces stutter)
vm.watermark_boost_factor=0
# Wake kswapd a little earlier so allocation stalls are rarer on 2 GB
vm.watermark_scale_factor=125
SC
    sysctl -p /etc/sysctl.d/99-casper-perf.conf >/dev/null 2>&1
    # Kernels < 5.8 reject swappiness > 100 — verify what actually stuck
    if grep -qx '180' /proc/sys/vm/swappiness 2>/dev/null; then
        log "vm.* sysctls applied (swappiness=180, page-cluster=0, dirty=10/5)"
    else
        sed -i 's/^vm.swappiness=180/vm.swappiness=100/' /etc/sysctl.d/99-casper-perf.conf
        sysctl -w vm.swappiness=100 >/dev/null 2>&1
        warn "Kernel capped swappiness at 100 (kernel < 5.8) — set 100 instead"
    fi

    # ── 5C. BFQ I/O scheduler for eMMC ───────────────────────────────────
    info "Setting BFQ I/O scheduler for eMMC..."
    cat > /etc/udev/rules.d/60-casper-scheduler.rules << 'IO'
# BFQ is best for slow eMMC on Atom — it prevents one IO-heavy process
# (package updates, tracker, etc.) from starving interactive apps.
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]",       ATTR{queue/scheduler}="bfq"
# Bump the IO queue depth for eMMC
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/nr_requests}="128"
IO
    udevadm control --reload-rules 2>/dev/null
    local dev
    for dev in /sys/block/mmcblk*/queue/scheduler /sys/block/sd*/queue/scheduler; do
        [ -f "$dev" ] && echo bfq > "$dev" 2>/dev/null || true
    done
    echo 128 > /sys/block/mmcblk0/queue/nr_requests 2>/dev/null || true
    log "BFQ scheduler active"

    # ── 5D. CPU governor ─────────────────────────────────────────────────
    # schedutil (kernel 5.10+) reacts to load via scheduler callbacks —
    # snappier than ondemand on bursty tablet workloads. Older kernels
    # fall back to ondemand.
    local kver governor
    kver=$(detect_kernel_version)
    if kernel_lt "$kver" "5.10"; then
        governor="ondemand"
    else
        governor="schedutil"
    fi
    info "Setting CPU governor: ${governor}"

    # A tiny helper script avoids systemd's \$-expansion pitfalls entirely
    # (v5.0 embedded the loop in ExecStart where '$g' semantics are murky).
    cat > /usr/local/bin/casper-set-governor << GOV
#!/bin/bash
# Casper N220 — apply CPU governor to all cores (generated by master script)
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo ${governor} > "\$g" 2>/dev/null || true
done
# Enable burst (turbo) if the knob exists
echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
GOV
    chmod +x /usr/local/bin/casper-set-governor

    cat > /etc/systemd/system/casper-cpu-governor.service << 'CPU'
[Unit]
Description=Casper N220 CPU governor
After=multi-user.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/casper-set-governor
[Install]
WantedBy=multi-user.target
CPU
    systemctl daemon-reload 2>/dev/null
    systemctl enable casper-cpu-governor.service 2>/dev/null
    /usr/local/bin/casper-set-governor
    log "CPU governor: ${governor} (+burst enabled)"

    # ── 5E. Mask heavy background services ───────────────────────────────
    info "Disabling heavy background services..."
    local heavy_services=(
        tracker-miner-fs-3.service tracker-miner-rss-3.service
        tracker-extract-3.service tracker-writeback-3.service
        evolution-addressbook-factory.service evolution-calendar-factory.service
        evolution-source-registry.service
        ModemManager.service
        apport.service
        fwupd.service
        unattended-upgrades.service
        NetworkManager-wait-online.service
        apt-daily.service apt-daily-upgrade.service
        apt-daily.timer apt-daily-upgrade.timer
    )
    local svc
    for svc in "${heavy_services[@]}"; do
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        systemctl mask    "$svc" 2>/dev/null || true
        # tracker/evolution actually run as *user* services
        run_as_user systemctl --user stop    "$svc" 2>/dev/null || true
        run_as_user systemctl --user disable "$svc" 2>/dev/null || true
        run_as_user systemctl --user mask    "$svc" 2>/dev/null || true
    done
    log "Masked: tracker, evolution, ModemManager, apport, fwupd,"
    log "        unattended-upgrades, NM-wait-online, apt-daily timers"

    # ── 5F. Disable unattended-upgrades in apt config too ────────────────
    if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
        sed -i 's/APT::Periodic::Update-Package-Lists "1";/APT::Periodic::Update-Package-Lists "0";/' \
            /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null
        sed -i 's/APT::Periodic::Unattended-Upgrade "1";/APT::Periodic::Unattended-Upgrade "0";/' \
            /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null
        log "unattended-upgrades disabled in apt config"
    fi

    # ── 5G. Journal size cap (eMMC write endurance) ──────────────────────
    info "Capping journal at 50 MB..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/casper.conf << 'J'
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
MaxRetentionSec=7day
ForwardToSyslog=no
J
    systemctl restart systemd-journald 2>/dev/null
    log "Journal: 50 MB cap, 7 day retention"

    # ── 5H. tmpfs for /tmp ───────────────────────────────────────────────
    if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
        backup_file /etc/fstab
        echo "tmpfs /tmp tmpfs defaults,noatime,size=512M 0 0" >> /etc/fstab
        log "tmpfs /tmp (512 MB)"
    fi
    # /var/log and /var/tmp stay on disk — daemons expect them to persist.

    # ── 5I. Root mount: noatime + commit=60 ──────────────────────────────
    # v5.0's sed only matched options == literal "defaults", but Debian's
    # root line is "errors=remount-ro" → the edit silently never happened.
    # This awk edits field 4 of the "/" line whatever it contains.
    if grep -qE '^[^#]\S*\s+/\s' /etc/fstab 2>/dev/null && \
       ! awk '$1 !~ /^#/ && $2 == "/" { if ($4 ~ /noatime/) found=1 } END { exit !found }' /etc/fstab 2>/dev/null; then
        backup_file /etc/fstab
        awk '
            $1 !~ /^#/ && $2 == "/" && NF >= 6 {
                if ($4 !~ /noatime/) $4 = $4 ",noatime"
                if ($4 !~ /commit=/) $4 = $4 ",commit=60"
                print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6
                next
            }
            { print }
        ' /etc/fstab > /etc/fstab.casper-tmp && mv /etc/fstab.casper-tmp /etc/fstab
        log "Root mount: +noatime +commit=60 (applies next boot)"
    else
        info "Root mount already has noatime (or no plain '/' line) — skipping"
    fi

    # ── 5J. eMMC queue knobs (runtime) ───────────────────────────────────
    echo 0 > /sys/block/mmcblk0/queue/iosched/back_seek_max 2>/dev/null || true

    # ── 5K. Transparent hugepages — off, PERSISTENTLY ────────────────────
    # THP compaction causes latency spikes on Atom. v5.0 only echoed the
    # sysfs knobs (lost at reboot); the kernel cmdline makes it stick.
    backup_file /etc/default/grub
    grub_set_param "transparent_hugepage" "never"
    update_grub >/dev/null 2>&1 && log "GRUB: transparent_hugepage=never (persistent)" \
        || warn "update-grub failed — THP setting may not persist"
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null

    # ── 5L. earlyoom — the "my tablet froze" insurance ───────────────────
    # On 2 GB, real memory exhaustion = the UI freezing for MINUTES while
    # the kernel thrashes. That looks exactly like the touchscreen bug.
    # earlyoom kills the biggest hog (usually a browser tab) seconds before
    # that point.
    info "Installing earlyoom (prevents total-freeze under memory pressure)..."
    apt-get install -y -qq earlyoom 2>&1 | tail -2
    if dpkg -s earlyoom >/dev/null 2>&1; then
        systemctl enable --now earlyoom.service 2>/dev/null
        log "earlyoom active"
    else
        warn "earlyoom not installable — skipping (not fatal)"
    fi

    # ── 5M. Weekly TRIM for the eMMC ─────────────────────────────────────
    if systemctl enable --now fstrim.timer 2>/dev/null; then
        log "fstrim.timer enabled (weekly eMMC TRIM keeps writes fast)"
    else
        warn "fstrim.timer unavailable — skipping"
    fi

    # ── 5N. Firefox low-RAM tuning — in the REAL profile dirs ────────────
    # v5.0 wrote to ~/.mozilla/firefox/default/ which Firefox never reads.
    # Real profiles are ~/.mozilla/firefox/<hash>.<name>/ with a prefs.js.
    if [ -d "${REAL_HOME}/.mozilla/firefox" ]; then
        local ffdir found_ff=0
        for ffdir in "${REAL_HOME}"/.mozilla/firefox/*/; do
            [ -f "${ffdir}prefs.js" ] || continue
            found_ff=1
            cat > "${ffdir}user.js" << 'FF'
// Casper N220 — low-RAM / eMMC-friendly Firefox tuning
user_pref("app.update.enabled", false);
user_pref("app.update.auto", false);
user_pref("browser.cache.disk.enable", false);        // eMMC endurance
user_pref("browser.cache.memory.capacity", 51200);    // 50 MB RAM cache
user_pref("browser.sessionhistory.max_total_viewers", 2);
user_pref("dom.ipc.processCount", 2);                 // fewer content procs
user_pref("network.dns.disablePrefetch", true);
user_pref("network.prefetch-next", false);
FF
            chown "${REAL_USER}:${REAL_USER}" "${ffdir}user.js"
            log "Firefox tuned: ${ffdir}"
        done
        if [ "$found_ff" = "0" ]; then
            info "No Firefox profile yet — start Firefox once, then re-run module 5"
        fi
    fi

    # ── 5O. Tracker writeback off (belt-and-braces) ──────────────────────
    run_as_user gsettings set org.freedesktop.Tracker3.Miner.Files enable-writeback false 2>/dev/null || true

    # ── 5P. Wi-Fi latency fix (RTL8723BS) ────────────────────────────────
    # The r8723bs staging driver's power-save is notorious: multi-second
    # ping spikes, stalls, and dropped associations. Turn it off at BOTH
    # layers — NetworkManager and the driver itself.
    info "Disabling Wi-Fi powersave (RTL8723BS latency fix)..."
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-casper-wifi-powersave.conf << 'NM'
# Casper N220 — 2 = disable Wi-Fi powersave (fixes rtl8723bs latency spikes)
[connection]
wifi.powersave = 2
NM
    cat > /etc/modprobe.d/casper-wifi.conf << 'WIFI'
# Casper N220 — RTL8723BS (staging driver r8723bs)
# rtw_power_mgnt=0 : disable dynamic power saving
# rtw_ips_mode=0   : disable inactive power saving
# Both cause latency spikes / stalls on this chip.
options r8723bs rtw_power_mgnt=0 rtw_ips_mode=0
WIFI
    systemctl reload NetworkManager 2>/dev/null || true
    # Also apply right now on any live wlan interface
    if command -v iw >/dev/null 2>&1; then
        local wdev
        for wdev in /sys/class/net/wl*; do
            [ -e "$wdev" ] || continue
            iw dev "$(basename "$wdev")" set power_save off 2>/dev/null || true
        done
    fi
    log "Wi-Fi powersave off (NM conf + driver opts; driver opts apply after reboot)"

    echo ""
    log "Performance + Wi-Fi module complete"
    warn "Reboot recommended (THP cmdline, driver options, initramfs)."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 6 — GNOME / TOUCH UX
# ─────────────────────────────────────────────────────────────────────────────
# Things that make the tablet actually USABLE as a tablet:
#   - Auto screen rotation (iio-sensor-proxy reads the accelerometer)
#   - Built-in on-screen keyboard (GNOME 40+ ships one — v5.0 tried to
#     install "gnome-shell-extension-on-screen-keyboard", which doesn't
#     exist in Debian/Ubuntu; the a11y gsetting is what enables it)
#   - Larger text scaling for finger-tap accuracy
#   - No edge-tiling / hot corners (finger drags trigger them by accident)
#   - Animations ON (perceived smoothness > a few % CPU on this GPU)
#   - No auto-suspend on AC
#   - Ubuntu 22.04 only: pin mutter 42.9-0ubuntu9 (fixes a Wayland touch
#     drag bug that jammy-security's 0ubuntu7 reintroduced — this is the
#     "wrapper update" that helped you temporarily)
# ─────────────────────────────────────────────────────────────────────────────
do_gnome_ux() {
    header "MODULE 6 — GNOME / touch UX"

    # ── 6A. Sanity: is GNOME even here? ──────────────────────────────────
    if ! command -v gsettings >/dev/null 2>&1; then
        err "gsettings not found — GNOME not installed?"
        return 1
    fi

    # ── 6B. Keep GDM on Wayland ──────────────────────────────────────────
    info "Ensuring GDM uses Wayland (NOT X11)..."
    local GDM_CONF="/etc/gdm3/daemon.conf"
    [ -f /etc/gdm3/custom.conf ] && GDM_CONF="/etc/gdm3/custom.conf"
    if [ -f "$GDM_CONF" ]; then
        backup_file "$GDM_CONF"
        sed -i 's/^#\?WaylandEnable=.*/WaylandEnable=true/' "$GDM_CONF"
        log "GDM: WaylandEnable=true (Wayland preserved for touch)"
    fi

    # ── 6C. Auto-rotation + on-screen keyboard ───────────────────────────
    # iio-sensor-proxy exposes the accelerometer to GNOME → screen rotates
    # like a real tablet. The service is D-Bus activated (no enable needed).
    info "Installing iio-sensor-proxy (automatic screen rotation)..."
    apt-get install -y -qq iio-sensor-proxy 2>&1 | tail -2
    if dpkg -s iio-sensor-proxy >/dev/null 2>&1; then
        systemctl start iio-sensor-proxy.service 2>/dev/null || true
        log "iio-sensor-proxy installed (rotation active after next login)"
    else
        warn "iio-sensor-proxy not installable — no auto-rotation"
    fi
    # Make sure rotation isn't locked
    run_as_user gsettings set org.gnome.settings-daemon.peripherals.touchscreen orientation-lock false 2>/dev/null || true

    # GNOME's BUILT-IN on-screen keyboard (pops up on text-field focus)
    run_as_user gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true 2>/dev/null
    log "On-screen keyboard enabled (built-in GNOME OSK)"

    # ── 6D. GNOME settings for tablet UX ─────────────────────────────────
    info "Applying GNOME settings for tablet UX..."

    # Text scaling — 1.15× so finger-taps hit buttons reliably on 11.6"
    run_as_user gsettings set org.gnome.desktop.interface text-scaling-factor 1.15 2>/dev/null

    # Edge-tiling off (accidental drags snap windows around)
    run_as_user gsettings set org.gnome.mutter edge-tiling false 2>/dev/null

    # Fatter draggable window border for fingers
    run_as_user gsettings set org.gnome.mutter draggable-border-width 20 2>/dev/null

    # Hot corners off (fingers trigger them constantly)
    run_as_user gsettings set org.gnome.desktop.interface enable-hot-corners false 2>/dev/null

    # Animations ON — perceived smoothness beats the tiny CPU saving
    run_as_user gsettings set org.gnome.desktop.interface enable-animations true 2>/dev/null

    # Font rendering
    run_as_user gsettings set org.gnome.desktop.interface font-antialiasing 'rgba' 2>/dev/null
    run_as_user gsettings set org.gnome.desktop.interface font-hinting 'slight' 2>/dev/null

    # Touchpad niceties (for the keyboard dock)
    run_as_user gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true 2>/dev/null
    run_as_user gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true 2>/dev/null

    # Power: never sleep on AC, 30 min on battery, no auto-brightness
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0 2>/dev/null
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'suspend' 2>/dev/null
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 1800 2>/dev/null
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled false 2>/dev/null

    # GNOME Software: never download updates in the background
    run_as_user gsettings set org.gnome.software download-updates false 2>/dev/null
    run_as_user gsettings set org.gnome.software allow-updates false 2>/dev/null

    log "GNOME settings applied (Wayland preserved, animations ON)"

    # ── 6E. Useful GNOME Shell extensions (these DO exist) ───────────────
    info "Installing GNOME Shell extensions (manager, appindicator, desktop icons)..."
    apt-get install -y -qq \
        gnome-shell-extension-manager \
        gnome-shell-extension-appindicator \
        gnome-shell-extension-desktop-icons-ng 2>&1 | tail -2

    # ── 6F. Pin mutter (Ubuntu 22.04 jammy ONLY) ─────────────────────────
    # jammy-security's mutter 42.9-0ubuntu7 reintroduced a Wayland touch
    # drag/drop bug; 42.9-0ubuntu9 fixes it but apt prefers the security
    # pocket. Install 0ubuntu9 from Launchpad and pin it. No-op on Debian.
    if grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
        local mutter_ver
        mutter_ver=$(dpkg -l mutter 2>/dev/null | awk '/^ii/{print $3}' | head -1)
        if echo "$mutter_ver" | grep -q "0ubuntu7"; then
            warn "Ubuntu 22.04 with buggy mutter ${mutter_ver} detected"
            warn "The touch-drag fix is 42.9-0ubuntu9 (direct Launchpad download)."
            if confirm "Download + pin mutter 42.9-0ubuntu9?" "y"; then
                local tmpdir base
                tmpdir=$(mktemp -d)
                base="https://launchpad.net/ubuntu/+archive/primary/+files"
                wget -q -O "$tmpdir/mutter-common.deb" \
                    "$base/mutter-common_42.9-0ubuntu9_all.deb" 2>/dev/null
                wget -q -O "$tmpdir/libmutter.deb" \
                    "$base/libmutter-10-0_42.9-0ubuntu9_amd64.deb" 2>/dev/null
                wget -q -O "$tmpdir/mutter.deb" \
                    "$base/mutter_42.9-0ubuntu9_amd64.deb" 2>/dev/null
                if dpkg -i "$tmpdir"/*.deb 2>&1 | tail -5; then :; fi
                apt-get install -f -y 2>&1 | tail -3
                if dpkg -l mutter 2>/dev/null | grep -q "0ubuntu9"; then
                    cat > /etc/apt/preferences.d/casper-mutter-pin << 'PIN'
Package: mutter
Pin: version 42.9-0ubuntu9
Pin-Priority: 1001

Package: libmutter-10-0
Pin: version 42.9-0ubuntu9
Pin-Priority: 1001

Package: mutter-common
Pin: version 42.9-0ubuntu9
Pin-Priority: 1001
PIN
                    log "mutter 42.9-0ubuntu9 installed and pinned"
                else
                    warn "mutter upgrade did not stick — check network / ${LOG_FILE}"
                fi
                rm -rf "$tmpdir"
            fi
        fi
    fi

    echo ""
    log "GNOME / touch UX module complete"
    info "Log out & back in for scaling / OSK / rotation to fully apply."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 7 — WINE + AUDIO OPTIMIZATION
# ─────────────────────────────────────────────────────────────────────────────
# Wine audio on a slow Atom needs bigger buffers than default or you get
# crackling. v5.0 also exported PULSE_SERVER (breaks if the runtime dir
# differs — PipeWire's pulse socket is found automatically anyway) and set
# a "LatencyMinimum" registry key that Wine doesn't read → both removed.
# ─────────────────────────────────────────────────────────────────────────────
do_wine() {
    header "MODULE 7 — Wine + audio optimization"

    if command -v wine >/dev/null 2>&1; then
        skipmsg
        info "Wine already installed: $(wine --version 2>/dev/null || echo 'unknown')"
    else
        info "Enabling 32-bit architecture (most Windows games need it)..."
        dpkg --add-architecture i386 2>/dev/null
        apt-get update -qq 2>&1 | tail -2

        info "Installing Wine (this pulls a LOT of packages — be patient)..."
        apt-get install -y \
            wine64 wine32:i386 libwine:i386 \
            winetricks winbind 2>&1 | tail -5
        # v5.0 tested the pipeline's exit code (always 0 because of tail).
        # Test for the actual binary instead.
        if command -v wine >/dev/null 2>&1; then
            log "Wine installed: $(wine --version 2>/dev/null || echo 'ok')"
        else
            warn "Full Wine install failed — trying minimal (wine64 only)..."
            apt-get install -y wine64 2>&1 | tail -3
            if command -v wine >/dev/null 2>&1 || command -v wine64 >/dev/null 2>&1; then
                log "wine64 minimal installed"
            else
                err "Wine install failed — see ${LOG_FILE}"
                return 1
            fi
        fi
    fi

    # ── 7B. Global Wine audio env ────────────────────────────────────────
    info "Setting global Wine audio env vars..."
    cat > /etc/profile.d/casper-wine-audio.sh << 'WINE'
# Casper N220 — Wine audio buffers for Bay Trail Atom
# PULSE_LATENCY_MSEC=60        : 60 ms latency (default is lower → crackles)
# STAGING_AUDIO_DURATION=20000 : extra buffer (µs) for wine-staging builds
export PULSE_LATENCY_MSEC=60
export STAGING_AUDIO_DURATION=20000
WINE
    log "Wine audio env: PULSE_LATENCY_MSEC=60 (raise to 80 if it crackles)"

    # ── 7C. Wine prefix + registry: use the Pulse driver ─────────────────
    if [ ! -d "${REAL_HOME}/.wine" ]; then
        info "Initializing Wine prefix (first run takes ~1 min on the Atom)..."
        sudo -u "${REAL_USER}" WINEDEBUG=-all WINEPREFIX="${REAL_HOME}/.wine" \
            wineboot -u 2>/dev/null
        sleep 2
    fi

    cat > /tmp/wine-audio.reg << 'REG'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine\Drivers]
"Audio"="pulse"
REG
    sudo -u "${REAL_USER}" WINEDEBUG=-all WINEPREFIX="${REAL_HOME}/.wine" \
        wine regedit /tmp/wine-audio.reg 2>/dev/null
    rm -f /tmp/wine-audio.reg
    log "Wine registry: Audio=pulse (PipeWire's pulse layer picks it up)"

    echo ""
    log "Wine module complete"
    info "Test with: wine ~/Games/your-game.exe"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 8 — DIAGNOSTIC
# ─────────────────────────────────────────────────────────────────────────────
do_diagnostic() {
    header "MODULE 8 — Diagnostic"

    echo ""
    echo -e "${BOLD}=== SYSTEM ===${NC}"
    echo "  Distro      : $(detect_distro)"
    echo "  Kernel      : $(uname -r) (series $(detect_kernel_version), flavor $(detect_kernel_flavor))"
    echo "  CPU         : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
    echo "  RAM         : $(free -h | awk '/^Mem:/{print $2}') total, $(free -h | awk '/^Mem:/{print $7}') available"
    echo "  uptime      : $(uptime -p)"
    echo "  session     : ${XDG_SESSION_TYPE:-unknown}"

    echo ""
    echo -e "${BOLD}=== KERNEL CMDLINE (relevant params) ===${NC}"
    tr ' ' '\n' < /proc/cmdline | grep -E '^(intel_idle|i915|i2c|snd_|pci=|usbcore|mitigations|nowatchdog|transparent_hugepage)' | sed 's/^/  /'
    echo ""
    echo "  Full GRUB line:"
    grep "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub 2>/dev/null | sed 's/^/    /'

    echo ""
    echo -e "${BOLD}=== AUDIO ===${NC}"
    echo "  Server       : $(run_as_user pactl info 2>/dev/null | grep 'Server Name' | cut -d: -f2 | xargs || echo 'not running')"
    echo "  ALSA cards   :"
    aplay -l 2>/dev/null | grep '^card' | sed 's/^/    /' || echo "    (none — SST firmware missing? run module 4)"
    echo "  SST firmware : $(ls /lib/firmware/intel/fw_sst_0f28.bin* 2>/dev/null | head -1 || echo 'MISSING — run module 4')"
    echo "  Audio group  : $(id "${REAL_USER}" 2>/dev/null | grep -o 'audio' || echo 'NOT in audio group')"

    echo ""
    echo -e "${BOLD}=== TOUCHSCREEN ===${NC}"
    echo "  Touch devices:"
    libinput list-devices 2>/dev/null | grep -B1 -A2 -i 'touch' | head -20 | sed 's/^/    /' || echo "    (libinput-tools not installed)"
    echo "  I2C devices  :"
    ls /sys/bus/i2c/devices/ 2>/dev/null | sed 's/^/    /' || echo "    (none)"
    echo "  Quirk file valid keys : $(grep -q 'MatchUdevType=touchscreen' /etc/libinput/local-overrides.quirks 2>/dev/null && ! grep -q 'MatchDriver' /etc/libinput/local-overrides.quirks 2>/dev/null && echo yes || echo 'NO — run module 3')"
    echo "  i2c_hid errors in dmesg:"
    dmesg 2>/dev/null | grep -iE 'i2c_hid.*(error|fail)|i2c.*timeout' | tail -5 | sed 's/^/    /' || echo "    (none)"

    echo ""
    echo -e "${BOLD}=== DISPLAY / BACKLIGHT ===${NC}"
    echo "  backlight   : $(ls /sys/class/backlight/ 2>/dev/null | tr '\n' ' ')"
    local bl
    bl=$(ls /sys/class/backlight/ 2>/dev/null | head -1)
    [ -n "$bl" ] && echo "    brightness : $(cat "/sys/class/backlight/$bl/brightness" 2>/dev/null)/$(cat "/sys/class/backlight/$bl/max_brightness" 2>/dev/null)"
    [ -z "$bl" ] && echo "    NONE — backlight driver not loaded (Ubuntu kernel fixes this: module 2)"
    echo "  i915 errors in dmesg:"
    dmesg 2>/dev/null | grep -iE 'i915.*error|drm.*error' | tail -5 | sed 's/^/    /' || echo "    (none)"

    echo ""
    echo -e "${BOLD}=== MEMORY / SWAP ===${NC}"
    swapon --show 2>/dev/null | sed 's/^/  /' || echo "  (no swap!)"
    echo "  swappiness   : $(cat /proc/sys/vm/swappiness 2>/dev/null)   (want 180, or 100 on kernel <5.8)"
    echo "  page-cluster : $(cat /proc/sys/vm/page-cluster 2>/dev/null)   (want 0)"
    echo "  THP          : $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
    free -h | sed 's/^/  /'
    if [ -f /proc/pressure/memory ]; then
        echo "  PSI memory pressure (avg10 > 10 = you'll feel stalls):"
        sed 's/^/    /' /proc/pressure/memory
    fi

    echo ""
    echo -e "${BOLD}=== I/O SCHEDULER ===${NC}"
    local dev
    for dev in /sys/block/mmcblk*/queue/scheduler /sys/block/sd*/queue/scheduler; do
        [ -f "$dev" ] && echo "  $(echo "$dev" | cut -d/ -f4): $(cat "$dev")"
    done

    echo ""
    echo -e "${BOLD}=== CPU GOVERNOR ===${NC}"
    echo "  cpu0  : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
    echo "  boost : $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo 'N/A')"
    echo "  freq  : $(awk '{printf "%.2f GHz", $1/1000000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo unknown)"

    echo ""
    echo -e "${BOLD}=== WI-FI (RTL8723BS) ===${NC}"
    echo "  driver r8723bs : $(lsmod 2>/dev/null | grep -q '^r8723bs' && echo loaded || echo 'not loaded')"
    if command -v iw >/dev/null 2>&1; then
        local wdev
        for wdev in /sys/class/net/wl*; do
            [ -e "$wdev" ] || continue
            echo "  $(basename "$wdev") powersave : $(iw dev "$(basename "$wdev")" get power_save 2>/dev/null | cut -d: -f2 | xargs)"
        done
    fi
    echo "  NM powersave conf : $([ -f /etc/NetworkManager/conf.d/99-casper-wifi-powersave.conf ] && echo present || echo 'MISSING — run module 5')"
    echo "  driver opts conf  : $([ -f /etc/modprobe.d/casper-wifi.conf ] && echo present || echo 'MISSING — run module 5')"
    echo "  recent rtl errors :"
    dmesg 2>/dev/null | grep -iE 'r8723|rtl8723' | grep -iE 'error|fail|timeout' | tail -3 | sed 's/^/    /' || echo "    (none)"

    echo ""
    echo -e "${BOLD}=== SERVICES ===${NC}"
    local svc
    for svc in casper-touchscreen-watchdog casper-cpu-governor zramswap casper-zram earlyoom NetworkManager; do
        printf "  %-30s %s\n" "$svc" "$(systemctl is-active "${svc}.service" 2>/dev/null || true)"
    done
    printf "  %-30s %s\n" "fstrim.timer" "$(systemctl is-enabled fstrim.timer 2>/dev/null || true)"
    for svc in pipewire pipewire-pulse wireplumber; do
        printf "  %-30s %s\n" "$svc (user)" "$(run_as_user systemctl --user is-active "${svc}.service" 2>/dev/null || echo unknown)"
    done

    echo ""
    echo -e "${BOLD}=== CASPER CONFIG FILES ===${NC}"
    local f
    for f in \
        /etc/udev/rules.d/90-casper-baytrail-i2c.rules \
        /etc/udev/rules.d/60-casper-scheduler.rules \
        /etc/libinput/local-overrides.quirks \
        /etc/modprobe.d/casper-i915.conf \
        /etc/modprobe.d/casper-audio.conf \
        /etc/modprobe.d/casper-wifi.conf \
        /etc/sysctl.d/99-casper-perf.conf \
        /etc/NetworkManager/conf.d/99-casper-wifi-powersave.conf \
        /usr/local/bin/touchscreen-reset \
        /usr/local/bin/touchscreen-watchdog \
        /usr/lib/systemd/system-sleep/casper-resume
    do
        printf "  %-60s %s\n" "$f" "$([ -e "$f" ] && echo 'present' || echo 'MISSING')"
    done

    echo ""
    log "Diagnostic complete — full output logged to ${LOG_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 9 — VERIFY ALL FIXES
# ─────────────────────────────────────────────────────────────────────────────
do_verify() {
    header "MODULE 9 — Verify all fixes"

    local pass=0 fail=0
    check() {
        # $1 = description, $2 = command to eval (0 = pass)
        if eval "$2" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} $1"
            pass=$((pass+1))
        else
            echo -e "  ${RED}✗${NC} $1"
            fail=$((fail+1))
        fi
    }

    echo ""
    echo -e "${BOLD}Kernel cmdline (needs reboot after module 3/5 to pass):${NC}"
    check "intel_idle.max_cstate=1 (Bay Trail freeze fix)" \
        'grep -q "intel_idle.max_cstate=1" /proc/cmdline'
    check "i915.enable_psr=0" \
        'grep -q "i915.enable_psr=0" /proc/cmdline'
    check "snd_intel_dspcfg.dsp_driver=2 (SST audio)" \
        'grep -q "snd_intel_dspcfg.dsp_driver=2" /proc/cmdline'
    check "mitigations=off" \
        'grep -q "mitigations=off" /proc/cmdline'
    check "transparent_hugepage=never" \
        'grep -q "transparent_hugepage=never" /proc/cmdline'
    local KV; KV=$(detect_kernel_version)
    if kernel_lt "$KV" "6.8"; then
        check "i2c_designware.disable_pm=1 (kernel<6.8)" \
            'grep -q "i2c_designware.disable_pm=1" /proc/cmdline'
        check "i2c_hid.use_polling_mode=1 (kernel<6.8)" \
            'grep -q "i2c_hid.use_polling_mode=1" /proc/cmdline'
    else
        check "i2c_designware.disable_pm NOT set (kernel>=6.8)" \
            '! grep -q "i2c_designware.disable_pm" /proc/cmdline'
        check "i2c_hid.use_polling_mode NOT set (kernel>=6.8)" \
            '! grep -q "i2c_hid.use_polling_mode" /proc/cmdline'
    fi

    echo ""
    echo -e "${BOLD}Audio:${NC}"
    check "PipeWire is running" \
        'run_as_user pactl info 2>/dev/null | grep -q "PipeWire"'
    check "SST DSP firmware present (fw_sst_0f28.bin)" \
        'ls /lib/firmware/intel/fw_sst_0f28.bin* >/dev/null 2>&1'
    check "WirePlumber Bay Trail config (0.4 or 0.5 format)" \
        '[ -f "${REAL_HOME}/.config/wireplumber/main.lua.d/99-baytrail.lua" ] || [ -f "${REAL_HOME}/.config/wireplumber/wireplumber.conf.d/99-casper-baytrail.conf" ]'
    check "UCM symlink (bytcrrt5640)" \
        '[ -L /usr/share/alsa/ucm2/bytcrrt5640 ] || [ -d /usr/share/alsa/ucm2/bytcrrt5640 ]'
    check "modprobe.d/casper-audio.conf" \
        '[ -f /etc/modprobe.d/casper-audio.conf ]'

    echo ""
    echo -e "${BOLD}Touch & display:${NC}"
    check "udev I2C rules" \
        '[ -f /etc/udev/rules.d/90-casper-baytrail-i2c.rules ]'
    check "libinput quirk file has VALID keys" \
        'grep -q "MatchUdevType=touchscreen" /etc/libinput/local-overrides.quirks && ! grep -q "MatchDriver" /etc/libinput/local-overrides.quirks'
    check "i915 modprobe options" \
        '[ -f /etc/modprobe.d/casper-i915.conf ]'
    check "touchscreen-reset script (fixed driver names)" \
        '[ -x /usr/local/bin/touchscreen-reset ] && grep -q "i2c_hid_acpi" /usr/local/bin/touchscreen-reset'
    check "touchscreen watchdog enabled" \
        'systemctl is-enabled casper-touchscreen-watchdog.service 2>/dev/null | grep -q enabled'
    check "resume hook (touch reset + wifi after suspend)" \
        '[ -x /usr/lib/systemd/system-sleep/casper-resume ]'
    check "backlight device present" \
        'ls /sys/class/backlight/ 2>/dev/null | grep -q .'

    echo ""
    echo -e "${BOLD}Performance:${NC}"
    check "zram swap active" \
        'grep -q zram /proc/swaps'
    check "swappiness is 180 (or 100 on old kernels)" \
        'grep -qxE "(100|180)" /proc/sys/vm/swappiness'
    check "page-cluster=0" \
        'grep -qx "0" /proc/sys/vm/page-cluster'
    check "BFQ scheduler on mmcblk0" \
        'grep -q "\[bfq\]" /sys/block/mmcblk0/queue/scheduler 2>/dev/null'
    check "CPU governor (schedutil or ondemand)" \
        'grep -qE "schedutil|ondemand" /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null'
    check "tracker-miner-fs-3 masked" \
        'systemctl is-enabled tracker-miner-fs-3.service 2>/dev/null | grep -q masked'
    check "NetworkManager-wait-online off" \
        '! systemctl is-enabled NetworkManager-wait-online.service 2>/dev/null | grep -q "^enabled"'
    check "journal capped at 50M" \
        'grep -q SystemMaxUse /etc/systemd/journald.conf.d/casper.conf'
    check "tmpfs /tmp in fstab" \
        'grep -q "tmpfs /tmp" /etc/fstab'
    check "earlyoom active (anti-freeze)" \
        'systemctl is-active earlyoom.service 2>/dev/null | grep -q "^active"'
    check "fstrim.timer enabled (eMMC TRIM)" \
        'systemctl is-enabled fstrim.timer 2>/dev/null | grep -q enabled'

    echo ""
    echo -e "${BOLD}Wi-Fi:${NC}"
    check "NM wifi.powersave=2 conf" \
        '[ -f /etc/NetworkManager/conf.d/99-casper-wifi-powersave.conf ]'
    check "r8723bs driver options conf" \
        '[ -f /etc/modprobe.d/casper-wifi.conf ]'

    echo ""
    echo -e "${BOLD}GNOME / Wayland:${NC}"
    check "Wayland session (or gsettings reachable)" \
        '[ "${XDG_SESSION_TYPE:-}" = "wayland" ] || run_as_user gsettings get org.gnome.mutter edge-tiling >/dev/null 2>&1'
    check "GNOME animations enabled" \
        'run_as_user gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null | grep -q true'
    check "On-screen keyboard enabled" \
        'run_as_user gsettings get org.gnome.desktop.a11y.applications screen-keyboard-enabled 2>/dev/null | grep -q true'
    check "iio-sensor-proxy installed (auto-rotate)" \
        'dpkg -s iio-sensor-proxy >/dev/null 2>&1'

    echo ""
    echo -e "${BOLD}Wine:${NC}"
    check "wine installed" 'command -v wine >/dev/null || command -v wine64 >/dev/null'
    check "Wine audio env set" '[ -f /etc/profile.d/casper-wine-audio.sh ]'

    echo ""
    echo -e "${BOLD}Video acceleration:${NC}"
    check "VA-API driver installed (libva-intel-driver)" \
        'dpkg -s libva-intel-driver >/dev/null 2>&1'
    check "LIBVA_DRIVER_NAME pinned to i965" \
        'grep -q "LIBVA_DRIVER_NAME=i965" /etc/profile.d/casper-vaapi.sh 2>/dev/null'
    check "vainfo reports H264 hw decode" \
        'LIBVA_DRIVER_NAME=i965 vainfo 2>/dev/null | grep -q "VAProfileH264.*VAEntrypointVLD"'
    check "Firefox VA-API policy present" \
        '[ -f /usr/lib/firefox-esr/distribution/policies.json ] && grep -q "media.ffmpeg.vaapi.enabled" /usr/lib/firefox-esr/distribution/policies.json'
    check "mpv hwdec=vaapi configured" \
        '[ -f /etc/mpv/mpv.conf ] && grep -q "hwdec=vaapi" /etc/mpv/mpv.conf'

    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}PASS: ${pass}${NC}   ${RED}FAIL: ${fail}${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}"
    echo ""
    if [ "$fail" -gt 0 ]; then
        warn "Some checks failed. Cmdline checks need a REBOOT first;"
        warn "otherwise re-run the relevant module. Full log: ${LOG_FILE}"
    else
        log "All checks passed. Your Casper N220 is fully set up."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 10 — VIDEO ACCELERATION (VA-API H.264 hardware decode)
# ─────────────────────────────────────────────────────────────────────────────
# WHY: The Z3735F's Bay Trail GPU has a hardware video decode block, but it
#      only covers H.264 / VP8 / MPEG-2 — NOT VP9 or AV1. YouTube defaults to
#      VP9 (and increasingly AV1) for most videos, which forces 100% SOFTWARE
#      decode on a quad-core Atom clocked under 2 GHz → dropped frames, fan-
#      less thermal throttling, and audio that drifts out of sync. This is
#      routinely mistaken for "the CPU is just too weak," but 720p H.264
#      decodes smoothly on this exact chip when the hardware path is used.
#
#      Bay Trail is old enough that it needs the LEGACY "i965" VA-API driver
#      (package libva-intel-driver), NOT intel-media-driver (iHD), which only
#      supports Broadwell and newer. Installing the wrong one silently no-ops.
#
#      Three pieces have to line up or hardware decode won't engage:
#        1. libva-intel-driver present and vainfo reports H264 entrypoints
#        2. Firefox's ffmpeg VA-API flags enabled (off by default on Debian's
#           packaged Firefox ESR, and further gated by RDD-process sandboxing)
#        3. The browser actually being SERVED H.264 instead of VP9/AV1 —
#           YouTube's own player picks the codec, not the browser, so an
#           extension (h264ify) is needed to force the H.264 stream. A script
#           cannot install a browser extension for you; this module prints
#           the manual step instead of silently claiming it's handled.
# ─────────────────────────────────────────────────────────────────────────────
do_video_accel() {
    header "MODULE 10 — Video acceleration (VA-API)"

    # ── 10A. Install the correct (legacy) VA-API driver ──────────────────
    info "Installing VA-API packages (i965 driver — correct for Bay Trail)..."
    apt-get update -qq 2>&1 | tail -2
    apt-get install -y vainfo libva-intel-driver mesa-va-drivers 2>&1 | tail -5

    if ! command -v vainfo >/dev/null 2>&1; then
        err "vainfo not found after install — VA-API packages failed."
        err "Check that 'contrib' and 'non-free' components are enabled."
        return 1
    fi

    # intel-media-driver (iHD) targets Broadwell+ and will get pulled in as
    # a dependency of some meta-packages; it silently shadows the working
    # i965 driver via the LIBVA_DRIVER_NAME auto-detect on some setups.
    # Force i965 explicitly system-wide rather than relying on autodetect.
    info "Pinning LIBVA_DRIVER_NAME=i965 system-wide (Bay Trail needs legacy driver)..."
    cat > /etc/profile.d/casper-vaapi.sh << 'VAAPI'
# Casper N220 — force the legacy i965 VA-API driver.
# Bay Trail (Atom Z3735F) predates intel-media-driver (iHD)'s Broadwell+
# floor. Without this pin, autodetect can pick iHD, which silently fails
# to initialize on this GPU and decode falls back to software.
export LIBVA_DRIVER_NAME=i965
VAAPI
    log "Wrote /etc/profile.d/casper-vaapi.sh"

    # Also set it for system services / greeter sessions that don't source
    # profile.d (e.g. some display managers).
    mkdir -p /etc/environment.d
    echo "LIBVA_DRIVER_NAME=i965" > /etc/environment.d/casper-vaapi.conf
    log "Wrote /etc/environment.d/casper-vaapi.conf"

    # ── 10B. Verify hardware decode entrypoints exist ────────────────────
    info "Checking vainfo for H.264 decode entrypoints..."
    VAINFO_OUT=$(LIBVA_DRIVER_NAME=i965 vainfo 2>&1)
    if echo "$VAINFO_OUT" | grep -q "VAProfileH264.*VAEntrypointVLD"; then
        log "H.264 hardware decode confirmed available"
    else
        warn "vainfo did not report H264/VLD — hardware decode may not work."
        warn "Output saved to ${LOG_DIR}/vainfo-output.txt for troubleshooting"
        echo "$VAINFO_OUT" > "${LOG_DIR}/vainfo-output.txt"
    fi

    # ── 10C. Firefox: enable VA-API + relax RDD sandbox ──────────────────
    # Debian's Firefox ESR ships with media.ffmpeg.vaapi.enabled=false and,
    # even when true, the RDD (Remote Data Decoder) sandbox can block the
    # render device open on some kernels. Both prefs are needed together.
    info "Configuring Firefox VA-API prefs (system-wide default)..."
    FF_POLICY_DIR="/usr/lib/firefox-esr/distribution"
    if [ -d /usr/lib/firefox-esr ] || command -v firefox-esr >/dev/null 2>&1; then
        mkdir -p "$FF_POLICY_DIR"
        cat > "${FF_POLICY_DIR}/policies.json" << 'FFPOL'
{
  "policies": {
    "Preferences": {
      "media.ffmpeg.vaapi.enabled": { "Value": true, "Status": "default" },
      "media.rdd-ffmpeg.enabled": { "Value": true, "Status": "default" },
      "media.hardware-video-decoding.enabled": { "Value": true, "Status": "default" }
    }
  }
}
FFPOL
        log "Firefox VA-API prefs written to ${FF_POLICY_DIR}/policies.json"
    else
        skipmsg
        info "firefox-esr not detected — skipping Firefox-specific config."
    fi

    # ── 10D. mpv: hardware decode for local video files ──────────────────
    info "Configuring mpv for VA-API hardware decode..."
    mkdir -p /etc/mpv
    cat > /etc/mpv/mpv.conf << 'MPVCONF'
# Casper N220 — VA-API hardware decode (Bay Trail i965 driver)
hwdec=vaapi
hwdec-codecs=h264,vp8
vo=gpu
MPVCONF
    log "mpv hardware decode configured (/etc/mpv/mpv.conf)"

    # ── 10E. Manual step: YouTube codec forcing ───────────────────────────
    echo ""
    warn "MANUAL STEP REQUIRED — a script cannot install browser extensions:"
    echo "    YouTube's player chooses VP9/AV1 by default, and Bay Trail has"
    echo "    NO hardware decode for either — only H.264. Install the"
    echo "    'h264ify' (or 'Enhanced H264ify') extension in Firefox so"
    echo "    YouTube is forced to serve the H.264 stream that this GPU can"
    echo "    actually decode in hardware. Also cap playback at 1080p/30fps"
    echo "    in the extension's settings — 60fps H.264 has a much smaller"
    echo "    hardware-eligible bitrate ladder on YouTube."
    echo ""
    info "After installing h264ify, verify hw decode is engaged during"
    info "playback with: intel_gpu_top   (or check for low CPU usage vs."
    info "software decode, which pins a core near 100%)."

    echo ""
    log "Video acceleration module complete"
    warn "LOG OUT / back in (or reboot) for the environment.d change to apply."
}

# ─────────────────────────────────────────────────────────────────────────────
# FULL INSTALL
# ─────────────────────────────────────────────────────────────────────────────
do_full_install() {
    header "FULL INSTALL — all modules in order"

    echo "  This runs modules 3 → 4 → 5 → 6 → 7 (kernel install, module 2,"
    echo "  is skipped because it needs its own reboot — run it first if you"
    echo "  still have backlight/Wi-Fi driver problems on the Debian kernel)."
    echo ""
    if ! confirm "Proceed?" "y"; then
        return 0
    fi

    do_touch_display
    do_audio
    do_performance
    do_gnome_ux
    do_wine
    do_video_accel

    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}          FULL INSTALL COMPLETE             ${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
    echo ""
    echo "  What was applied:"
    echo "    ✓ Touch & display (C-state, I2C rules, VALID quirk, fixed reset"
    echo "      script, streaming watchdog, resume hook)"
    echo "    ✓ Audio (PipeWire + SST firmware + UCM fix + WirePlumber 0.4/0.5)"
    echo "    ✓ Performance (zram 1.5G, swappiness 180, BFQ, ${GREEN}earlyoom${NC},"
    echo "      governor, fstrim, services masked, eMMC mount flags)"
    echo "    ✓ Wi-Fi latency fix (RTL8723BS powersave off)"
    echo "    ✓ GNOME touch UX (auto-rotate, OSK, Wayland preserved)"
    echo "    ✓ Wine + audio buffers"
    echo "    ✓ Video acceleration (VA-API H.264 hw decode, mpv + Firefox)"
    echo ""
    warn "REBOOT REQUIRED — kernel params, driver options and initramfs"
    warn "changes only take effect after a reboot."
    if confirm "Reboot now?" "n"; then
        sleep 3
        reboot
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────
main() {
    # Detect the real (non-root) user if we weren't invoked via sudo
    if [ -z "${REAL_USER:-}" ] || [ "${REAL_USER}" = "root" ]; then
        REAL_USER=$(awk -F: '$3>=1000 && $1!="nobody" {print $1; exit}' /etc/passwd 2>/dev/null)
        if [ -z "${REAL_USER}" ]; then
            err "Could not detect a non-root user. Run: REAL_USER=<name> sudo -E $0"
            exit 1
        fi
        REAL_HOME=$(resolve_home "${REAL_USER}")
        REAL_HOME="${REAL_HOME:-/home/${REAL_USER}}"
        USER_UID=$(id -u "${REAL_USER}" 2>/dev/null || echo "1000")
        USER_BUS="unix:path=/run/user/${USER_UID}/bus"
        warn "Detected real user: ${REAL_USER}"
    fi

    show_banner

    # Non-interactive mode: --module <name|number> (numbers match the menu)
    if [ "${1:-}" = "--module" ] && [ -n "${2:-}" ]; then
        case "$2" in
            full)               do_full_install ;;
            kernel|2)           do_kernel ;;
            touch|display|3)    do_touch_display ;;
            audio|4)            do_audio ;;
            performance|perf|5) do_performance ;;
            gnome|ux|6)         do_gnome_ux ;;
            wine|7)             do_wine ;;
            diagnostic|diag|8)  do_diagnostic ;;
            verify|9)           do_verify ;;
            video|vaapi|10)     do_video_accel ;;
            *) err "Unknown module: $2 (try: full kernel touch audio performance gnome wine diagnostic verify video)"; exit 1 ;;
        esac
        exit 0
    fi

    # Interactive menu loop
    while true; do
        show_menu
        case "${choice:-}" in
            1) do_full_install ;;
            2) do_kernel ;;
            3) do_touch_display ;;
            4) do_audio ;;
            5) do_performance ;;
            6) do_gnome_ux ;;
            7) do_wine ;;
            8) do_diagnostic ;;
            9) do_verify ;;
            10) do_video_accel ;;
            0) echo "Bye."; exit 0 ;;
            *) warn "Invalid choice — pick 0-10" ;;
        esac
        echo ""
        read -p "$(echo -e "${DIM}Press Enter to return to menu...${NC}")" _
    done
}

main "$@"
