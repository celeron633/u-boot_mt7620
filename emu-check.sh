#!/usr/bin/env bash
#
# Run a U-Boot image in the MT7620 emulator and report whether it survives
# relocation.
#
# tools/mt7620emu.py prints everything it knows; this wrapper makes one command
# enough. It finds a Python that can import unicorn (creating a venv in the
# user cache on first use, since Debian's system Python refuses pip installs),
# picks a System.map for symbol names, runs chunked so a native unicorn crash
# still shows how far the image got, and then names the addresses that matter:
# the escape point, its target, and the last PC.
#
# What the verdict means:
#   0  the image stayed inside its own code. It is not proof that the board
#      boots -- peripherals are stubs -- but it rules out the failure this tool
#      exists for.
#   1  the image jumped out of valid code after relocate_code, which is what a
#      non-PIC build does and what bricks a board. Do not flash it; see
#      "为什么必须用验证过的工具链" in BUILDING_WSL.md. Rebuild with the
#      verified toolchain.
#   2  usage or setup failure, or the emulator produced nothing to judge.
#
# Usage: bash emu-check.sh <image> [extra mt7620emu.py options]
#
# The System.map is only honest when it belongs to the same build as the image,
# so pass --symbols <map> when the image came from somewhere else.

set -euo pipefail

usage() {
	echo "usage: bash emu-check.sh <image> [extra mt7620emu.py options]" >&2
	exit 2
}

(($# >= 1)) || usage
image=$1
shift

if [[ ! -f $image ]]; then
	echo "Not a file: $image" >&2
	exit 2
fi
if [[ ! -s $image ]]; then
	echo "Empty file: $image" >&2
	exit 2
fi

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
emulator=$repo_dir/tools/mt7620emu.py
if [[ ! -f $emulator ]]; then
	echo "Emulator not found: $emulator" >&2
	exit 2
fi

# Chunked execution: the console output and the last PC survive even if unicorn
# dies natively. 8M instructions is a few seconds and is enough for both
# outcomes seen so far -- a bad image escapes within the first chunk, a good one
# reaches board init and parks in a polling loop. Longer budgets only let an
# escaped image slide through zeroed memory until it runs off the mapped RAM,
# which tells us nothing; pass --step/--max-insn to override.
venv_dir=${XDG_CACHE_HOME:-$HOME/.cache}/mt7620emu/venv

find_python() {
	local candidate
	if [[ -n ${MT7620EMU_PYTHON:-} ]]; then
		printf '%s' "$MT7620EMU_PYTHON"
		return 0
	fi
	for candidate in python3 python; do
		if command -v "$candidate" >/dev/null 2>&1 &&
			"$candidate" -c 'import unicorn' >/dev/null 2>&1; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	if [[ -x $venv_dir/bin/python ]] &&
		"$venv_dir/bin/python" -c 'import unicorn' >/dev/null 2>&1; then
		printf '%s' "$venv_dir/bin/python"
		return 0
	fi
	return 1
}

python=$(find_python) || python=
if [[ -z $python ]]; then
	if [[ -e $venv_dir ]]; then
		echo "$venv_dir exists but cannot import unicorn." >&2
		echo "Remove it and retry, or point MT7620EMU_PYTHON at a Python" >&2
		echo "that has unicorn." >&2
		exit 2
	fi
	echo "No Python with unicorn; creating $venv_dir (pip install unicorn) ..." >&2
	if ! python3 -m venv "$venv_dir" 2>/dev/null; then
		echo "python3 -m venv failed. Install python3-venv, or run" >&2
		echo "'pip install unicorn' yourself and set MT7620EMU_PYTHON." >&2
		exit 2
	fi
	if ! "$venv_dir/bin/pip" install --quiet --disable-pip-version-check unicorn; then
		echo "pip install unicorn failed (no network?)." >&2
		exit 2
	fi
	echo "Installed unicorn in $venv_dir." >&2
	python=$venv_dir/bin/python
fi

# A map next to the image is taken at face value; the repo-root one is from
# whatever was built last, so the caller is warned below.
symbols=
symbols_is_local=yes
if [[ " $* " != *" --symbols"* ]]; then
	for candidate in "$(dirname "$image")/System.map" "$repo_dir/System.map"; do
		if [[ -f $candidate ]]; then
			symbols=$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")
			[[ $candidate == "$repo_dir/System.map" ]] || symbols_is_local=no
			break
		fi
	done
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT

cmd=("$python" "$emulator" "$image" --step 1000000 --max-insn 8000000)
if [[ -n $symbols ]]; then
	cmd+=(--symbols "$symbols")
	if [[ $symbols_is_local == no ]]; then
		echo "Note: symbols come from $symbols, which is the last build in this" >&2
		echo "      tree and may not match $image. Pass --symbols <map> to override." >&2
	fi
fi
if (($#)); then
	cmd+=("$@")
fi

echo "running: ${cmd[*]}"
"${cmd[@]}" 2>&1 | tee "$log"

# The emulator reports raw addresses. Turn the interesting ones back into
# symbols, using the relocation base the image itself printed, so both the
# flash window and the relocated copy resolve. A target that falls outside
# both is the region-absolute-jal signature: the top nibble of the target came
# from the running PC instead of the link address.
"$python" - "$log" "$symbols" <<'PY'
import re
import sys

log_path, map_path = sys.argv[1], sys.argv[2]
TEXT_BASE = 0xBC000000
IMAGE_WINDOW = 0x00080000
MAX_DELTA = 0x4000

text = open(log_path, errors="replace").read()


def hexof(pattern):
    m = re.search(pattern, text)
    return int(m.group(1), 16) if m else None


reloc_base = hexof(r"relocate_code Pointer at:\s*([0-9a-fA-F]+)")
esc_from = hexof(r"\[ESCAPE\] last sane block (0x[0-9a-fA-F]+)")
esc_to = hexof(r"\[ESCAPE\] jumped to\s+(0x[0-9a-fA-F]+)")
last_pc = hexof(r"stopped at PC\s*:\s*(0x[0-9a-fA-F]+)")
fault = re.search(r"first fault\s*:.*", text)
escaped = re.search(r"^escaped\s*:\s*(\w+)", text, re.M)

syms = []
if map_path:
    for line in open(map_path, errors="replace"):
        parts = line.split()
        if len(parts) >= 3 and parts[1] != "A":
            try:
                syms.append((int(parts[0], 16), parts[2]))
            except ValueError:
                pass
    syms.sort()


def nearest(addr):
    best = None
    for a, name in syms:
        if a <= addr:
            best = (a, name)
        else:
            break
    if best is None or addr - best[0] > MAX_DELTA:
        return ""
    if addr == best[0]:
        return best[1]
    return "%s+0x%x" % (best[1], addr - best[0])


def name_for(addr):
    if not syms or addr is None:
        return ""
    if TEXT_BASE <= addr < TEXT_BASE + IMAGE_WINDOW:
        link = addr
    elif reloc_base is not None and reloc_base <= addr < reloc_base + IMAGE_WINDOW:
        link = addr - (reloc_base - TEXT_BASE)
    else:
        return ""
    return nearest(link & 0xFFFFFFFF)


print()
print("=== emu-check ===")
if reloc_base is not None:
    print("reloc base : 0x%08X  (relocated copy of 0x%08X, %+#x)"
          % (reloc_base, TEXT_BASE, reloc_base - TEXT_BASE))
else:
    print("reloc base : never reported (image died before relocate_code)")
if esc_from is not None:
    print("escape from: 0x%08X  %s" % (esc_from, name_for(esc_from) or "(no symbol)"))
if esc_to is not None:
    print("escape to  : 0x%08X  %s" % (esc_to, name_for(esc_to) or "(outside both windows)"))
    if not name_for(esc_to) and syms:
        intended = (TEXT_BASE & 0xF0000000) | (esc_to & 0x0FFFFFFF)
        name = nearest(intended)
        if name:
            print("             = same low 28 bits as 0x%08X %s -- a"
                  % (intended, name))
            print("               region-absolute jal; its target keeps the")
            print("               top nibble of the running PC, not of the")
            print("               link address.")
# PC reads as 0 when unicorn stopped on a fault rather than on the budget.
if last_pc:
    print("last PC    : 0x%08X  %s" % (last_pc, name_for(last_pc) or "(no symbol)"))
if fault:
    print("fault      : %s" % fault.group(0))

print()
if escaped is None:
    print("verdict    : UNKNOWN -- no verdict line in the emulator output.")
    sys.exit(2)
if escaped.group(1) == "yes":
    print("verdict    : ESCAPED -- the image jumped out of valid code. Most")
    print("             likely a non-PIC build; do not flash it.")
    sys.exit(1)
print("verdict    : contained -- the image stayed inside its own code after")
print("             relocate_code. Not proof that the board boots, but the")
print("             non-PIC failure mode is ruled out.")
PY
