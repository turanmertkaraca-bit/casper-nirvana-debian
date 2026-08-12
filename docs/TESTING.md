# TESTING.md — on-device checklist after flashing

The automated KVM smoke test verifies boot, both kernels, GRUB/EFI setup,
services, and the dconf defaults. It **cannot** verify anything that needs
the real Bay Trail hardware. Run through this on the tablet after flashing.

## Before you start

- Clock/locale correct? (Settings → System → Date & Time, Region & Language)
- Connect to Wi-Fi (Settings → Wi-Fi). Turkish keyboard already active;
  switch with the language key if you have a dock.
- First boot is slow (root partition resize) — let it settle, then reboot
  once and note how fast the second boot feels.

## Checklist

1. **Boot flow** — power on: no GRUB menu frame at all → CasperOS splash →
   GDM login (landscape, not sideways) → tap the `lvy` tile → desktop.
   - If the display is sideways: rotate once in Settings → Displays and
     tell me — the `monitors.xml` rotation may need flipping (see §7 below).
   - If you ever need the menu: hold Shift at the splash.
2. **Touchscreen** — swipe between workspaces, use the on-screen keyboard
   (tap a text field), drag apps, use it for 30+ minutes including suspend/
   resume cycles. The watchdog auto-resets it if it wedges; Ctrl+Alt+R also
   resets it manually.
3. **Audio** — play music, pause 60 seconds, play again: the first sound
   must not be cut. Check `Settings → Sound` shows the RT5640 output and a
   volume slider. If no sound: `sudo dmesg | grep -i bytcr` and
   `ls /lib/firmware/intel/fw_sst_0f28.bin` (must exist).
4. **YouTube** — install **h264ify** in Firefox first, then play a 720p
   video. CPU should stay low (hardware decode). Watch `intel_gpu_top` or
   CPU%: if a core sits at 100%, VA-API isn't engaging — report `vainfo`
   output.
5. **Video playback** — open an H.264 `.mp4` with Files → mpv: smooth,
   hardware decode. `mpv --hwdec=vaapi` is the default config.
6. **Wi-Fi** — several hours of use: no multi-second stalls. The RTL8723BS
   powersave is disabled in both NetworkManager and the driver.
7. **Rotation** — rotate the tablet: screen auto-rotates (iio-sensor-proxy);
   the rotation-lock toggle is in the quick settings.
8. **Fallback kernel** — hold Shift at splash → Advanced options → boot
   `5.15.165`. Verify: touch works, display is landscape, Wi-Fi works, boot
   completes. (This is the recovery path if 6.12 ever misbehaves.)
9. **Suspend/resume** — suspend (power button), resume: touch works, Wi-Fi
   reconnects, sound still clean.
10. **Battery** — one full discharge cycle; report time. zram/earlyoom
    should keep the UI responsive under load; if a heavy page OOMs, that's
    earlyoom working — the desktop survives.

## Rotation troubleshooting (§7)

`monitors.xml` sets rotation `right` for connector `eDP-1` (with `unknown`
vendor wildcards, so it applies to any panel on that connector). If the
display boots sideways the *other* way:

```bash
sudo sed -i 's/<rotation>right<\/rotation>/<rotation>left<\/rotation>/' \
  /etc/skel/.config/monitors.xml /var/lib/gdm3/.config/monitors.xml \
  /home/lvy/.config/monitors.xml
```

then log out/in (GDM reads its own copy). If the connector isn't `eDP-1`
(the file is ignored, display stays as in Settings → Displays), find it
with `sudo ls /sys/class/drm/*/status | grep -i eDP` and update the
`<connector>` tag — or just fix orientation once in Settings and it will
be remembered per user.

## Report back

For anything failing, paste: `sudo casper-n220 --diagnostic` equivalent:
`uname -r; dmesg | tail -50; systemctl --failed; journalctl -p err -b`.
The build repo lives at https://github.com/turanmertkaraca-bit/casper-nirvana-debian
