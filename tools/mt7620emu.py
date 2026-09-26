"""Minimal MT7620 (MIPS32r2 LE) emulator for U-Boot bring-up triage.

Maps the SPI flash image at its link address, aliases DDR through KSEG0/KSEG1,
stubs the Ralink SoC registers, and emulates the console UART so U-Boot's own
output is captured. Reports where execution stalls.
"""
import argparse
import collections
import ctypes
import sys

from unicorn import *
from unicorn.mips_const import *

# Unicorn emulates the MIPS MMU, so KSEG0/KSEG1 virtual addresses are
# translated to physical before reaching a mapping: 0xBC000000 -> 0x1C000000.
# Everything below is therefore PHYSICAL, and the KSEG aliasing is free.
ENTRY = 0xBC000000               # TEXT_BASE, virtual
FLASH_PHYS = 0x1C000000          # SPI NOR window
FLASH_SIZE = 0x00400000
BOOT_PHYS = 0x1FC00000           # MIPS reset vector mirror
RAM_PHYS = 0x00000000
RAM_SIZE = 0x08000000            # HC5761: 128 MiB DDR2

SYSCTL = 0x10000000              # RALINK_SYSCTL_BASE 0xB0000000 -> physical
MMIO_REGIONS = [(0x10000000, 0x00200000)]

UART = SYSCTL + 0x0C00           # UART Lite = console (CFG_RT2880_CONSOLE)
UART_RBR = UART + 0x00
UART_TBR = UART + 0x04
UART_LSR = UART + 0x1C
LSR_TEMT = 1 << 6
LSR_THRE = 1 << 5

COUNT_REG = SYSCTL + 0x0D08           # RALINK_COUNT, free running


class Soc:
    def __init__(self, default_read, verbose_mmio):
        self.console = bytearray()
        self.reads = collections.Counter()
        self.writes = collections.Counter()
        self.log = []
        self.ticks = 0
        self.default_read = default_read
        self.verbose = verbose_mmio

    def read(self, uc, offset, size, base):
        addr = base + offset
        self.reads[addr] += 1
        self.ticks += 1
        if addr == UART_LSR:
            return LSR_TEMT | LSR_THRE
        if addr == UART_RBR:
            return 0
        if addr == COUNT_REG:
            return self.ticks * 1000
        if self.verbose and self.reads[addr] <= 2:
            self.log.append("R 0x%08X" % addr)
        return self.default_read

    def write(self, uc, offset, size, value, base):
        addr = base + offset
        self.writes[addr] += 1
        if addr == UART_TBR:
            self.console.append(value & 0xFF)
            return
        if self.verbose and self.writes[addr] <= 2:
            self.log.append("W 0x%08X = 0x%08X" % (addr, value))


def load_symbols(path):
    syms = []
    if not path:
        return syms
    try:
        with open(path) as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 3 and parts[1] not in ("A",):
                    syms.append((int(parts[0], 16), parts[2]))
    except OSError:
        return []
    syms.sort()
    return syms


def symbolize(syms, addr):
    if not syms:
        return ""
    lo, hi = 0, len(syms) - 1
    best = None
    while lo <= hi:
        mid = (lo + hi) // 2
        if syms[mid][0] <= addr:
            best = syms[mid]
            lo = mid + 1
        else:
            hi = mid - 1
    if best is None:
        return ""
    delta = addr - best[0]
    if delta > 0x4000:
        return ""
    return "%s+0x%x" % (best[1], delta) if delta else best[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--symbols")
    ap.add_argument("--max-insn", type=int, default=80_000_000)
    ap.add_argument("--default-read", default="0xFFFFFFFF")
    ap.add_argument("--verbose-mmio", action="store_true")
    ap.add_argument("--stall-chunks", type=int, default=50,
                    help="stop after this many chunks with an unchanged PC; a "
                         "tight loop can land on the same PC at a chunk "
                         "boundary while still making progress")
    ap.add_argument("--step", type=int, default=0,
                    help="run in chunks of N instructions, flushing progress "
                         "so a native unicorn crash still shows how far it got")
    args = ap.parse_args()

    image = open(args.image, "rb").read()
    syms = load_symbols(args.symbols)
    soc = Soc(int(args.default_read, 0), args.verbose_mmio)

    uc = Uc(UC_ARCH_MIPS, UC_MODE_MIPS32 | UC_MODE_LITTLE_ENDIAN)

    flash = ctypes.create_string_buffer(FLASH_SIZE)
    ctypes.memmove(flash, image, len(image))
    # A memory-mapped SPI NOR window silently drops writes rather than
    # trapping, so map it writable and just count the writes instead. Writes
    # here mean code touching .data before relocate_code has moved it.
    uc.mem_map_ptr(FLASH_PHYS, FLASH_SIZE, UC_PROT_ALL, flash)
    uc.mem_map_ptr(BOOT_PHYS, FLASH_SIZE, UC_PROT_ALL, flash)

    # Real DRAM aliases once past its size, which is how get_ram_size() probes
    # capacity. Map the same buffer twice so the wraparound is genuine and the
    # detected size comes out right instead of running off the end.
    ram = ctypes.create_string_buffer(RAM_SIZE)
    uc.mem_map_ptr(RAM_PHYS, RAM_SIZE, UC_PROT_ALL, ram)
    uc.mem_map_ptr(RAM_PHYS + RAM_SIZE, RAM_SIZE, UC_PROT_ALL, ram)

    for base, size in MMIO_REGIONS:
        uc.mmio_map(
            base, size,
            # unicorn passes user_data as a 4th/5th positional arg; swallow it
            # with `ud` so the closed-over base is not overwritten.
            lambda uc_, off, sz, ud, b=base: soc.read(uc_, off, sz, b),
            None,
            lambda uc_, off, sz, val, ud, b=base: soc.write(uc_, off, sz, val, b),
            None,
        )

    # The relocated image lives around RELOC_BASE; anything executing outside
    # the flash window or that RAM window has jumped somewhere it should not.
    FLASH_WINDOW = 0xBC000000
    RELOC_LO, RELOC_HI = 0x87F00000, 0x88000000
    escape = {"prev": None, "at": None, "from": None}

    def sane(addr):
        in_flash = FLASH_WINDOW <= addr <= FLASH_WINDOW + 0x40000
        in_reloc = RELOC_LO <= addr < RELOC_HI
        return in_flash or in_reloc

    blocks = collections.Counter()
    recent = collections.deque(maxlen=64)
    state = {"insn": 0, "last_pc": ENTRY}

    def on_block(uc_, address, size, _):
        if escape["at"] is None:
            if sane(address):
                escape["prev"] = address
            else:
                escape["at"] = address
                escape["from"] = escape["prev"]
                prev = escape["prev"] or 0
                print("  [ESCAPE] last sane block 0x%08X %s"
                      % (prev, symbolize(syms, prev)), flush=True)
                print("  [ESCAPE] jumped to      0x%08X (not valid code)"
                      % address, flush=True)
        blocks[address] += 1
        recent.append(address)
        state["last_pc"] = address
        state["insn"] += max(size // 4, 1)
        if state["insn"] > args.max_insn:
            uc_.emu_stop()

    uc.hook_add(UC_HOOK_BLOCK, on_block)

    flash_writes = collections.Counter()

    def on_flash_write(uc_, access, address, size, value, _):
        flash_writes[uc_.reg_read(UC_MIPS_REG_PC)] += 1

    uc.hook_add(UC_HOOK_MEM_WRITE, on_flash_write,
                begin=FLASH_PHYS, end=FLASH_PHYS + FLASH_SIZE - 1)

    faults = []

    def on_fault(uc_, access, address, size, value, _):
        pc = uc_.reg_read(UC_MIPS_REG_PC)
        faults.append((access, address, pc))
        # Do not map from inside the callback: unicorn crashes natively if the
        # new region collides. Stop instead and report, since a wild access is
        # itself the interesting result.
        return False

    uc.hook_add(
        UC_HOOK_MEM_READ_UNMAPPED | UC_HOOK_MEM_WRITE_UNMAPPED
        | UC_HOOK_MEM_FETCH_UNMAPPED, on_fault)

    err = None
    if args.step:
        pc = ENTRY
        done = 0
        shown = 0
        stall = 0
        try:
            while done < args.max_insn:
                uc.emu_start(pc, 0, count=args.step)
                new_pc = uc.reg_read(UC_MIPS_REG_PC)
                done += args.step
                if len(soc.console) > shown:
                    text = soc.console[shown:].decode("utf-8", "replace")
                    shown = len(soc.console)
                    for chunk_line in text.splitlines():
                        print("  [console] " + chunk_line, flush=True)
                print("  [step] insn~%-10d pc=0x%08X %s" %
                      (done, new_pc, symbolize(syms, new_pc)), flush=True)
                stall = stall + 1 if new_pc == pc else 0
                if stall >= args.stall_chunks:
                    print("  [step] pc not advancing; stopping", flush=True)
                    break
                pc = new_pc
        except UcError as exc:
            err = exc
    else:
        try:
            uc.emu_start(ENTRY, 0, count=0)
        except UcError as exc:
            err = exc

    pc = uc.reg_read(UC_MIPS_REG_PC)
    print("=== %s ===" % args.image)
    print("stopped at PC   : 0x%08X  %s" % (pc, symbolize(syms, pc)))
    print("last block      : 0x%08X  %s"
          % (state["last_pc"], symbolize(syms, state["last_pc"])))
    print("blocks executed : %d unique, ~%d instructions"
          % (len(blocks), state["insn"]))
    if err:
        print("unicorn error   : %s" % err)
    if faults:
        acc, addr, fpc = faults[0]
        print("first fault     : access=%d addr=0x%08X pc=0x%08X %s"
              % (acc, addr, fpc, symbolize(syms, fpc)))
        print("total faults    : %d" % len(faults))

    if escape["at"] is not None:
        print("escaped         : yes -- jumped out of valid code")
    else:
        print("escaped         : no")

    print("\n--- console output (%d bytes) ---" % len(soc.console))
    print(soc.console.decode("utf-8", "replace"))

    print("--- hottest blocks ---")
    for addr, n in blocks.most_common(8):
        print("  0x%08X  %-28s %d" % (addr, symbolize(syms, addr), n))

    loop = sorted(set(recent))
    if loop and (max(loop) - min(loop)) < 0x400:
        print("\n--- spinning in 0x%08X-0x%08X ---" % (min(loop), max(loop)))
        for addr in loop:
            print("  0x%08X  %s" % (addr, symbolize(syms, addr)))

    if flash_writes:
        print("--- writes into the flash window (dropped on hardware) ---")
        for addr, n in flash_writes.most_common(6):
            print("  from pc 0x%08X  %-26s %d" % (addr, symbolize(syms, addr), n))
    print("--- most-read MMIO ---")
    for addr, n in soc.reads.most_common(8):
        print("  0x%08X  %d" % (addr, n))
    if soc.log:
        print("--- first MMIO touches ---")
        for line in soc.log[:40]:
            print("  " + line)


if __name__ == "__main__":
    sys.exit(main())
