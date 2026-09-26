#!/usr/bin/env bash
#
# Compare two U-Boot images while ignoring the build timestamp.
#
# lib_mips/board.c bakes __DATE__/__TIME__ into version_string, so two builds
# of the same commit never have equal checksums. This reports whether the only
# differences sit inside those banners: if so the images are the same code and
# either is safe to flash; if not, something in the build differed and the
# image must not be flashed without knowing why.
#
# Usage: bash compare-image.sh <image-a> <image-b>

set -euo pipefail

usage() {
	echo "usage: bash compare-image.sh <image-a> <image-b>" >&2
	exit 2
}

(($# == 2)) || usage
a=$1
b=$2

for f in "$a" "$b"; do
	if [[ ! -f $f ]]; then
		echo "Not a file: $f" >&2
		exit 2
	fi
	if [[ ! -r $f ]]; then
		echo "Not readable: $f" >&2
		exit 2
	fi
	if [[ ! -s $f ]]; then
		echo "Empty file: $f" >&2
		exit 2
	fi
done

# "U-Boot 1.1.3 (Sep 26 2026 - 06:31:38)" -- allow a little slack past the end.
banner='U-Boot 1.1.3 ('
banner_len=48

size_a=$(stat -c %s "$a")
size_b=$(stat -c %s "$b")

banner_of() {
	local text
	text=$(strings -n 10 "$1" | grep -F -m1 "$banner") || text='(no banner found)'
	printf '%s' "$text"
}

echo "a: $a ($size_a bytes)"
echo "   banner: $(banner_of "$a")"
echo "b: $b ($size_b bytes)"
echo "   banner: $(banner_of "$b")"

if ((size_a != size_b)); then
	echo "DIFFERENT: file sizes do not match." >&2
	exit 1
fi

starts=()
while IFS= read -r off; do
	starts+=("$off")
done < <(grep -abo -F "$banner" "$a" | cut -d: -f1)

if ((${#starts[@]} == 0)); then
	echo "Warning: no version banner in $a; every differing byte counts." >&2
fi

in_banner() {
	local off=$1 s
	for s in "${starts[@]}"; do
		if ((off >= s && off < s + banner_len)); then
			return 0
		fi
	done
	return 1
}

# cmp exits 1 when the files differ and >1 on a real error; only the latter
# must abort, and an aborted cmp must never be read as "no differences".
diff_list=$(cmp -l "$a" "$b") && cmp_rc=0 || cmp_rc=$?
if ((cmp_rc > 1)); then
	echo "cmp failed on $a / $b" >&2
	exit 2
fi

total=0
outside=0
first_outside=
if [[ -n $diff_list ]]; then
	while read -r pos _ _; do
		((++total))
		# cmp -l reports 1-based positions.
		if ! in_banner $((pos - 1)); then
			((++outside))
			[[ -n $first_outside ]] || first_outside=$((pos - 1))
		fi
	done <<< "$diff_list"
fi

echo "differing bytes: $total total, $outside outside the version banner"

if ((outside == 0)); then
	echo "SAME CODE: the only differences are the build timestamp."
else
	echo "DIFFERENT CODE: first mismatch outside the banner at offset $first_outside." >&2
	echo "Do not flash this image until the build difference is explained." >&2
	exit 1
fi
