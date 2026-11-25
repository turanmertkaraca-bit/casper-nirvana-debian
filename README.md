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
- **Landscape boot**: the panel is physically portrait, so mutter rotates it
  90° via `monitors.xml` — including GDM's own copy, so the login screen is
  landscape too. This is the setting you'd otherwise hunt for in a display
  panel that does not exist.
- **User `lvy`** (no password), Turkey locale `tr_TR.UTF-8`, timezone
  `Europe/Istanbul`, keyboard `tr`, **GDM → GNOME Shell on Wayland**, with the
  on-screen keyboard enabled.
- **Installs with no network at all**: the installer ISO carries a complete
  apt repository of every package the image needs, plus the 5.15 kernel
  packages. There is no mirror, no DHCP probe and no firmware download during
  the install.
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

## The desktop: GNOME on Wayland

GNOME is the session, launched by **GDM**. This was briefly replaced by
Hyprland + Caelestia and that was reverted: Caelestia had to be compiled from
source against a Qt it was not built for, needed a cmake/g++/Qt toolchain
inside the image, and was **never once verified on the tablet**. GNOME is the
session that was actually proven on this hardware, and it is the only one that
gives the tablet an on-screen keyboard.

- **One session, no fallback compositor.** GDM starts GNOME Shell on Wayland
  for user `lvy`. If the shell ever fails, GDM still gives you a working login
  screen (a frozen greeter is not the same failure as a dead bare compositor),
  and `getty@tty2` is enabled as a text console — `Ctrl+Alt+F2`.
- **On-screen keyboard works again.** `screen-keyboard-enabled=true` in
  `/etc/dconf/db/local.d/00-casper-desktop`, with `ibus` installed. This is the
  one thing the Caelestia experiment lost outright: typing a Wi-Fi password on
  the tablet had become impossible without a USB keyboard.
- **Landscape boot.** The panel is physically portrait, so mutter rotates it
  90° via `monitors.xml`. It has to be present **three** times — for `lvy`, in
  `/etc/skel`, and in `/var/lib/gdm3/.config` — because GDM reads its own copy:
  miss that one and the *login screen* boots sideways even though the desktop
  is correct.
- **Touch-first defaults** in the same dconf file: 1.15 text scaling, hot
  corners off, tap-to-click, natural scroll, and no idle-suspend on AC.
- **Shell extensions** are enabled by discovering the UUIDs that actually got
  installed, not by hardcoding names this Debian release may not ship.

Also in the image: `nautilus` for files, `gnome-console`, `gnome-text-editor`,
`gnome-keyring`, `iio-sensor-proxy` for rotation, the GNOME portal for screen
sharing, and `network-manager-gnome` so Wi-Fi is configurable from the panel.

Nothing is compiled from source. The whole desktop comes from trixie's own
packages, which is what makes the fully offline ISO in the next section
possible at all.

Known gaps, all real:

- **None of this session has been verified on the tablet.** The build proves it
  installs and that GDM starts; the desktop rendering itself needs the real
  i915 path.
- **GNOME is heavy for 2 GB.** It was removed once for that reason. It is back
  because "a desktop that was never verified" is a worse problem than "a
  desktop that uses more RAM", and zram + earlyoom are configured to keep the
  UI alive under load.

## Flashing / installing (no OS required — Ventoy USB stick)

**The install needs no internet.** The ISO is self-contained: it carries a
complete apt repository of every package the image installs (the exact
dependency closure of `build/packages.list`), the two Ubuntu 5.15 kernel
packages, the RTL8723BS Wi-Fi firmware and its Bluetooth firmware. `netcfg` is
disabled in the preseed, so nothing probes the network, waits for DHCP or
prompts for a mirror. You can install on a plane.

Building that ISO **does** need a network (it resolves and downloads the
closure) — see `build/preseed/make-offline-repo.sh`. That is the point: the
work happens on the builder, not on the tablet.

The KVM test enforces this: it boots the installer with `-nic none`, so a
regression that reintroduces a download fails the test instead of quietly
working on a runner with connectivity.

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
