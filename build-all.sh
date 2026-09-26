#!/usr/bin/env bash
#
# Build every board configuration in one pass and collect the flashable
# images under dist/<model>/. Used by .github/workflows/build.yml, and
# usable by hand in WSL exactly the same way.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_dir"

device_vendor=${DEVICE_VENDOR:-cleanwrt}
out_dir=${OUT_DIR:-dist}

# config file : model directory : real U-Boot partition size in KiB
boards=(
	'Ai-BR100:Ai-BR100:128'
	'PSG1218:PSG1218:192'
	'PSG1218-V22.5:PSG1218-V22.5:192'
	'YK-L1:YK-L1:192'
	'HC5761:HC5761:192'
)

# Place uboot.bin at the start of a zero-filled partition image of $3 KiB.
# The tree's own dd rules truncate when the build outgrows the partition;
# refuse instead, so a short image never gets mistaken for a good one.
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
	echo
	printf '%-14s %-34s %9s  %s\n' MODEL FILE BYTES MD5
} > "$manifest"

for entry in "${boards[@]}"; do
	IFS=: read -r config model native <<< "$entry"
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
	pad uboot.bin "$model_dir/${model}_uboot_128k.bin" 128 || true
	pad uboot.bin "$model_dir/${model}_uboot_192k.bin" 192 || true

	cat > "$model_dir/README.txt" <<NOTE
$model
U-Boot partition: ${native} KiB -> flash ${model}_uboot_${native}k.bin

${model}_uboot.bin       raw output, no padding
${model}_uboot_128k.bin  same image padded with zeros to 128 KiB
${model}_uboot_192k.bin  same image padded with zeros to 192 KiB

All three hold identical code; only the trailing zero padding differs.
Web recovery upload wants the image that matches the partition size.
Writing a padded image larger than the U-Boot partition overwrites what
follows it, so do not use the 192 KiB file on a 128 KiB partition.
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
