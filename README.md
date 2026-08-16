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

## Flashing (no OS required — Ventoy USB stick)

CasperOS is a **raw disk image**, so it isn't booted like a distro installer.
The recommended path needs no keyboard and no terminal — and only **one
file** on the stick:

### Recommended: self-contained flash ISO on a Ventoy stick

1. Download from the release:
   - `casper-flash.iso.xz.00` + `casper-flash.iso.xz.01` + `casper-flash.iso.xz.sha256`
     (the flash ISO **with the CasperOS image already inside**)
   - `casper-flash-esp.zip` (only needed as a fallback, see below)
2. Decompress to the raw ISO (needs ~7 GB free — phone or PC):
   ```bash
   sha256sum -c casper-flash.iso.xz.sha256
   cat casper-flash.iso.xz.?? | xz -dc > casper-flash.iso
   ```
3. Copy **just `casper-flash.iso`** onto the stick's main partition.
4. Plug into the tablet, boot, and in the Ventoy menu select
   **casper-flash.iso**. (Ventoy supports 32-bit UEFI since v1.0.30 — if
   your Ventoy is older, update it first.)
5. Watch the screen: it finds the image **inside the ISO**, shows a
   10-second countdown, flashes the internal eMMC, prints
   **"flash complete"**, then reboots. Pull the stick after that.

The flasher only ever touches the **internal eMMC** (anything that is not
the USB stick / CD). If it sees more than one internal disk (e.g. an SD
card is inserted), it aborts to a shell instead of guessing — remove the
SD card and reboot.

### Older two-file flow (still supported)

If you have `casper-n220.img` (the raw image) on the stick's data
partition instead, the flasher finds it there first — same result. The
plain image is still published as `casper-n220.img.xz.00` for manual
`dd` flashing and for the ESP kit.

### Fallback A: flash from within CasperOS booted from the stick

If your Ventoy boots raw `.img` files directly (select `casper-n220.img`
in the menu), CasperOS runs from the stick; then on the desktop:
`sudo /usr/local/bin/casper-flash` — same result.

### Fallback B: Debian netinst rescue shell

Put `debian-13.x-amd64-netinst.iso` on the stick too (Debian's amd64
ISOs include the 32-bit UEFI loader, so they boot on this tablet). Boot
it → **Advanced options → Rescue mode** → shell, then:

```bash
mkdir /mnt/s
mount -t vfat /dev/sda1 /mnt/s   # find the stick partition with lsblk
cat /mnt/s/casper-n220.img.xz.00 | xz -dc > /dev/mmcblk0
sync; reboot
```

### Fallback C: ESP kit (firmware that won't boot Ventoy at all)

`casper-flash-esp.zip` contains a replacement `BOOTIA32.EFI` plus the
kernel/initrd. Copy `BOOTIA32.EFI` over `/EFI/BOOT/BOOTIA32.EFI` on the
stick's ESP partition (FAT32), put `vmlinuz`/`initrd.img` in a `flash/`
folder on the data partition, and the tablet boots the flasher directly —
no Ventoy menu involved.

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
