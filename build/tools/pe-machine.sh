#!/usr/bin/env bash
# Print the PE COFF machine type of an EFI binary as lowercase hex:
#   014c = IA-32 (32-bit, what Bay Trail firmware requires)
#   8664 = x86-64
#   0x01c2/01c4 = ARM/ARM64
#
# Why not `file | grep 80386`: the check that used to live in 04-assemble.sh
# depended on file(1)'s exact wording ("Intel 80386", "IA-32", ...), which
# changes between file versions. This reads the two bytes Microsoft actually
# defines, so the verdict is the same on every host - and when it fails it can
# say WHICH machine the binary is instead of just "not IA-32".
#
# Usage: pe-machine.sh <pe-file>
set -euo pipefail

f="${1:?usage: pe-machine.sh <pe-file>}"
[ -f "$f" ] || { echo "pe-machine: not a file: $f" >&2; exit 1; }

# MZ magic
mz=$(od -An -tx1 -j 0 -N2 "$f" 2>/dev/null | tr -d ' \n')
[ "$mz" = "4d5a" ] || { echo "pe-machine: no MZ header: $f" >&2; exit 1; }

# e_lfanew at 0x3c: file offset of the PE header
off=$(od -An -tu4 -j 60 -N4 "$f" 2>/dev/null | tr -d ' \n')
case "$off" in
    ''|*[!0-9]*) echo "pe-machine: cannot read e_lfanew: $f" >&2; exit 1 ;;
esac
size=$(stat -c %s "$f")
[ "$off" -lt "$size" ] || { echo "pe-machine: e_lfanew $off beyond EOF ($size): $f" >&2; exit 1; }

# "PE\0\0" signature, then the 2-byte Machine field
sig=$(od -An -tx1 -j "$off" -N4 "$f" 2>/dev/null | tr -d ' \n')
[ "$sig" = "50450000" ] || { echo "pe-machine: no PE signature at $off: $f" >&2; exit 1; }

machine=$(od -An -tx2 -j $((off + 4)) -N2 "$f" 2>/dev/null | tr -d ' \n')
[ -n "$machine" ] || { echo "pe-machine: cannot read Machine: $f" >&2; exit 1; }
printf '%s\n' "$machine"
