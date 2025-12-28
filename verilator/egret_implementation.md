# Egret Implementation Progress & Debug Plan

## Overview

Mac LC uses **Egret** (not CUDA) as its ADB/PRAM/RTC microcontroller. This document tracks the implementation of the real Egret using the jt6805 68HC05 CPU core and the actual Egret ROM (341s0850).

## Implementation Status

### Completed

| Component | File | Status |
|-----------|------|--------|
| Egret ROM extraction | `rtl/egret_rom.bin`, `rtl/egret_rom.hex` | Done |
| jt6805 CPU core | `rtl/jt6805/*.v` | Copied from Apple II MiSTer |
| Egret module | `rtl/egret.sv` | Created, same interface as cuda_maclc.sv |
| Build integration | `verilator/Makefile` | Added jt6805 files + USE_EGRET_CPU define |
| Switching mechanism | `rtl/dataController_top.sv` | `ifdef USE_EGRET_CPU` added |
| Verilator build | - | Builds successfully |
| Egret-controlled 68000 reset | `rtl/dataController_top.sv` | Egret Port C bit 3 controls 68000 |
| ROM addressing fix | `rtl/egret.sv` | Fixed 12-bit truncation bug |
| VIA_FULL signal | `rtl/egret.sv` | Connected to `via_byteack_in` (VIA PB4 output) |
| CB1 clocking | `rtl/egret.sv`, `rtl/via6522.sv` | Working - bytes transfer |
| Debug logging | `rtl/egret.sv`, `rtl/dataController_top.sv` | 68000 VIA writes + Egret state |

### Current Behavior (as of 2024-12-27)

- Egret CPU executes from ROM correctly
- Reset vector at 0x1FFE correctly points to 0x0F71 (startup code)
- Egret controls 68000 reset via Port C bit 3
- 68000 released from reset at ~cycle 57M (after Egret sets Port C bit 3)
- Egret reaches main loop at 0x1047
- VIA_FULL correctly tracks VIA PB4 output (via_byteack_in)
- **Current issue**: At 0x12C2, TIP check fails (TIP=0), causing branch to 0x132B abort path

## Key Fixes Made

### 1. Egret-Controlled 68000 Reset
The real Egret controls the 68000 reset via Port C bit 3. Added wiring in `dataController_top.sv`:
```systemverilog
// Egret starts BEFORE 68000
reg [9:0] egretBootCounter = 0;
wire egretReset = (egretBootCounter < 10'd256);

// 68000 reset controlled by Egret Port C bit 3
`ifdef USE_EGRET_CPU
    assign _cpuReset = (minResetPassed && !egret_reset_680x0) ? 1'b1 : 1'b0;
`endif
```

### 2. VIA_FULL Signal Fix (Updated 2024-12-27)
VIA_FULL (Port B bit 2) now correctly uses `via_byteack_in` to match MAME behavior:
```systemverilog
// VIA_FULL: Directly from VIA Port B bit 4 output (via_byteack_in)
// In MAME, this comes from VIA PB4 writes by the 68000, not SR hardware status
wire via_full = via_byteack_in;

wire [7:0] pb_in = {
    ...
    via_full,         // Bit 2: VIA_FULL (from VIA PB4)
    ...
};
```

**Why this matters**: In MAME's v8.cpp, via_out_b() sends PB4 to Egret's set_via_full():
```cpp
void v8_device::via_out_b(u8 data) {
    write_pb4(BIT(data, 4));  // -> Egret set_via_full()
    write_pb5(BIT(data, 5));  // -> Egret set_sys_session() (TIP)
}
```

### 3. ROM Addressing Fix
Fixed 12-bit truncation bug in ROM offset calculation:
```systemverilog
wire [12:0] rom_offset = cpu_addr - 13'h0F00;  // Use full 13-bit offset
```

### 4. Debug Logging (Added 2024-12-27)
Added comprehensive debug logging for both Egret and 68000 VIA interactions:
- Egret: VIA_FULL changes, TIP changes, address 0x12C2 checks
- 68000: VIA ORB/DDRB/SR/ACR/IER writes with decoded values

## Memory Map (68HC05)

| Address Range | Size | Description |
|---------------|------|-------------|
| 0x0000-0x000F | 16B | I/O Registers (Ports A, B, C, DDR, Timer) |
| 0x0010-0x010F | 256B | Internal RAM |
| 0x0F00-0x1FFF | 4352B | ROM (Egret firmware 341s0850) |
| 0x1FF8-0x1FFF | 8B | Interrupt vectors |

## Port Mapping (from MAME egret.cpp)

### Port A ($00) - ADB and System Control
| Bit | Dir | Function |
|-----|-----|----------|
| 7 | O | ADB data line out |
| 6 | I | ADB data line in |
| 5 | I | System type (1 = Egret controls power) |
| 4 | O | DFAC latch |
| 3 | O | 680x0 reset pulse |
| 2 | I | Keyboard power switch |
| 1-0 | O | PSU control |

### Port B ($01) - VIA Interface (KEY for debugging)
| Bit | Dir | Function | Our Implementation |
|-----|-----|----------|-------------------|
| 7 | O | DFAC clock (I2C SCL) | Output |
| 6 | I/O | DFAC data (I2C SDA) | Tied high |
| 5 | I/O | CB2 - Shift register data | Connected to VIA CB2 |
| 4 | O | CB1 - Shift register clock | Connected to VIA CB1 |
| 3 | I | TIP from VIA (SYS_SESSION) | Connected to VIA PB5 output |
| 2 | I | VIA_FULL | Connected to `via_byteack_in` (VIA PB4) |
| 1 | O | TREQ to VIA (XCVR_SESSION) | Output to VIA PB3 |
| 0 | I | +5V sense | Tied high |

### Port C ($02) - 68000 Control
| Bit | Dir | Function |
|-----|-----|----------|
| 3 | O | 680x0 reset (active high internally, active low to CPU) |
| 2-0 | O | IPL2-0 |

## Code Flow Analysis

### Startup to Main Loop
1. **0x0F71**: RSP (Reset Stack Pointer)
2. **0x0F72-0x0F81**: Initialize I/O ports
3. **0x0F83-0x0F97**: Clear RAM
4. **0x0FB0**: CLI (enable interrupts)
5. **0x1DE8**: Delay loops (many iterations)
6. **0x12AC-0x12AF**: Check TIP and VIA_FULL - loops until both LOW
7. **0x1034**: Main loop entry

### Main Loop to CB1 Clocking
```
0x1034: Main loop start
0x1047: jsr $1198 (check status)
0x104C: jsr $1ACE (check conditions)
0x104F: bcc $1034 (loop if carry clear)
0x1051: jsr $1138 (more checks)
0x1054: bcs $1059 (continue if carry set)
0x1059: bclr 6, $95
0x105B: jsr $12C2 (VIA communication)
```

### VIA Communication at 0x12C2
```
0x12C2: brclr 3, $01, $132B  ; If TIP=0 (asserted), abort to $132B
0x12C5: clr $B5              ; TIP=1 (idle), continue
0x12C7: jsr $14C8            ; Start CB1 clocking
```

### CB1 Clocking at 0x14EF
```
0x14EF: bclr 4, $01    ; CB1 low
0x14F1: bset 4, $01    ; CB1 high
0x14F3: brset 5, $01   ; Read CB2 (data bit)
... (repeat 8 times)
```

## MAME Trace Analysis

### Key Finding from egret.txt (4.2M lines)
MAME's Egret also loops through 0x12C2 → 0x132B many times before succeeding:
- Lines 347, 397, 447, ... show repeated `12C2: brclr 3, $01, $132B` → `132B: sec`
- First success at line 4480: `12C2: brclr` → `12C5: clr $B5` (TIP was HIGH)

This confirms that Egret polling at 0x12C2 and aborting to 0x132B is **normal behavior** during startup. The 68000 eventually writes to VIA ORB to set TIP high (PB5=1), which allows Egret to proceed.

### Expected Handshake Sequence
1. Egret releases 68000 from reset (Port C bit 3)
2. 68000 boots, initializes VIA
3. 68000 writes to VIA ORB setting PB5=1 (TIP high)
4. Egret's 0x12C2 check passes, proceeds to 0x12C5
5. Egret starts CB1 clocking to transfer data

## Current Issue (2024-12-27)

At 0x12C2, Egret checks TIP (pb_in[3]) and finds it LOW (0), causing branch to abort path 0x132B.

**Debug output shows:**
```
EGRET: *** 0x12C2 brclr 3,$01 - TIP check: pb_in[3]=0 (TIP=0) ***
EGRET: *** 0x132B - brclr jumped here (TIP was low) ***
```

This repeats indefinitely. Unlike MAME, TIP never goes HIGH in our simulation.

**Hypothesis**: The 68000 is not writing to VIA ORB to set PB5 (TIP) high, or our VIA is not correctly outputting PB5.

## Files Modified

```
rtl/
├── egret.sv              # Egret with via_byteack_in for VIA_FULL + debug logging
├── egret_rom.bin         # Extracted ROM binary
├── egret_rom.hex         # ROM in hex format
├── dataController_top.sv # Egret reset control + 68000 VIA debug logging
└── jt6805/               # CPU core files

verilator/
├── Makefile              # Build with USE_EGRET_CPU
└── dis6805.py            # 68HC05 disassembler for debugging
```

## Switching Between Implementations

**Use real Egret CPU (default for simulation):**
```makefile
V_DEFINE = ... +define+USE_EGRET_CPU=1 ...
```

**Use state machine (cuda_maclc.sv):**
```makefile
V_DEFINE = ... # Remove +define+USE_EGRET_CPU=1
```

## Next Steps

1. **Debug 68000 VIA writes**: Check if 68000 writes to VIA ORB to set PB5 (TIP) high
2. **Compare VIA output**: Verify via_pb_o[5] (TIP) is being set correctly
3. **Check VIA DDRB**: Ensure PB5 is configured as output in the VIA
4. **Trace timing**: Compare simulation timing with MAME to find when TIP should change

## References

- MAME source: `src/mame/apple/egret.cpp`, `src/mame/apple/v8.cpp`
- Egret ROM: 341s0850 (4352 bytes)
- jt6805 source: jtcores/modules/jt680x
- 68HC05 datasheet for instruction timing
- MAME trace files:
  - `egret.txt` (4.2M lines - Egret CPU trace)
  - `mame_maclcboot.txt` (144MB - 68000 CPU trace)
