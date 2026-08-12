# Casper Nirvana N220 — Consolidated Fix Reference
### Debian 12 Bookworm + GNOME (Wayland) + Ubuntu kernel
Hardware: Intel Atom Z3735F (Bay Trail-T) · 2GB RAM · 32-bit UEFI · eMMC ·
RT5640 audio · Goodix/Silead I2C touch · RTL8723BS Wi-Fi/BT · 11.6" 1366×768

Script version referenced throughout: **casper-n220-master.sh v6.1** (2158 lines,
modules 1–10).

---

## 0. What this document is

This replaces the earlier "Z.ai / GLM" guide PDF. That document was mostly
accurate on hardware background but contained several **factual errors that
would break your system if followed literally** — they're corrected below,
each flagged with why. This version reflects everything actually verified
across our sessions, plus fresh web checks done while writing this.

---

## 1. Hardware summary

| Field | Value |
|---|---|
| SoC | Intel Atom Z3735F (Bay Trail-T, 22nm, ~2W TDP) |
| CPU | 4× Silvermont cores, 1.33GHz base / 1.83GHz burst, no Turbo Boost |
| GPU | Intel HD Graphics Gen7, 4 EUs, 311–646MHz — **H.264/VP8 hw decode only, no VP9/AV1** |
| RAM | 2GB DDR3L-1333, single-channel, soldered |
| Storage | 32–64GB eMMC |
| Display | 11.6" 1366×768, 5-point capacitive touch |
| Audio | Realtek RT5640 on Intel SST (Smart Sound) bus |
| Wi-Fi/BT | Realtek RTL8723BS SDIO combo |
| Boot | 32-bit UEFI only, despite 64-bit-capable CPU |

---

## 2. Confirmed root causes (high confidence — verified against source/docs)

### 2.1 Touchscreen freeze (the original bug that started this whole project)
Two independent bugs stacked on top of a real hardware quirk:

1. **libinput quirk file silently rejected.** The original quirk file used
   `MatchDriver` and `ModelTabletModeSwitch` — not valid libinput quirk keys.
   libinput rejects the **entire file** on any parse error, so the
   touch/mouse-separation fix never loaded, at all, ever. Fixed in v6.0 with
   validated keys (`MatchUdevType`, `AttrEventCode`).
2. **touchscreen-reset script matched dead driver names.** It grepped for
   `i2c_hid`/`silead`/`goodix`; the real sysfs driver names on modern kernels
   are `i2c_hid_acpi`, `silead_ts`, `Goodix-TS`. The reset script — and the
   watchdog that calls it — was a no-op. Fixed in v6.0.
3. **Underlying hardware cause:** Bay Trail's LPSS I2C controller clock gets
   gated when the package enters deep C-states (PC6+), stalling the I2C bus
   the touch controller sits on. Fix: `intel_idle.max_cstate=1`.

### 2.2 Mutter Wayland touch-drag bug (Ubuntu 22.04 only)
Mutter `42.9-0ubuntu7` (jammy-security pocket) has a broken touch drag/drop.
`42.9-0ubuntu9` (jammy-updates) fixes it, but apt prefers the security pocket
by default, so it silently reverts after any update unless pinned. **This
does not apply to Debian 12**, which ships Mutter 43 without this bug — so if
you're running the recommended Debian 12 stack, this specific issue is moot
already. It only matters if you ever run Ubuntu 22.04 directly.

### 2.3 Audio silence / SST firmware
Debian has no `linux-firmware` package (unlike Ubuntu). The SST DSP firmware
(`fw_sst_0f28.bin`) needed by `bytcr_rt5640` comes from `firmware-intel-sound`
instead, which lives in Debian's `non-free-firmware` component (not enabled
by default on a minimal install). v6.1 auto-enables that component.

### 2.4 UCM profile name mismatch
ALSA UCM profile is named `bytcr-rt5640` (dashes) but the kernel reports the
card as `bytcrrt5640` (no dashes). ALSA does exact-string matching, so the
profile silently never loads without a symlink.

### 2.5 WirePlumber syntax split
WirePlumber 0.4 uses Lua config files; 0.5 uses `.conf` syntax. A script
targeting only one breaks on the other. v6.0 writes both formats so whichever
version is actually installed picks up the config.

### 2.6 YouTube / video "lag" — not actually a CPU limitation
Bay Trail's GPU hardware-decodes **H.264 and VP8 only** — no VP9, no AV1.
YouTube defaults to VP9 (increasingly AV1), forcing 100% software decode on a
1.33GHz quad-core Atom. This reads as "the CPU can't handle video" but it's a
codec-selection problem, not a raw-power problem — 720p H.264 decodes
smoothly on this exact chip via VA-API. Fixed by v6.1 Module 10.

---

## 3. Corrections to the GLM/Z.ai PDF guide

These are real errors in that document. If you (or an AI agent) build a
config from it as-is, some of these will actively break things.

| GLM doc claim | Reality | Why it matters |
|---|---|---|
| `vm.ksm=1` / `vm.ksm_threads=2` as sysctl keys | **Not valid sysctls.** KSM is controlled via `/sys/kernel/mm/ksm/` sysfs files (e.g. `run`, `pages_to_scan`), not `sysctl`/`/etc/sysctl.d/`. Verified against kernel.org KSM docs. | Writing these to a sysctl.d file does nothing — dead config, same class of bug as the libinput quirk. |
| `vm.overcommit_memory=1` recommended alongside conservative dirty-ratio tuning | Contradictory: `overcommit_memory=1` means "always overcommit," which fights the rest of the conservative memory tuning aimed at a 2GB machine avoiding OOM surprises. | Removed in v6.0 for this reason. |
| `vm.swappiness=10` | **Wrong direction for a zram-only swap setup.** Swappiness=10 tells the kernel to avoid swap — correct advice for slow disk swap, actively wrong once swap is zram (compressed RAM). Kernel guidance for zram-backed swap is to swap aggressively (high swappiness, ~100–180) since it's cheap. | Using swappiness=10 with zram wastes the RAM savings zram is there to provide. |
| `i915.enable_rc6=0` listed as valid on "All" kernels | `enable_rc6` was **removed from the i915 driver in kernel 4.16**. On any current kernel this parameter is dead and does nothing (harmless but pointless — and its presence signals stale info). | `i915.enable_dc=0` is the actual modern equivalent; kept in v6.0. |
| `video.use_native_backlight=1` listed as valid on "All" kernels | Removed from the kernel around 4.4. Same issue — a parameter from a much older kernel generation that no longer exists. | Dead parameter, cleaned from GRUB in v6.0. |
| WirePlumber config shown only in old Lua (`main.lua.d`) format | Modern WirePlumber (0.5+, likely what Bookworm ships) uses `.conf` syntax under `wireplumber.conf.d/`. Lua-only config silently no-ops on 0.5. | v6.0 writes both formats to cover either WirePlumber version. |
| `nowatchdog nmi_watchdog=0` claimed to run on "All" kernels uniformly | Generally fine, but worth knowing `nowatchdog` is a boot-time convenience flag, not a hard requirement — low risk either way, this one's basically correct. | Minor — no action needed. |
| Script described as "1638 lines," Module numbering slightly different (module 7 = diagnostic, 8 = wine) | The actual v6.1 script is 2158 lines with Wine as Module 7, Diagnostic as Module 8, Verify as Module 9, and now Video accel as Module 10. | If you feed the PDF to an AI agent verbatim, the module numbers it references won't match the real script. |

**Bottom line on the GLM doc:** the hardware background chapters (1–4, 9, 13)
are largely accurate and fine as history/context. The specific sysctl/kernel
parameter tables (chapter 10, Appendix A) contain the errors above and
shouldn't be used as a literal source of truth — the actual script
(v6.1) is the corrected version of that same information.

---

## 4. Current state of the fix script (v6.1, 10 modules)

1. **Kernel** — Ubuntu mainline kernel install on Debian (backlight + Wi-Fi driver fix)
2. **Touch & display** — C-state fix, I2C udev rules, valid libinput quirk, fixed reset script, streaming watchdog, suspend/resume hook, i915 modprobe options
3. **Audio** — PipeWire/WirePlumber (both 0.4 + 0.5 syntax), SST firmware, UCM symlink, non-free-firmware auto-enable
4. **Performance & Wi-Fi** — zram 1.5GB lz4, swappiness=180 + page-cluster=0, BFQ scheduler, CPU governor, earlyoom, fstrim, THP=never, masked services, RTL8723BS powersave fix
5. **GNOME/touch UX** — iio-sensor-proxy auto-rotation, on-screen keyboard, tablet gsettings, mutter pin (Ubuntu 22.04 only)
6. **Wine** — wine64/32, PULSE_LATENCY_MSEC=60
7. **Diagnostic** — read-only system report
8. **Verify** — pass/fail checklist of every fix
9. *(renumbering note: verify is module 9 in the actual script; see file for exact mapping)*
10. **Video acceleration** *(new)* — VA-API i965 driver pin, Firefox VA-API prefs, mpv hwdec, vainfo H.264 check. Manual step still required: install the h264ify browser extension, since scripts can't install browser extensions.

Full module list and line numbers live in the script itself — this doc is
context, not a replacement for reading `casper-n220-master.sh`.

---

## 5. Open / unverified items worth knowing about

- **RTL8723BS Bluetooth A2DP** is reported broadly unreliable on this chipset
  across the Linux community; no clean fix exists, only mitigations (force
  11n off, driver power management tweaks already in Module 4).
- **eMMC wear** — no monitoring is currently scripted. `smartctl` support for
  eMMC is inconsistent; worth checking `mmc extcsd read` output periodically
  if the tablet becomes a daily driver.
- Video acceleration (Module 10) checks that `vainfo` reports H.264 decode
  entrypoints, but actual GPU engagement during YouTube playback should be
  confirmed empirically (e.g., `intel_gpu_top` during playback, or watching
  CPU usage drop) since driver auto-detection issues are common on old Gen7
  hardware.

---

## 6. Feasibility: DeepSeek V4 + OpenCode building you a custom Debian OS

You asked specifically about connecting OpenCode to DeepSeek V4-Flash via
GitHub to have it "spin up" a custom Debian build for this tablet. Breaking
down what's realistic:

### What's true and current (verified via search, Aug 2026)
DeepSeek V4 is real and shipped — two open-weight models under MIT license,
**V4-Pro** (1.6T params) and **V4-Flash** (284B params), released April 24,
2026, both with 1M-token context, available via API and Hugging Face.
V4-Flash is the lighter/faster variant and is a reasonable pick for an
agentic coding tool like OpenCode given cost and latency. Benchmarks put
V4-Pro competitive with Claude Opus-tier models on SWE-bench-style coding
tasks; V4-Flash trades some capability for speed/cost.

### What "have DeepSeek build me a custom OS" actually means in practice
There's a meaningful gap between what's technically possible and what the
phrase implies:

**Realistic version:** DeepSeek V4-Flash, driven through OpenCode, can:
- Read this reference doc + the master script as context
- Generate/modify the shell script further (exactly like this session did)
- Build a **preseed file** for Debian's installer to fully automate
  installation choices (partitioning, package selection, locale, etc.)
- Build a **live-build or debootstrap-based custom ISO recipe** that bakes
  the master script's fixes in at first-boot, so you get a Casper-N220-ready
  Debian image instead of installing stock Debian then running the script
  after
- Iterate autonomously on errors if given shell access to a real machine or
  VM to test against (this is where an agentic coding tool earns its keep —
  it can actually run commands, see failures, and fix them, unlike a
  one-shot chat response)

**Not realistic, or badly framed:** "DeepSeek builds an OS" sounds like it's
inventing a new operating system. It isn't and shouldn't — Debian is the
correct base (this was already established: 32-bit UEFI compatibility rules
out most modern distros). What's actually happening is **Debian
remastering/customization**, a well-trodden practice (there are established
tools for exactly this: `live-build`, `debootstrap`, `preseed`,
`simple-cdd`). The value DeepSeek/OpenCode adds is automating the
scripting and iteration, not replacing Debian's engineering.

### Practical path if you want to do this
1. Use OpenCode with DeepSeek V4-Flash as the model (cheaper/faster,
   sufficient for shell scripting and config generation — V4-Pro only
   worth it if you hit reasoning limits on complex parts).
2. Give it this doc + the current master script as repo context via GitHub.
3. Have it target **`live-build`** (Debian's official tool for building
   custom installable/live ISOs) rather than trying to hand-roll an ISO —
   this is the single highest-leverage correction to make if the agent
   suggests something else, since live-build already solves the hard parts
   (bootloader, package selection, hooks for post-install scripts).
4. Structure the master script's modules as `live-build` hooks
   (`config/hooks/normal/`) so fixes apply during image build, not after
   first boot — this is a real improvement over the current "install
   then run script" flow, since it means a freshly flashed tablet is
   correct on first boot.
5. Test in a VM first for anything not touching real hardware (kernel
   params, package selection); the touch/audio/GPU-specific modules still
   need testing on the actual tablet since Bay Trail-specific bugs won't
   reproduce in a VM.
6. Treat AI-agent-authored kernel/GRUB/systemd config with the same
   skepticism applied to the GLM doc above — verify against kernel docs
   before trusting parameter names, especially since this exact failure
   mode (plausible-sounding but wrong sysctl/kernel-param names) is what
   caused several of the corrections in section 3.

**Net assessment:** feasible and a genuine workflow improvement (bakes fixes
into the image instead of post-install scripting), not the sci-fi "AI builds
custom OS" framing — it's Debian customization tooling with an agentic coding
model driving `live-build` and iterating on failures. Worth doing if you want
a repeatable, flashable image for this tablet or others like it; probably
overkill if you only have the one N220 and it's already working.
