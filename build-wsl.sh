#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_dir"

config_file=${CONFIG_FILE:-HC5761}
cross_compile=${CROSS_COMPILE:-mipsel-linux-gnu-}
host_cc=${HOSTCC:-gcc}
MIPSFLAGS_HINT="-mabicalls (cpu/ralink_soc/config.mk)"

if [[ ! -f "$config_file" ]]; then
	echo "Configuration not found: $config_file" >&2
	exit 1
fi

if ! grep -qE '^(PSG1218_BOARD|YK_L1_BOARD|HC5761_BOARD)=y$' "$config_file"; then
	echo "128 KiB builds are disabled. Select PSG1218, PSG1218-V22.5, HC5761 or YK-L1." >&2
	exit 1
fi

required_tools=(make awk "${cross_compile}gcc" "${cross_compile}ld" \
	"${cross_compile}objcopy" "$host_cc")
missing_tools=()
for tool in "${required_tools[@]}"; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		missing_tools+=("$tool")
	fi
done

if ((${#missing_tools[@]})); then
	echo "Missing build tools: ${missing_tools[*]}" >&2
	echo "On Debian/Ubuntu install: build-essential gcc-mipsel-linux-gnu" >&2
	echo "  binutils-mipsel-linux-gnu zlib1g-dev" >&2
	exit 1
fi

if ! printf '#include <zlib.h>\n' | "$host_cc" -E -x c - >/dev/null 2>&1; then
	echo "The host zlib headers are missing (install zlib1g-dev)." >&2
	exit 1
fi

cp "$config_file" .config

# Recreate the header subset emitted by the old Menuconfig script.
awk '
BEGIN {
	print "/*"
	print " * Automatically generated from " ARGV[1] ": do not edit"
	print " */"
	print "#define AUTOCONF_INCLUDED"
}
/^# [A-Za-z_][A-Za-z0-9_]* is not set$/ {
	print "#undef  " $2
	next
}
/^[A-Za-z_][A-Za-z0-9_]*=y$/ {
	name = $0
	sub(/=y$/, "", name)
	print "#define " name " 1"
	next
}
/^[A-Za-z_][A-Za-z0-9_]*=/ {
	split($0, pair, "=")
	name = pair[1]
	value = substr($0, length(name) + 2)
	print "#define " name " " value
}
' "$config_file" > autoconf.h.tmp
mv autoconf.h.tmp autoconf.h

# The HTTP make rule does not recover from a failed/partial generation.
rm -f httpd/fsdata.c
(
	cd httpd
	./vendors/makefsdatac "${DEVICE_VENDOR:-cleanwrt}"
)
if [[ ! -s httpd/fsdata.c ]]; then
	echo "Failed to generate httpd/fsdata.c" >&2
	exit 1
fi

# Do not parallelize: this old tree makes `clean` and all outputs siblings.
make -j1 CROSS_COMPILE="$cross_compile" HOSTCC="$host_cc" "$@"

# This tree is built -mabicalls/PIC and start.S relocates itself out of the
# 0xBC000000 flash window into RAM. A non-PIC build instead links absolute
# `jal` targets and an absolute gp, and `jal` resolves against the top nibble
# of the *running* PC, so those calls are only correct while executing from
# flash. After relocate_code the first one jumps into unwritten RAM and the
# board never boots -- writing such an image bricks the device. GCC 13 has
# been seen to emit exactly this, so verify the link output before reporting
# a usable firmware.
if [[ -f u-boot ]]; then
	elf_flags=$("${cross_compile}readelf" -h u-boot |
		sed -n 's/^[[:space:]]*Flags:[[:space:]]*//p')
	# Compare whole comma-separated items: "cpic" contains "pic" as a
	# substring, so a plain match would accept a build that has neither.
	flags_csv=",$(printf '%s' "$elf_flags" | tr -d ' '),"
	for want in pic cpic; do
		case $flags_csv in
		*",$want,"*) ;;
		*)
			echo "u-boot is not a PIC build: ELF flags are '$elf_flags'." >&2
			echo "Such an image does not survive relocation and will not" >&2
			echo "boot. Check that $MIPSFLAGS_HINT reached the compiler." >&2
			exit 1
			;;
		esac
	done

	# objdump prints the mnemonic after a tab, so require whitespace before
	# it; that keeps "jalr t9" (the GOT-indirect form, which is fine) out.
	abs_jal=$("${cross_compile}objdump" -d u-boot |
		grep -cE '[[:space:]]jal[[:space:]]+0x' || true)
	if [[ $abs_jal -ne 0 ]]; then
		echo "u-boot contains $abs_jal absolute 'jal' calls, which break" >&2
		echo "once the image is relocated into RAM. Refusing to report a" >&2
		echo "flashable firmware." >&2
		exit 1
	fi
fi

if [[ -f uboot.bin ]]; then
	echo
	echo "Firmware: $repo_dir/uboot.bin"
	artifacts=(uboot.bin)
	for artifact in uboot_192k.bin uboot.img; do
		[[ -f "$artifact" ]] && artifacts+=("$artifact")
	done
	wc -c "${artifacts[@]}"
fi
