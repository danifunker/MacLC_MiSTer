#!/usr/bin/env python3
"""
Simple 68HC05 disassembler for Egret ROM
Plain hex format (one byte per line)
"""

# 68HC05 instruction set
OPCODES = {
    0x20: ("bra", None, "rel"),
    0x21: ("brn", None, "rel"),
    0x22: ("bhi", None, "rel"),
    0x23: ("bls", None, "rel"),
    0x24: ("bcc", None, "rel"),
    0x25: ("bcs", None, "rel"),
    0x26: ("bne", None, "rel"),
    0x27: ("beq", None, "rel"),
    0x28: ("bhcc", None, "rel"),
    0x29: ("bhcs", None, "rel"),
    0x2A: ("bpl", None, "rel"),
    0x2B: ("bmi", None, "rel"),
    0x2C: ("bmc", None, "rel"),
    0x2D: ("bms", None, "rel"),
    0x2E: ("bil", None, "rel"),
    0x2F: ("bih", None, "rel"),
    
    0x00: ("brset", 0, "bit_rel"),
    0x01: ("brclr", 0, "bit_rel"),
    0x02: ("brset", 1, "bit_rel"),
    0x03: ("brclr", 1, "bit_rel"),
    0x04: ("brset", 2, "bit_rel"),
    0x05: ("brclr", 2, "bit_rel"),
    0x06: ("brset", 3, "bit_rel"),
    0x07: ("brclr", 3, "bit_rel"),
    0x08: ("brset", 4, "bit_rel"),
    0x09: ("brclr", 4, "bit_rel"),
    0x0A: ("brset", 5, "bit_rel"),
    0x0B: ("brclr", 5, "bit_rel"),
    0x0C: ("brset", 6, "bit_rel"),
    0x0D: ("brclr", 6, "bit_rel"),
    0x0E: ("brset", 7, "bit_rel"),
    0x0F: ("brclr", 7, "bit_rel"),
    
    0x10: ("bset", 0, "direct"),
    0x11: ("bclr", 0, "direct"),
    0x12: ("bset", 1, "direct"),
    0x13: ("bclr", 1, "direct"),
    0x14: ("bset", 2, "direct"),
    0x15: ("bclr", 2, "direct"),
    0x16: ("bset", 3, "direct"),
    0x17: ("bclr", 3, "direct"),
    0x18: ("bset", 4, "direct"),
    0x19: ("bclr", 4, "direct"),
    0x1A: ("bset", 5, "direct"),
    0x1B: ("bclr", 5, "direct"),
    0x1C: ("bset", 6, "direct"),
    0x1D: ("bclr", 6, "direct"),
    0x1E: ("bset", 7, "direct"),
    0x1F: ("bclr", 7, "direct"),
    
    0x3A: ("dec", None, "direct"),
    0x3C: ("inc", None, "direct"),
    0x3D: ("tst", None, "direct"),
    0x3F: ("clr", None, "direct"),
    
    0x4A: ("deca", None, "impl"),
    0x4C: ("inca", None, "impl"),
    0x4D: ("tsta", None, "impl"),
    0x4F: ("clra", None, "impl"),
    
    0x5A: ("decx", None, "impl"),
    0x5C: ("incx", None, "impl"),
    0x5D: ("tstx", None, "impl"),
    0x5F: ("clrx", None, "impl"),
    
    0x80: ("rti", None, "impl"),
    0x81: ("rts", None, "impl"),
    0x83: ("swi", None, "impl"),
    
    0x97: ("tax", None, "impl"),
    0x98: ("clc", None, "impl"),
    0x99: ("sec", None, "impl"),
    0x9A: ("cli", None, "impl"),
    0x9B: ("sei", None, "impl"),
    0x9C: ("rsp", None, "impl"),
    0x9D: ("nop", None, "impl"),
    0x9F: ("txa", None, "impl"),
    
    0xA0: ("suba", None, "imm"),
    0xA1: ("cmpa", None, "imm"),
    0xA2: ("sbca", None, "imm"),
    0xA3: ("cpx", None, "imm"),
    0xA4: ("anda", None, "imm"),
    0xA5: ("bita", None, "imm"),
    0xA6: ("lda", None, "imm"),
    0xA8: ("eora", None, "imm"),
    0xA9: ("adca", None, "imm"),
    0xAA: ("ora", None, "imm"),
    0xAB: ("adda", None, "imm"),
    0xAD: ("bsr", None, "rel"),
    0xAE: ("ldx", None, "imm"),
    
    0xB0: ("suba", None, "direct"),
    0xB1: ("cmpa", None, "direct"),
    0xB2: ("sbca", None, "direct"),
    0xB3: ("cpx", None, "direct"),
    0xB4: ("anda", None, "direct"),
    0xB5: ("bita", None, "direct"),
    0xB6: ("lda", None, "direct"),
    0xB7: ("sta", None, "direct"),
    0xB8: ("eora", None, "direct"),
    0xB9: ("adca", None, "direct"),
    0xBA: ("ora", None, "direct"),
    0xBB: ("adda", None, "direct"),
    0xBC: ("jmp", None, "direct"),
    0xBD: ("jsr", None, "direct"),
    0xBE: ("ldx", None, "direct"),
    0xBF: ("stx", None, "direct"),
    
    0xC0: ("suba", None, "ext"),
    0xC1: ("cmpa", None, "ext"),
    0xC2: ("sbca", None, "ext"),
    0xC3: ("cpx", None, "ext"),
    0xC4: ("anda", None, "ext"),
    0xC5: ("bita", None, "ext"),
    0xC6: ("lda", None, "ext"),
    0xC7: ("sta", None, "ext"),
    0xC8: ("eora", None, "ext"),
    0xC9: ("adca", None, "ext"),
    0xCA: ("ora", None, "ext"),
    0xCB: ("adda", None, "ext"),
    0xCC: ("jmp", None, "ext"),
    0xCD: ("jsr", None, "ext"),
    0xCE: ("ldx", None, "ext"),
    0xCF: ("stx", None, "ext"),
    
    0xD6: ("lda", None, "idx1"),
    0xD7: ("sta", None, "idx1"),
    
    0xE6: ("lda", None, "idx"),
    0xE7: ("sta", None, "idx"),
    
    0xF1: ("cmpa", None, "idx2"),
    0xF3: ("cpx", None, "idx2"),
    0xF6: ("lda", None, "idx2"),
    0xF7: ("sta", None, "idx2"),
    0xF9: ("adca", None, "idx2"),
    0xFB: ("adda", None, "idx2"),
    0xFC: ("jmp", None, "idx2"),
    0xFD: ("jsr", None, "idx2"),
    0xFE: ("ldx", None, "idx2"),
    0xFF: ("stx", None, "idx2"),
}

def read_plain_hex(filename):
    """Read plain hex file (one byte per line)"""
    data = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    data.append(int(line, 16))
                except ValueError:
                    pass  # Skip invalid lines
    return bytearray(data)

def disassemble_instr(rom, pc):
    """Disassemble one instruction"""
    if pc >= len(rom):
        return "???", 1
        
    opcode = rom[pc]
    
    if opcode not in OPCODES:
        return f"db      ${opcode:02x}", 1
    
    mnem, bit, mode = OPCODES[opcode]
    
    if mode == "impl":
        return mnem, 1
    elif mode == "imm":
        if pc + 1 >= len(rom):
            return f"db ${opcode:02x}", 1
        operand = rom[pc + 1]
        return f"{mnem}    #${operand:02x}", 2
    elif mode == "direct":
        if pc + 1 >= len(rom):
            return f"db ${opcode:02x}", 1
        operand = rom[pc + 1]
        if bit is not None:
            return f"{mnem}    {bit},${operand:02x}", 2
        return f"{mnem}    ${operand:02x}", 2
    elif mode == "ext":
        if pc + 2 >= len(rom):
            return f"db ${opcode:02x}", 1
        addr = (rom[pc + 1] << 8) | rom[pc + 2]
        return f"{mnem}    ${addr:04x}", 3
    elif mode == "rel":
        if pc + 1 >= len(rom):
            return f"db ${opcode:02x}", 1
        offset = rom[pc + 1]
        if offset >= 128:
            offset = offset - 256
        target = (pc + 2 + offset) & 0xFFFF
        return f"{mnem}    ${target:04x}", 2
    elif mode == "bit_rel":
        if pc + 2 >= len(rom):
            return f"db ${opcode:02x}", 1
        direct = rom[pc + 1]
        offset = rom[pc + 2]
        if offset >= 128:
            offset = offset - 256
        target = (pc + 3 + offset) & 0xFFFF
        return f"{mnem}    {bit},${direct:02x},${target:04x}", 3
    elif mode == "idx":
        if pc + 1 >= len(rom):
            return f"db ${opcode:02x}", 1
        offset = rom[pc + 1]
        return f"{mnem}    ${offset:02x},x", 2
    elif mode == "idx1":
        return f"{mnem}    ,x", 1
    elif mode == "idx2":
        if pc + 1 >= len(rom):
            return f"db ${opcode:02x}", 1
        offset = rom[pc + 1]
        return f"{mnem}    ${offset:02x},x", 2
    
    return "???", 1

def disassemble_range(rom, start, count=20):
    """Disassemble count instructions from start"""
    pc = start
    for _ in range(count):
        if pc >= len(rom):
            break
        instr, size = disassemble_instr(rom, pc)
        data_bytes = " ".join(f"{rom[pc+i]:02x}" for i in range(min(size, len(rom)-pc)))
        print(f"{pc:04x}  {data_bytes:12s}  {instr}")
        pc += size

if __name__ == "__main__":
    rom = read_plain_hex("egret_rom.hex")
    
    print(f"ROM size: {len(rom)} bytes")
    print(f"Reset vector: 0x{(rom[0xFFE] << 8) | rom[0xFFF]:04x}\n")
    
    print("=== Stuck address range 0x0f5b-0x0f65 ===")
    disassemble_range(rom, 0x0f5b, 20)
    
    print("\n=== Reset vector handler at 0x0f71 ===")
    disassemble_range(rom, 0x0f71, 15)