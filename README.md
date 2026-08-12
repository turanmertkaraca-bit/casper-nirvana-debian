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

## Flashing (from the tablet's current Debian 12, or any Linux)

The image contains no personal data and gets a fresh machine-id on first
boot. Partition table on the target eMMC is **replaced** — back up anything
you need first.

```bash
# 1. download the release parts (all casper-n220.img.xz.XX + .sha256)
# 2. verify + reassemble:
sha256sum -c casper-n220.img.xz.sha256
cat casper-n220.img.xz.* | xz -dc > casper-n220.img

# 3. identify the target disk (!!! double-check !!!)
lsblk

# 4. flash (replace /dev/mmcblk0 with your eMMC — this wipes it)
sudo dd if=casper-n220.img of=/dev/mmcblk0 bs=4M status=progress conv=fsync
sudo sync
```

Reboot. First boot is slower (partition resize) — after that it's the
desktop straight off the splash. If the firmware lands in its setup menu
instead of booting, just exit it — the removable `BOOTIA32.EFI` path gets
picked up.

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
