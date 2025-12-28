#!/usr/bin/env python3
"""
Generate SystemVerilog testbench stimulus from MAME Mac LC boot logs.

This script parses the handshake.log file and generates exact signal 
transitions that can be used in a testbench.
"""

import re
import sys

def parse_mame_log(filename):
    """Parse MAME log file and extract Egret signal transitions."""
    
    transitions = []
    
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            
            # Parse XCVR_SESSION changes
            match = re.search(r'XCVR_SESSION:\s+(\d+)\s+\(PC=([0-9a-fA-F]+)\)', line)
            if match:
                value = int(match.group(1))
                pc = match.group(2)
                transitions.append({
                    'type': 'xcvr',
                    'value': value,
                    'pc': pc
                })
            
            # Parse VIA_DATA and VIA_CLOCK changes
            match = re.search(r'VIA_DATA:\s+(\d+)\s+VIA_CLOCK:\s+(\d+)\s+\(PC=([0-9a-fA-F]+)\)', line)
            if match:
                data = int(match.group(1))
                clock = int(match.group(2))
                pc = match.group(3)
                transitions.append({
                    'type': 'via',
                    'data': data,
                    'clock': clock,
                    'pc': pc
                })
    
    return transitions

def generate_sv_sequence(transitions, max_transitions=200):
    """Generate SystemVerilog code for the signal sequence."""
    
    print("// Generated signal sequence from MAME logs")
    print("// Total transitions:", len(transitions))
    print()
    
    delay_ns = 476  # Approximate Egret clock half-period (2.097 MHz)
    
    for i, trans in enumerate(transitions[:max_transitions]):
        if trans['type'] == 'xcvr':
            print(f"// Transition {i}: XCVR_SESSION (PC=0x{trans['pc']})")
            print(f"@(posedge clk_2mhz);")
            print(f"egret_xcvr_session = {trans['value']};")
            print(f"#{delay_ns};")
            print()
            
        elif trans['type'] == 'via':
            print(f"// Transition {i}: VIA signals (PC=0x{trans['pc']})")
            print(f"@(posedge clk_2mhz);")
            print(f"egret_via_data = {trans['data']};")
            print(f"egret_via_clock = {trans['clock']};")
            print(f"#{delay_ns};")
            print()

def analyze_patterns(transitions):
    """Analyze the transitions to find patterns."""
    
    print("=== Pattern Analysis ===\n")
    
    # Find clock toggle sequences
    clock_toggles = []
    for i, trans in enumerate(transitions):
        if trans['type'] == 'via':
            clock_toggles.append(trans['clock'])
    
    # Find sequences of clock pulses (1->0 transitions)
    sequences = []
    current_seq = []
    
    for i in range(len(clock_toggles) - 1):
        if clock_toggles[i] == 1 and clock_toggles[i+1] == 0:
            current_seq.append(i)
        elif current_seq and len(current_seq) > 0:
            if len(current_seq) >= 8:
                sequences.append(current_seq)
            current_seq = []
    
    print(f"Found {len(sequences)} byte transmission sequences")
    for i, seq in enumerate(sequences[:5]):  # Show first 5
        print(f"  Sequence {i+1}: {len(seq)} clock pulses")
    
    print()
    
    # Find XCVR_SESSION patterns
    xcvr_changes = []
    for trans in transitions:
        if trans['type'] == 'xcvr':
            xcvr_changes.append(trans['value'])
    
    print(f"XCVR_SESSION changes: {len(xcvr_changes)} times")
    print(f"  Pattern: {' -> '.join(map(str, xcvr_changes[:10]))}")
    
    print()

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 generate_testbench.py handshake.log")
        sys.exit(1)
    
    log_file = sys.argv[1]
    
    print(f"Parsing {log_file}...")
    transitions = parse_mame_log(log_file)
    
    print(f"Extracted {len(transitions)} transitions\n")
    
    # Analyze patterns
    analyze_patterns(transitions)
    
    # Generate SystemVerilog sequence
    print("\n=== SystemVerilog Test Sequence ===\n")
    generate_sv_sequence(transitions)

if __name__ == '__main__':
    main()
