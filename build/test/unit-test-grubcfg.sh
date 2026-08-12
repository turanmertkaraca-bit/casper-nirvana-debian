#!/usr/bin/env bash
# Unit test for grub-casper-postprocess.sh — runs on any machine with bash.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"

cat > /tmp/grub-test.cfg <<'EOF'
set default="0"
set timeout_style=hidden
set timeout=1
if [ x$feature_platform_search_hint = xy ]; then
  search --no-floppy --fs-uuid --set=root HOSTROOTUUID123
else
  search --no-floppy --fs-uuid --set=root HOSTROOTUUID123
fi
menuentry 'Debian GNU/Linux' --class debian --class gnu-linux $menuentry_id_option 'gnulinux-simple-IMGROOT1' {
	load_video
	insmod gzio
	if [ x$grub_platform = xxen ]; then insmod xenhypo; fi
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root HOSTROOTUUID123
	linux	/boot/vmlinuz-6.12.9-amd64 root=UUID=HOSTROOTUUID123 ro quiet splash intel_idle.max_cstate=1
	initrd	/boot/initrd.img-6.12.9-amd64
}
menuentry 'Debian GNU/Linux, with Linux 5.15.165-0515165-generic' --class debian $menuentry_id_option 'gnulinux-5.15.165-0515165-generic-advanced-IMGROOT1' {
	search --no-floppy --fs-uuid --set=root HOSTROOTUUID123
	linux	/boot/vmlinuz-5.15.165-0515165-generic root=UUID=HOSTROOTUUID123 ro quiet splash intel_idle.max_cstate=1
	initrd	/boot/initrd.img-5.15.165-0515165-generic
}
EOF

bash "$SRC/tools/grub-casper-postprocess.sh" /tmp/grub-test.cfg HOSTROOTUUID123 IMGROOT1 >/dev/null

fail=0
grep -q 'root=UUID=IMGROOT1' /tmp/grub-test.cfg || { echo "FAIL: root UUID not replaced"; fail=1; }
! grep -q 'HOSTROOTUUID123' /tmp/grub-test.cfg || { echo "FAIL: host UUID still present"; fail=1; }
grep -q 'vmlinuz-5.15.165-0515165-generic.*i2c_designware.disable_pm=1 i2c_hid.use_polling_mode=1' /tmp/grub-test.cfg \
    || { echo "FAIL: 5.15 entry missing legacy I2C params"; fail=1; }
grep -q 'vmlinuz-6.12' /tmp/grub-test.cfg \
    && ! grep -q 'vmlinuz-6.12.*i2c_designware' /tmp/grub-test.cfg \
    || { echo "FAIL: 6.12 entry wrongly got I2C params"; fail=1; }

if [ "$fail" = 0 ]; then
    echo "PASS: grub postprocessor"
else
    echo "grub-test.cfg after processing:"; cat /tmp/grub-test.cfg
    exit 1
fi
