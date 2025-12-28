#!/usr/bin/env python3
"""Convert binary PRAM file to hex format for Verilog $readmemh"""

import sys

def convert_pram(input_file, output_file):
    """Convert binary PRAM to hex format (one byte per line)"""
    with open(input_file, 'rb') as f:
        data = f.read()
    
    if len(data) != 256:
        print(f"Warning: PRAM file is {len(data)} bytes, expected 256")
    
    with open(output_file, 'w') as f:
        for byte in data:
            f.write(f"{byte:02x}\n")
    
    print(f"Converted {len(data)} bytes from {input_file} to {output_file}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: convert_pram.py <input.pram> <output.hex>")
        sys.exit(1)
    
    convert_pram(sys.argv[1], sys.argv[2])
