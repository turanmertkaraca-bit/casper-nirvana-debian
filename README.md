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
- **Landscape boot**: the panel orientation fix you'd otherwise set in
  GNOME Settings ("Right") is baked into `monitors.xml` for both GDM and the
  user session.
- **User `lvy`** (no password), Turkey locale `tr_TR.UTF-8`, timezone
  `Europe/Istanbul`, keyboard `tr`, GNOME on **Wayland** with the on-screen
  keyboard enabled at login and in the session.
- **Audio**: PipeWire + WirePlumber with suspend disabled (no first-second
  sound cut, no 5-second pop), SST firmware + UCM symlink baked in.
- **Performance**: zram 1.5 GB + swappiness 180, earlyoom (kills the browser,
  never the desktop), BFQ, schedutil, THP off, zstd initramfs, masked
  background services, VA-API hardware decode (i965 driver) for Firefox/mpv.
- First-boot: root partition auto-resizes to fill the eMMC, and the firmware
  NVRAM boot entry is repaired once.

## What you must know (disclosures)

- **`mitigations=off` is set** (kernel cmdline). It is a deliberate, big
  speedup for Silvermont (~20–40% on syscalls) and reasonable on a personal
  media tablet — not for machines running untrusted code.
- **User `lvy` has no password** and passwordless `sudo`. Anyone with the
  tablet can use it. The lock screen is a swipe, not security.
- **Secure Boot must be OFF** (mainline Ubuntu kernels are unsigned).
- **One manual step remains**: install the **h264ify** (or Enhanced H264ify)
  browser extension in Firefox. YouTube serves VP9/AV1 by default, which Bay
  Trail cannot hardware-decode; h264ify forces the H.264 stream the GPU
  actually decodes. Cap playback at ≤1080p/30fps.

## Flashing / installing (no OS required — Ventoy USB stick)

Three ways, in order of preference:

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
