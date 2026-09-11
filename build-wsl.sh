#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_dir"

config_file=${CONFIG_FILE:-Ai-BR100}
cross_compile=${CROSS_COMPILE:-mipsel-linux-gnu-}
host_cc=${HOSTCC:-gcc}

if [[ ! -f "$config_file" ]]; then
	echo "Configuration not found: $config_file" >&2
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

# Ai-BR100 is a saved menuconfig file, but the generated header was not
# committed. Recreate the subset emitted by the old Menuconfig script.
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

if [[ -f uboot.bin ]]; then
	echo
	echo "Firmware: $repo_dir/uboot.bin"
	artifacts=(uboot.bin)
	for artifact in uboot_128k.bin uboot_192k.bin uboot.img; do
		[[ -f "$artifact" ]] && artifacts+=("$artifact")
	done
	wc -c "${artifacts[@]}"
fi
