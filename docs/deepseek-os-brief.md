# BUILD BRIEF — Custom Debian Image for Casper Nirvana N220

Build a **small, polished, single-purpose Debian image** for one specific tablet.
Output is a `dd`-able raw disk image, not a live ISO and not a generic installer.

It will be flashed to the device's eMMC and also shared with other owners of the
same tablet. Everything must work on first boot with no terminal use.

---

## 1. Target hardware (exact)

| Field | Value |
|---|---|
| Device | Casper Nirvana N220 / N240 (Turkish Bay Trail tablet, ~2014) |
| SoC | Intel Atom Z3735F (Bay Trail-T, Silvermont, 4 cores, 1.33/1.83GHz) |
| RAM | **2GB DDR3L, soldered** — the binding constraint on every decision |
| Storage | 32–64GB eMMC (`/dev/mmcblk0`), slow (~150MB/s read, ~80MB/s write) |
| Display | 11.6" 1366x768 IPS, 5-point capacitive touch |
| Touch | Goodix, Silead, or ELAN over I2C-HID — **varies by manufacturing batch** |
| Audio | Realtek RT5640 on Intel SST bus |
| Wi-Fi/BT | Realtek RTL8723BS (SDIO combo) |
| GPU | Intel HD Gen7, 4 EUs — **H.264/VP8 hw decode only. NO VP9. NO AV1.** |
| Firmware | **32-bit UEFI ONLY, on a 64-bit CPU** |

### 1.1 The firmware constraint — read this twice

32-bit (IA32) UEFI firmware, 64-bit CPU. Therefore:

- The **bootloader must be `i386-efi`** (`grub-efi-ia32-bin` → `BOOTIA32.EFI`)
- The **kernel and userland are `amd64`**
- There is **no 32-bit kernel** in this project

Do not build an i386 image. Only the EFI bootloader binary is 32-bit.

Known-working procedure (done manually on this device):

```bash
apt install grub-efi-ia32-bin
grub-install --target=i386-efi --efi-directory=/boot/efi \
  --bootloader-id=GRUB --boot-directory=/boot --removable
```

Install **both** the removable path (`/EFI/BOOT/BOOTIA32.EFI`) and the standard
`bootloader-id` path. Many Bay Trail firmwares mishandle NVRAM boot entries, so
the removable fallback is often the only one that boots.

**One exception to "no i386":** Wine may require i386 *multiarch* packages. That
is unrelated to the bootloader/kernel architecture rule above. See §6.

### 1.2 Base distro

Build on **Debian 13 "Trixie"** (current stable, kernel 6.12 LTS).

**Verify before committing:** Trixie demoted i386 to a non-regular architecture.
Confirm `grub-efi-ia32-bin` is still available for amd64 on Trixie. If it is not,
fall back to Debian 12 Bookworm and report this. **This is a hard blocker** — the
tablet cannot boot at all without an ia32 bootloader.

---

## 2. Dual kernel, invisible by default

Ship **two kernels** in the image:

- **Default:** Debian stock 6.12
- **Fallback:** Ubuntu mainline 5.15.x (`.deb` from `kernel.ubuntu.com/mainline`,
  installed at build time)

**Why both:** the device owner has empirically found 5.15 works well and reported
kernel 6.x as buggy and laggy in past testing. That finding is confounded — those
tests applied I2C parameters that are correct for 5.15 but break the rewritten
`i2c_hid_acpi` driver on 6.8+ — so 6.12 with correct parameters is untested and
may be fine. Additionally, the touch controller varies by batch across devices,
so different owners may genuinely need different kernels. Shipping both makes the
image self-recovering: a bad kernel costs one reboot, not a reinstall.

**Per-kernel parameter sets are mandatory:**

- **5.15 entry:** legacy I2C params ARE appropriate — include
  `i2c_designware.disable_pm=1` and `i2c_hid.use_polling_mode=1`
- **6.12 entry:** these MUST be omitted entirely, along with
  `i2c_hid_acpi.disable_multitouch`

Applying one param set to both kernels is the exact mistake that made all prior
comparisons on this device meaningless.

### 2.1 Keeping it polished

The GRUB menu must **not** appear during a normal boot:

```
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=1
GRUB_DEFAULT=0
```

- Boots straight to the Plymouth splash. No menu, no kernel prompt.
- The 5.15 fallback sits under the auto-generated "Advanced options" submenu,
  reachable by holding **Esc** or **Shift** during boot.
- Leave GRUB's `recordfail` behaviour intact — it surfaces the menu automatically
  after a failed boot, which is precisely when the fallback is needed.
- Document the Esc/Shift trick prominently in the README, since it is the entire
  recovery path for other owners.

---

## 3. Size target and package strategy

**Goal: minimal GNOME plus the listed apps, nothing else.**

Be realistic and state your actual figure: a workable minimal GNOME desktop plus
Firefox, mpv, and Wine lands roughly in the **3–4GB installed** range. That is
small relative to a stock Debian GNOME install (~8–10GB), but it is not a 1GB
system. Do not over-strip to hit an arbitrary number — a broken desktop is worse
than a larger one. Report the real installed size in your deliverables.

**Build up, do not install-then-remove.** Removal leaves orphans and apt drags
things back via recommends. Use `mmdebstrap --variant=minbase` plus an explicit
package list.

**Mandatory:**

- `APT::Install-Recommends "false";` in the image's apt config
- `dpkg` `path-exclude` for `/usr/share/man`, `/usr/share/doc`,
  `/usr/share/locale` (keep the user's locale + English)
- `force-unsafe-io` in `/etc/dpkg/dpkg.cfg.d/` (large speedup on slow eMMC)
- Clear apt lists and cache at the end of the build
- Enable the `non-free-firmware` component explicitly

### 3.1 GNOME — install these, not the metapackages

Do **not** install the `gnome` or `task-gnome-desktop` metapackages; they pull in
the entire application suite. `gnome-core` is smaller but still generous. Hand-pick.

Required (do not strip these — GNOME breaks in confusing ways without them):

- `gnome-shell`, `gnome-session`, `gnome-settings-daemon`, `gnome-control-center`
- `gdm3`
- `polkit` / `policykit-1` — **do not remove**, breaks mounting, power, auth
- `dconf-cli`, `dconf-gsettings-backend`, `gsettings-desktop-schemas`
- `xdg-desktop-portal`, `xdg-desktop-portal-gnome`
- `gnome-keyring` — Wi-Fi passwords silently fail to save without it
- `network-manager`, `network-manager-gnome`
- `gvfs`, `gvfs-backends`, `udisks2` — USB drives in the file manager
- `nautilus` (files), a terminal (`gnome-console` or `gnome-terminal`)
- `adwaita-icon-theme`, `fonts-cantarell` (GNOME's default UI font)
- `iio-sensor-proxy` — auto-rotation
- `gnome-initial-setup` — **keep this.** It is the polished first-boot flow for
  user account, locale, timezone, and keyboard. Essential when distributing to
  other owners who cannot use a terminal.

Explicitly exclude: `gnome-games`, `gnome-music`, `gnome-photos`, `gnome-maps`,
`gnome-weather`, `gnome-contacts`, `gnome-calendar`, `gnome-clocks`,
`gnome-characters`, `gnome-logs`, `totem` (mpv covers video), `rhythmbox`,
`cheese`, `simple-scan`, `evolution`, `libreoffice*`, `yelp`, `gnome-user-docs`,
`tracker` / `tracker-miners` (do not install rather than mask), `malcontent`.

Consider excluding `gnome-software` — apt covers updates and it is heavy. State
your recommendation.

### 3.2 Applications to preinstall

- `firefox-esr` — with VA-API prefs preconfigured (§5)
- `mpv` — with `hwdec=vaapi` configured
- Wine — see §6
- `vainfo`, `libva-intel-driver`, `mesa-va-drivers`
- `alsa-utils`, PipeWire stack (§4)
- `earlyoom`, `zram-tools`, `fstrim` timer

---

## 4. Fixes to bake in at build time

All of these are already implemented and debugged in the accompanying script
`casper-n220-master.sh` (v6.1, modules 1–10). **Read it and port its logic into
build hooks** rather than reimplementing from scratch. It encodes fixes that took
many iterations to get right.

**Touch & display**
- `intel_idle.max_cstate=1` — the touchscreen-freeze root cause (deep C-states
  gate the LPSS I2C clock the touch controller sits on)
- libinput quirk for touch/pointer separation — **validate the file**, see §7
- I2C udev rules keeping the bus powered
- Touchscreen reset script + Ctrl+Alt+R binding + I2C-timeout watchdog +
  suspend/resume hook
- `i915.enable_psr=0 enable_dc=0 enable_fbc=0` (flicker, stalls, corruption)

**Audio**
- PipeWire + WirePlumber. **Write config in both 0.4 Lua and 0.5 `.conf` syntax** —
  a config for only one version silently no-ops on the other
- `snd_intel_dspcfg.dsp_driver=2`, SST firmware from `firmware-intel-sound`
- UCM symlink `bytcrrt5640` → `bytcr-rt5640` (kernel reports the card name
  without dashes; ALSA matches exactly, so volume controls vanish without it)
- `snd_hda_intel.power_save=0` (kills the 5-second pop)

**Video**
- `libva-intel-driver` (i965). **Not `intel-media-driver`/iHD** — that requires
  Broadwell or newer and silently falls back to software decode here
- Pin `LIBVA_DRIVER_NAME=i965` in `/etc/environment.d/` and `/etc/profile.d/`
- Firefox prefs via `policies.json`: `media.ffmpeg.vaapi.enabled`,
  `media.rdd-ffmpeg.enabled`, `media.hardware-video-decoding.enabled` — all three,
  or the RDD sandbox blocks decode
- `/etc/mpv/mpv.conf` with `hwdec=vaapi`

**Performance (2GB RAM is the constraint)**
- zram 1.5GB lz4, `vm.swappiness=180`, `vm.page-cluster=0`
- `earlyoom` — prevents low-memory freezes that look exactly like the touch bug
- BFQ scheduler, `schedutil` governor, THP off, `noatime`
- `mitigations=off` — 20–40% syscall win on Silvermont
- Mask/omit: tracker, evolution-data-server, ModemManager, unattended-upgrades,
  `apt-daily` timers, `NetworkManager-wait-online`
- Journal capped at 50MB

**Wi-Fi**
- RTL8723BS powersave off: NetworkManager conf + `rtw_power_mgnt=0 rtw_ips_mode=0`

---

## 5. Branding — this is what makes it feel purpose-built

System-wide GNOME defaults **must** go in `/etc/dconf/db/local.d/` followed by
`dconf update`. Do **not** use `gsettings` in build hooks — there is no user yet,
so those calls apply to nobody. Anything placed in `/etc/skel/` is copied into
each new user's home at creation.

- Plymouth boot theme (custom splash)
- GRUB theme — mostly unseen given the hidden menu, but themed for the fallback path
- GDM login styling, wallpaper, GTK/icon theme via `dconf` system defaults
- `/etc/os-release`: custom `PRETTY_NAME` and `NAME` so it identifies as this
  build in About and on boot
- Tablet UX defaults: text scaling ~1.15, hot corners off, edge-tiling off,
  on-screen keyboard enabled, larger drag threshold

**Caveat to flag:** Plymouth costs ~1–2s of boot time and can flicker on Bay
Trail's i915 given the PSR/FBC quirks being disabled. Worth it, but expect it.

---

## 6. Wine — decide the 32-bit question explicitly

Wine must work out of the box with audio.

- `PULSE_LATENCY_MSEC=60` in `/etc/profile.d/`, `Audio=pulse` registry setting
- A `.wine` prefix is per-user and path-dependent, so it cannot be fully baked
  into the image. Ship a **first-login user service that runs `wineboot` once**,
  silently. Roughly a minute, once, then done.

**Decision you must make and report:** modern Wine (9.0+) has a new WoW64 mode
that can run 32-bit Windows applications without i386 host libraries. If the Wine
version in the chosen Debian release supports this adequately, **skip
`dpkg --add-architecture i386` entirely** and save several hundred MB of image
size. If it does not, enable i386 multiarch for `wine32` only.

Verify whether i386 multiarch still works normally on Trixie given the i386
architecture demotion. Report your finding and which path you took.

---

## 7. Known-bad configuration — do NOT reintroduce

A previous AI-generated guide for this device contained the following errors.
They are confirmed wrong. Do not copy them from any source you encounter:

- `vm.ksm=1` / `vm.ksm_threads=2` — **not real sysctls.** KSM lives in
  `/sys/kernel/mm/ksm/`. Writing these to `sysctl.d` silently does nothing.
- `vm.swappiness=10` with zram — backwards. Correct for slow disk swap, wrong for
  compressed-RAM swap. Use ~180 with `page-cluster=0`.
- `i915.enable_rc6=0` — removed from i915 in kernel 4.16. Dead. Use `enable_dc=0`.
- `video.use_native_backlight=1` — removed around kernel 4.4. Dead.
- `vm.overcommit_memory=1` — contradicts conservative memory tuning on 2GB.
- Driver names `i2c_hid`, `silead`, `goodix` — the real sysfs names are
  `i2c_hid_acpi`, `silead_ts`, `Goodix-TS`. Matching the old names is a no-op,
  which silently disabled the touchscreen reset and its watchdog for a long time.
- libinput quirk keys `MatchDriver` and `ModelTabletModeSwitch` — **not valid.**
  libinput rejects the *entire quirk file* on any parse error, so one bad key
  silently disables every quirk in it. **Validate any quirk file with the
  `libinput quirks` tooling as a build step** and fail the build if it rejects.
- `linux-firmware` — **does not exist on Debian.** Use `firmware-realtek`,
  `firmware-intel-sound`, `firmware-misc-nonfree` from `non-free-firmware`.
- `intel-media-driver` (iHD) for VA-API — wrong for Bay Trail (Broadwell+ only).

**General rule:** verify every kernel parameter, sysctl key, package name, and
driver name against current documentation before including it. Plausible-sounding
but nonexistent configuration names are the dominant failure mode in this
project's history, and they fail *silently*.

---

## 8. Image mechanics & distribution

- Output a **raw `.img`** flashable with `dd` / balenaEtcher / Ventoy
- Partition: FAT32 ESP (flagged `esp`/`boot`) + ext4 root
- Generate `/etc/fstab` with **UUIDs at build time**, after `mkfs`
- **First-boot resize** of the root partition — eMMC sizes vary between 32GB and
  64GB across these tablets, and the image must not waste the difference
- `gnome-initial-setup` handles user creation, locale, timezone on first boot
- Build host amd64, target amd64 → plain `chroot`, no qemu needed

**Before distributing to other owners, the build must:**
- Contain **no personal data** — no pre-created user account, no Wi-Fi
  credentials, no shell history, no SSH keys, no machine-id (leave
  `/etc/machine-id` empty so it regenerates per device)
- **Disclose `mitigations=off`** in the README. It is a deliberate, reasonable
  tradeoff on a personal media tablet, but other users must be told it is on.
- Note that Secure Boot must be disabled (mainline Ubuntu kernels are unsigned)

---

## 9. Deliverables

1. Reproducible build scripts, in the repo, runnable end to end
2. The resulting `.img`, with its **actual installed size** reported
3. README covering: flashing instructions, **the Esc/Shift fallback-kernel
   trick**, the `mitigations=off` disclosure, Secure Boot note, and the one
   remaining manual step — installing the **h264ify** browser extension, which
   forces YouTube to serve H.264 that this GPU can actually decode in hardware
   (it defaults to VP9/AV1, which Bay Trail cannot hardware-decode at all)
4. An explicit list of anything you could not verify, had to guess, or that
   needs testing on real hardware

## 10. What must be tested on the device (state this in the README)

These cannot be validated in a VM — Bay Trail's quirks do not reproduce there:
touchscreen behaviour under sustained use, audio output, VA-API hardware decode,
backlight control on each kernel, Wi-Fi stability, and auto-rotation.

Expect to iterate. Build the scripts so a rebuild is cheap.
