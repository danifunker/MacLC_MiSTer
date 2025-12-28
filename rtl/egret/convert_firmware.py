#!/usr/bin/env python3
# Convert Egret ROM binary to hex format for Verilog $readmemh

with open('341s0851.bin', 'rb') as f:
    data = f.read()

# Skip the first 256 bytes (header) if present
# The ROM files are 4352 bytes (0x1100), where first 0x100 is header
if len(data) == 0x1100:
    data = data[0x100:]  # Skip header, keep 4KB ROM
elif len(data) != 0x1000:
    print(f"Warning: Unexpected file size: {len(data)} bytes")

with open('egret_rom.hex', 'w') as f:
    for byte in data:
        f.write(f'{byte:02x}\n')

print(f"Converted {len(data)} bytes to egret_rom.hex")
