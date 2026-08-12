#!/usr/bin/env bash
# grub-casper-postprocess.sh — post-process a generated grub.cfg.
#
#   1. Replace every occurrence of the BUILD HOST's root UUID with the
#      IMAGE's root UUID. (update-grub inside a chroot sees the host's
#      /proc and can stamp the host UUID into the menuentry linux lines
#      and the header search --set=root lines. Without this fix the image
#      cannot find its own root and fails to boot.)
#
#   2. Append the legacy Bay Trail I2C kernel parameters ONLY to the
#      Ubuntu mainline 5.15 fallback kernel entries:
#        i2c_designware.disable_pm=1 i2c_hid.use_polling_mode=1
#      (Correct for 5.15; on 6.8+ they break the reworked i2c_hid_acpi
#      driver, so they must never land on the 6.12 default entry.)
#
# Usage: grub-casper-postprocess.sh <grub.cfg> [host_root_uuid] [image_root_uuid]
set -euo pipefail

cfg="$1"
host_uuid="${2:-}"
img_uuid="${3:-}"
[ -f "$cfg" ] || { echo "no such file: $cfg" >&2; exit 1; }

tmp="$(mktemp)"
awk -v hu="$host_uuid" -v iu="$img_uuid" '
function fix_uuid(s) {
    if (hu != "" && iu != "" && index(s, hu)) {
        g = s
        gsub(hu, iu, g)
        return g
    }
    return s
}
/^[ \t]*menuentry / {
    in_entry = 1
    is_515 = 0
    done_515 = 0
}
{
    if (in_entry && !is_515 && $0 ~ /linux[ \t]+\/boot\/vmlinuz-5\.15/) is_515 = 1
    if (in_entry && is_515 && !done_515 && $0 ~ /linux[ \t]+\/boot\/vmlinuz-5\.15/) {
        line = fix_uuid($0)
        print line " i2c_designware.disable_pm=1 i2c_hid.use_polling_mode=1"
        done_515 = 1
        next
    }
    print fix_uuid($0)
    if ($0 ~ /^}/) in_entry = 0
}
' "$cfg" > "$tmp" && mv "$tmp" "$cfg"

echo "post-processed $cfg"
if [ -n "$host_uuid" ] && [ -n "$img_uuid" ]; then
    if grep -q "$host_uuid" "$cfg" 2>/dev/null; then
        echo "ERROR: host UUID still present in grub.cfg" >&2
        exit 1
    fi
    echo "OK: host UUID fully replaced"
fi
echo "5.15 entries with legacy I2C params: $(grep -c 'vmlinuz-5\.15.*i2c_designware.disable_pm=1' "$cfg")"
echo "6.12 entries with legacy I2C params (must be 0): $(grep -c 'vmlinuz-6\.\..*i2c_designware.disable_pm=1' "$cfg")"
