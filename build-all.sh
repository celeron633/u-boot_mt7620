#!/usr/bin/env bash
#
# Build every board configuration in one pass and collect the flashable
# images under dist/<model>/. Used by .github/workflows/build.yml, and
# usable by hand in WSL exactly the same way.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_dir"

cross_compile=${CROSS_COMPILE:-mipsel-linux-gnu-}
device_vendor=${DEVICE_VENDOR:-cleanwrt}
out_dir=${OUT_DIR:-dist}

# config file : model directory (192 KiB U-Boot partitions only)
boards=(
	'PSG1218:PSG1218'
	'PSG1218-V22.5:PSG1218-V22.5'
	'YK-L1:YK-L1'
	'HC5761:HC5761'
)

# Place uboot.bin at the start of a zero-filled partition image of $3 KiB.
# Refuse oversized images so they can never be silently truncated.
pad() {
	local src=$1 out=$2 kb=$3
	local limit=$((kb * 1024)) size
	size=$(stat -c %s "$src")
	if ((size > limit)); then
		echo "Skipping $(basename "$out"): uboot.bin is $size bytes," \
			"which does not fit a ${kb}KiB partition." >&2
		return 1
	fi
	dd if=/dev/zero of="$out" bs=1024 count="$kb" status=none
	dd if="$src" of="$out" conv=notrunc status=none
}

# Collect into a staging directory outside the tree. `make clean`/`clobber`
# sweep the whole repo with `find . -name '*.bin' | xargs rm -f`, so anything
# gathered under the repo is deleted again by the next board's build.
stage_dir=$(mktemp -d)
trap 'rm -rf "$stage_dir"' EXIT

manifest="$stage_dir/MANIFEST.txt"
{
	echo "commit : ${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
	echo "built  : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
	echo "vendor : ${device_vendor}"
	echo "target : $(${cross_compile}gcc --version | head -1)"
	echo "binutil: $(${cross_compile}ld --version | head -1)"
	echo "host   : $(${HOSTCC:-gcc} --version | head -1)"
	echo
	echo "Only the toolchain recorded above is verified (see BUILDING_WSL.md);"
	echo "images built with another compiler are untested on real hardware."
	echo
	printf '%-14s %-34s %9s  %s\n' MODEL FILE BYTES MD5
} > "$manifest"

for entry in "${boards[@]}"; do
	IFS=: read -r config model <<< "$entry"
	echo "=== $model ($config) ==="

	# No explicit clean: the tree's `all` target already depends on `clean`,
	# and build-wsl.sh regenerates httpd/fsdata.c for each configuration.
	CONFIG_FILE="$config" DEVICE_VENDOR="$device_vendor" bash ./build-wsl.sh

	if [[ ! -s uboot.bin ]]; then
		echo "No uboot.bin produced for $model" >&2
		exit 1
	fi

	model_dir="$stage_dir/$model"
	mkdir -p "$model_dir"
	cp uboot.bin "$model_dir/${model}_uboot.bin"
	pad uboot.bin "$model_dir/${model}_uboot_192k.bin" 192

	cat > "$model_dir/README.txt" <<NOTE
$model
U-Boot partition: 192 KiB -> flash ${model}_uboot_192k.bin

${model}_uboot.bin       raw output, no padding
${model}_uboot_192k.bin  same image padded with zeros to 192 KiB

Both hold identical code; only the trailing zero padding differs.
Web recovery upload wants the image that matches the partition size.
Writing a padded image larger than the U-Boot partition overwrites what
follows it, so do not use the 192 KiB file on a 128 KiB partition.

WARNING: a bad bootloader image does not boot and cannot be recovered over
the network -- it needs an SPI programmer. Before writing, dump the current
0x0-0x30000 to a file and keep it. Only the toolchain recorded in
MANIFEST.txt is verified; see BUILDING_WSL.md.
NOTE

	for f in "$model_dir"/*.bin; do
		printf '%-14s %-34s %9s  %s\n' \
			"$model" "$(basename "$f")" "$(stat -c %s "$f")" \
			"$(md5sum "$f" | cut -d' ' -f1)" >> "$manifest"
	done
done

rm -rf "$out_dir"
mkdir -p "$out_dir"
cp -R "$stage_dir/." "$out_dir/"

echo
cat "$out_dir/MANIFEST.txt"
