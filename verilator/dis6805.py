#!/usr/bin/env python3
"""Simple 68HC05 disassembler for Egret ROM"""

import sys

# 68HC05 opcode table (simplified)
opcodes = {
    0x00: ("brset", "0,d,r"),   0x01: ("brclr", "0,d,r"),
    0x02: ("brset", "1,d,r"),   0x03: ("brclr", "1,d,r"),
    0x04: ("brset", "2,d,r"),   0x05: ("brclr", "2,d,r"),
    0x06: ("brset", "3,d,r"),   0x07: ("brclr", "3,d,r"),
    0x08: ("brset", "4,d,r"),   0x09: ("brclr", "4,d,r"),
    0x0a: ("brset", "5,d,r"),   0x0b: ("brclr", "5,d,r"),
    0x0c: ("brset", "6,d,r"),   0x0d: ("brclr", "6,d,r"),
    0x0e: ("brset", "7,d,r"),   0x0f: ("brclr", "7,d,r"),
    0x10: ("bset", "0,d"),      0x11: ("bclr", "0,d"),
    0x12: ("bset", "1,d"),      0x13: ("bclr", "1,d"),
    0x14: ("bset", "2,d"),      0x15: ("bclr", "2,d"),
    0x16: ("bset", "3,d"),      0x17: ("bclr", "3,d"),
    0x18: ("bset", "4,d"),      0x19: ("bclr", "4,d"),
    0x1a: ("bset", "5,d"),      0x1b: ("bclr", "5,d"),
    0x1c: ("bset", "6,d"),      0x1d: ("bclr", "6,d"),
    0x1e: ("bset", "7,d"),      0x1f: ("bclr", "7,d"),
    0x20: ("bra", "r"),         0x21: ("brn", "r"),
    0x22: ("bhi", "r"),         0x23: ("bls", "r"),
    0x24: ("bcc", "r"),         0x25: ("bcs", "r"),
    0x26: ("bne", "r"),         0x27: ("beq", "r"),
    0x28: ("bhcc", "r"),        0x29: ("bhcs", "r"),
    0x2a: ("bpl", "r"),         0x2b: ("bmi", "r"),
    0x2c: ("bmc", "r"),         0x2d: ("bms", "r"),
    0x2e: ("bil", "r"),         0x2f: ("bih", "r"),
    0x30: ("neg", "d"),         0x33: ("com", "d"),
    0x34: ("lsr", "d"),         0x36: ("ror", "d"),
    0x37: ("asr", "d"),         0x38: ("lsl", "d"),
    0x39: ("rol", "d"),         0x3a: ("dec", "d"),
    0x3c: ("inc", "d"),         0x3d: ("tst", "d"),
    0x3f: ("clr", "d"),
    0x40: ("nega", ""),         0x42: ("mul", ""),
    0x43: ("coma", ""),         0x44: ("lsra", ""),
    0x46: ("rora", ""),         0x47: ("asra", ""),
    0x48: ("lsla", ""),         0x49: ("rola", ""),
    0x4a: ("deca", ""),         0x4c: ("inca", ""),
    0x4d: ("tsta", ""),         0x4f: ("clra", ""),
    0x50: ("negx", ""),         0x53: ("comx", ""),
    0x54: ("lsrx", ""),         0x56: ("rorx", ""),
    0x57: ("asrx", ""),         0x58: ("lslx", ""),
    0x59: ("rolx", ""),         0x5a: ("decx", ""),
    0x5c: ("incx", ""),         0x5d: ("tstx", ""),
    0x5f: ("clrx", ""),
    0x60: ("neg", "x1"),        0x63: ("com", "x1"),
    0x64: ("lsr", "x1"),        0x66: ("ror", "x1"),
    0x67: ("asr", "x1"),        0x68: ("lsl", "x1"),
    0x69: ("rol", "x1"),        0x6a: ("dec", "x1"),
    0x6c: ("inc", "x1"),        0x6d: ("tst", "x1"),
    0x6f: ("clr", "x1"),
    0x70: ("neg", "x"),         0x73: ("com", "x"),
    0x74: ("lsr", "x"),         0x76: ("ror", "x"),
    0x77: ("asr", "x"),         0x78: ("lsl", "x"),
    0x79: ("rol", "x"),         0x7a: ("dec", "x"),
    0x7c: ("inc", "x"),         0x7d: ("tst", "x"),
    0x7f: ("clr", "x"),
    0x80: ("rti", ""),          0x81: ("rts", ""),
    0x83: ("swi", ""),          0x8e: ("stop", ""),
    0x8f: ("wait", ""),
    0x97: ("tax", ""),          0x98: ("clc", ""),
    0x99: ("sec", ""),          0x9a: ("cli", ""),
    0x9b: ("sei", ""),          0x9c: ("rsp", ""),
    0x9d: ("nop", ""),          0x9f: ("txa", ""),
    0xa0: ("sub", "#i"),        0xa1: ("cmp", "#i"),
    0xa2: ("sbc", "#i"),        0xa3: ("cpx", "#i"),
    0xa4: ("and", "#i"),        0xa5: ("bit", "#i"),
    0xa6: ("lda", "#i"),        0xa7: ("sta", "#i"),
    0xa8: ("eor", "#i"),        0xa9: ("adc", "#i"),
    0xaa: ("ora", "#i"),        0xab: ("add", "#i"),
    0xad: ("bsr", "r"),         0xae: ("ldx", "#i"),
    0xaf: ("stx", "#i"),
    0xb0: ("sub", "d"),         0xb1: ("cmp", "d"),
    0xb2: ("sbc", "d"),         0xb3: ("cpx", "d"),
    0xb4: ("and", "d"),         0xb5: ("bit", "d"),
    0xb6: ("lda", "d"),         0xb7: ("sta", "d"),
    0xb8: ("eor", "d"),         0xb9: ("adc", "d"),
    0xba: ("ora", "d"),         0xbb: ("add", "d"),
    0xbc: ("jmp", "d"),         0xbd: ("jsr", "d"),
    0xbe: ("ldx", "d"),         0xbf: ("stx", "d"),
    0xc0: ("sub", "e"),         0xc1: ("cmp", "e"),
    0xc2: ("sbc", "e"),         0xc3: ("cpx", "e"),
    0xc4: ("and", "e"),         0xc5: ("bit", "e"),
    0xc6: ("lda", "e"),         0xc7: ("sta", "e"),
    0xc8: ("eor", "e"),         0xc9: ("adc", "e"),
    0xca: ("ora", "e"),         0xcb: ("add", "e"),
    0xcc: ("jmp", "e"),         0xcd: ("jsr", "e"),
    0xce: ("ldx", "e"),         0xcf: ("stx", "e"),
    0xd0: ("sub", "x2"),        0xd1: ("cmp", "x2"),
    0xd2: ("sbc", "x2"),        0xd3: ("cpx", "x2"),
    0xd4: ("and", "x2"),        0xd5: ("bit", "x2"),
    0xd6: ("lda", "x2"),        0xd7: ("sta", "x2"),
    0xd8: ("eor", "x2"),        0xd9: ("adc", "x2"),
    0xda: ("ora", "x2"),        0xdb: ("add", "x2"),
    0xdc: ("jmp", "x2"),        0xdd: ("jsr", "x2"),
    0xde: ("ldx", "x2"),        0xdf: ("stx", "x2"),
    0xe0: ("sub", "x1"),        0xe1: ("cmp", "x1"),
    0xe2: ("sbc", "x1"),        0xe3: ("cpx", "x1"),
    0xe4: ("and", "x1"),        0xe5: ("bit", "x1"),
    0xe6: ("lda", "x1"),        0xe7: ("sta", "x1"),
    0xe8: ("eor", "x1"),        0xe9: ("adc", "x1"),
    0xea: ("ora", "x1"),        0xeb: ("add", "x1"),
    0xec: ("jmp", "x1"),        0xed: ("jsr", "x1"),
    0xee: ("ldx", "x1"),        0xef: ("stx", "x1"),
    0xf0: ("sub", "x"),         0xf1: ("cmp", "x"),
    0xf2: ("sbc", "x"),         0xf3: ("cpx", "x"),
    0xf4: ("and", "x"),         0xf5: ("bit", "x"),
    0xf6: ("lda", "x"),         0xf7: ("sta", "x"),
    0xf8: ("eor", "x"),         0xf9: ("adc", "x"),
    0xfa: ("ora", "x"),         0xfb: ("add", "x"),
    0xfc: ("jmp", "x"),         0xfd: ("jsr", "x"),
    0xfe: ("ldx", "x"),         0xff: ("stx", "x"),
}

def disassemble(rom, addr, base=0x0F00):
    """Disassemble one instruction at addr"""
    offset = addr - base
    if offset < 0 or offset >= len(rom):
        return None, 1

    op = rom[offset]
    if op not in opcodes:
        return f"db    ${op:02x}", 1

    mnem, mode = opcodes[op]

    if mode == "":
        return mnem, 1
    elif mode == "d":
        if offset + 1 >= len(rom):
            return f"{mnem}  ???", 2
        d = rom[offset + 1]
        return f"{mnem}  ${d:02x}", 2
    elif mode == "e":
        if offset + 2 >= len(rom):
            return f"{mnem}  ???", 3
        hi = rom[offset + 1]
        lo = rom[offset + 2]
        return f"{mnem}  ${hi:02x}{lo:02x}", 3
    elif mode == "r":
        if offset + 1 >= len(rom):
            return f"{mnem}  ???", 2
        rel = rom[offset + 1]
        if rel > 127:
            rel -= 256
        target = addr + 2 + rel
        return f"{mnem}  ${target:04x}", 2
    elif mode == "#i":
        if offset + 1 >= len(rom):
            return f"{mnem}  #???", 2
        imm = rom[offset + 1]
        return f"{mnem}  #${imm:02x}", 2
    elif mode == "x":
        return f"{mnem}  ,x", 1
    elif mode == "x1":
        if offset + 1 >= len(rom):
            return f"{mnem}  ???,x", 2
        d = rom[offset + 1]
        return f"{mnem}  ${d:02x},x", 2
    elif mode == "x2":
        if offset + 2 >= len(rom):
            return f"{mnem}  ???,x", 3
        hi = rom[offset + 1]
        lo = rom[offset + 2]
        return f"{mnem}  ${hi:02x}{lo:02x},x", 3
    elif "," in mode:
        # Bit test/set modes
        parts = mode.split(",")
        bit = parts[0]
        if "d" in parts[1]:
            if offset + 1 >= len(rom):
                return f"{mnem}  {bit}, ???", 2
            d = rom[offset + 1]
            if len(parts) > 2:  # brset/brclr with relative
                if offset + 2 >= len(rom):
                    return f"{mnem}  {bit}, ${d:02x}, ???", 3
                rel = rom[offset + 2]
                if rel > 127:
                    rel -= 256
                target = addr + 3 + rel
                return f"{mnem}  {bit}, ${d:02x}, ${target:04x}", 3
            return f"{mnem}  {bit}, ${d:02x}", 2

    return f"db    ${op:02x}", 1

def main():
    if len(sys.argv) < 2:
        print("Usage: dis6805.py <rom.bin> [start_addr] [count]")
        sys.exit(1)

    with open(sys.argv[1], 'rb') as f:
        rom = f.read()

    base = 0x0F00
    start = int(sys.argv[2], 16) if len(sys.argv) > 2 else base
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 50

    addr = start
    for _ in range(count):
        if addr - base >= len(rom):
            break
        dis, size = disassemble(rom, addr, base)
        if dis:
            print(f"{addr:04X}: {dis}")
        addr += size

if __name__ == "__main__":
    main()
