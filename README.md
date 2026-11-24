# CasperOS — custom Debian for the Casper Nirvana N220 / N240

A small, tuned, flash-ready Debian 13 (trixie) image for the Casper Nirvana
N220 / N240 tablet (Intel Atom Z3735F Bay Trail, 2 GB RAM, 32-bit UEFI).
Built from this repo on GitHub Actions, verified by an automated KVM boot
test of both kernels, and published as split `.img.xz` parts in Releases.

Everything is baked in — nothing runs after first boot:

- **32-bit UEFI GRUB** (`i386-efi`, installed at both `/EFI/BOOT/BOOTIA32.EFI`
  and `/EFI/CasperOS/`) — the Bay Trail firmware only understands IA32 EFI.
- **Hidden GRUB → plymouth splash** — boots straight into the CasperOS
  animation, no menu frame. Hold **Shift/Esc** at boot for the menu; the
  5.15 fallback kernel is under *Advanced options*.
- **Dual kernel**: Debian 6.12 (default) + Ubuntu mainline **5.15.165**
  (fallback — the kernel known good on this device, with its correct legacy
  I2C parameters applied to that entry only).
- **Landscape boot**: the panel is physically portrait, so the compositor
  rotates it 90° (`monitor = …, transform, 1` in the Hyprland config) — the
  setting you'd otherwise hunt for in a display panel that does not exist.
- **User `lvy`** (no password), Turkey locale `tr_TR.UTF-8`, timezone
  `Europe/Istanbul`, keyboard `tr`, **greetd autologin straight into
  Hyprland**. No login screen, no password prompt, no GDM.
- **Audio, working on first boot**: PipeWire 1.4 + WirePlumber 0.5 tuned for
  the RT5640 (2048-frame quantum, 48 kHz locked, PCM never suspended — that
  is the "first second of sound is missing" and the 5-second pop). The
  SST DSP firmware is present, and the ALSA UCM profile is aliased to the
  name the kernel actually reports, so the mixer and speaker controls exist
  instead of the card showing up with no profile.
- **Performance**: zram 2 GB (lz4) + swappiness 180, earlyoom (kills the
  browser, never the desktop), BFQ, schedutil, THP off, BBR + fq on the
  RTL8723BS Wi-Fi, masked background services, VA-API hardware decode (i965
  driver) for Firefox/mpv.
- **Small boot footprint**: zstd initramfs, with the tablet's storage stack
  (ext4 + `mmc_block`/`sdhci`) named explicitly so root always mounts, and
  the build asserting with `lsinitramfs` that those modules are really in the
  initrd — less to read off the eMMC and less RAM held while booting. Man
  pages, docs, gtk-doc and lintian data are excluded at dpkg level, so they
  are never written to the disk in the first place.
- First-boot: root partition auto-resizes to fill the eMMC, and the firmware
  NVRAM boot entry is repaired once.

## What you must know (disclosures)

- **Memory-integrity and hardening features are OFF**. The kernel cmdline
  carries `mitigations=off init_on_alloc=0 init_on_free=0 page_poison=0
  slub_debug=- randomize_kstack_offset=0 audit=0 apparmor=0`, and AppArmor
  is masked. `mitigations=off` alone is a deliberate, big speedup for
  Silvermont (~20–40% on syscalls); the init/poison/randomisation knobs each
  remove a memset or RNG call from hot allocation paths. This is fine for a
  personal media tablet and wrong for anything running untrusted code —
  there is no memory-corruption barrier left.
- **User `lvy` has no password** and passwordless `sudo`. Anyone with the
  tablet can use it. The lock screen is a swipe, not security.
- **Secure Boot must be OFF** (mainline Ubuntu kernels are unsigned).
- **One manual step remains**: install the **h264ify** (or Enhanced H264ify)
  browser extension in Firefox. YouTube serves VP9/AV1 by default, which Bay
  Trail cannot hardware-decode; h264ify forces the H.264 stream the GPU
  actually decodes. Cap playback at ≤1080p/30fps.

## The desktop: Hyprland + Caelestia shell

**GNOME is not on this image.** It was the single largest consumer of both
image space and RAM, and this tablet runs exactly one session: greetd
autologins, starts Hyprland, which starts the Caelestia shell. There is no
login screen — user `lvy` never had a password anyway.

What replaced it: `greetd` (a few hundred KB, no GTK) as the session launcher,
`thunar` for files, `foot` for a terminal, `nmtui` for networks, and the
Hyprland portal for screen sharing. Everything GNOME-specific — tracker, ibus,
gnome-keyring, nautilus, gvfs's GNOME bits, the extension stack — is gone from
the package list, not merely masked.

- **Hyprland 0.55 + Quickshell 0.3** come from `trixie-backports`, pinned at
  priority 100 (`/etc/apt/preferences.d/99-casper-backports`) so `apt upgrade`
  cannot drag libc/systemd forward with them.
- **[caelestia-shell](https://github.com/caelestia-dots/shell) is built from
  source at `v1.1.0`.** That pin is forced, not lazy: every release from
  v1.2.0 onward hard-gates its CMake on Qt 6.9
  (`qt_standard_project_setup(REQUIRES 6.9)`) and links libcava/aubio through
  pkg-config. trixie has Qt 6.8.2 — and no Qt 6.9+ even in backports — and no
  libcava development package at all, so those versions cannot be built here.
  v1.1.0 is the last tag with neither requirement.
- **Blur and animations are off** in `/etc/xdg/hypr/hyprland.conf`. On a 4-EU
  Gen7 GPU they are the difference between usable and stuttering; the shell
  still looks correct without them.
- `/etc/casperos/hyprshell.status` records whether the shell compiled in this
  build and which versions went in. If it starts with `failed:`, the session
  still launches — you get bare Hyprland, and **Super+Return** opens `foot`.

Known gaps in this session, all real:

- **No on-screen keyboard at all.** GNOME's OSK left with GNOME and nothing
  replaces it yet, so typing a Wi-Fi password on the tablet itself needs a USB
  keyboard until something like squeekboard is wired up.
- **The shell is pointer-first** (`showOnHover`, drag thresholds, hover
  popouts). Touch works at the compositor level — Hyprland 0.53+ fixed the
  fullscreen touch bug — but Caelestia was not designed for a finger.
- **v1.1.0 predates Quickshell 0.3**, so QML/API mismatches are possible. They
  surface as errors inside the session, not at build time.
- **None of this session has been verified on the tablet.** The build only
  proves it compiles and installs. Because this is now the *only* session, a
  compositor that cannot start means no GUI: greetd then drops to a shell on
  VT1, and `Ctrl+Alt+F2` gives a console.

## Flashing / installing (no OS required — Ventoy USB stick)

Three ways, in order of preference:

### 32-bit UEFI, Ventoy, and RAM during install

Bay Trail firmware is **IA32-only**, and Debian's amd64 netinst ships no 32-bit
EFI loader at all — that is why a stock Debian ISO silently refuses to start on
this tablet. The installer built here carries its own `EFI/BOOT/BOOTIA32.EFI`
(checked at build time: it must exist and be a PE32 IA-32 binary), both as a
file in the ISO tree — the path Ventoy ≥1.0.30 chainloads — and as the ISO's
EFI boot image for real firmware.

The IA32 menu boots the **text installer** on purpose: no GTK, roughly a
quarter of the graphical installer's RAM, which matters when the machine only
has 2 GB and the install itself runs `apt` in a chroot. There are two entries —
automatic (preseeded, hands-off) and interactive.

Ventoy itself: use a Ventoy ≥1.0.30 stick, copy the ISO on, boot it. Secure
Boot must be off.

### 1. Debian-installer ISO (visible, keyboard-friendly)

Download `casper-install.iso` + `casper-install.iso.sha256` from the
release and put the ISO on the Ventoy stick. Boot → Ventoy menu →
`casper-install.iso`. The installer is Debian's own (full on-screen
progress, USB keyboard works). It **tries to auto-install** with a preseed
(Turkish locale, user `lvy`, whole-disk install, all CasperOS fixes
applied automatically) — if the preseed engages you just wait; if it
falls back to the interactive menu, pick the defaults and continue (the
installer still installs plain Debian, and you apply the fixes with one
command afterwards, see below). The tablet's RTL8723BS Wi-Fi firmware is
bundled into the installer, so Wi-Fi works during the install.

### 2. Self-contained flash ISO (zero interaction)

`casper-flash.iso.xz.00` + `.01` (with the CasperOS image already inside;
decompress with `cat casper-flash.iso.xz.?? | xz -dc > casper-flash.iso`)
→ copy `casper-flash.iso` to the stick → boot → it flashes the internal
eMMC automatically. Note: older builds of this ISO showed no on-screen
progress; the current build shows every step.

### 3. After any manual Debian 13 install — one command

```bash
sudo apt install -y git
git clone https://github.com/turanmertkaraca-bit/casper-nirvana-debian
cd casper-nirvana-debian
sudo bash build/preseed/casperos-fixup.sh
sudo reboot
```

This applies the complete CasperOS configuration (package set, touch/
audio/performance fixes, 5.15 fallback kernel, GRUB tuning, plymouth
theme, lvy user) to any stock Debian 13 system. It needs network on the
tablet (Wi-Fi or USB-tethered phone).

### Legacy paths (still supported)

- The plain image `casper-n220.img.xz.00` for manual `dd`, and the ESP kit
  `casper-flash-esp.zip` for firmware that won't boot Ventoy at all.

---

**Important:** the image contains no personal data and gets a fresh
machine-id on first boot. Partition table on the target eMMC is
**replaced**. First boot is slower (partition resize); Secure Boot must be
off (mainline kernels are unsigned).

## Boot menu / fallback kernel

Hold **Shift** (or press Esc) during the splash → GRUB menu → *Advanced
options* → the 5.15.165 entry. After a failed boot GRUB shows the menu
automatically. If a future update ever breaks 6.12, the 5.15 fallback is
your one-reboot recovery.

## Development

```bash
# build locally on any root x86_64 Debian/Ubuntu box:
sudo ./build/build-image.sh --img /tmp/casper-n220.img --size 6G

# KVM boot-test the result (both kernels):
sudo ./build/test/smoke-test.sh --img /tmp/casper-n220.img --out /tmp/casper-test
```

See `docs/TESTING.md` for the on-device test checklist (things KVM cannot
verify) and the architecture notes in `docs/`.
