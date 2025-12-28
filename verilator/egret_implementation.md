# Egret Implementation Progress & Debug Plan

## Overview

Mac LC uses **Egret** (not CUDA) as its ADB/PRAM/RTC microcontroller. This document tracks the implementation of the real Egret using the m68hc05_core CPU (from OpenCores) and the actual Egret ROM (341S0851).

## Implementation Status

### Completed

| Component | File | Status |
|-----------|------|--------|
| Egret ROM extraction | `rtl/egret/341s0851.bin`, `rtl/egret/egret_rom.hex` | Done |
| m68hc05_core CPU | `rtl/egret/m68hc05_core.sv` | Converted from OpenCores VHDL |
| Egret wrapper | `rtl/egret/egret_wrapper.sv` | Created, same interface as cuda_maclc.sv |
| Build integration | `verilator/Makefile` | Added m68hc05_core + USE_EGRET_CPU define |
| Switching mechanism | `rtl/dataController_top.sv` | `ifdef USE_EGRET_CPU` added |
| Verilator build | - | Builds successfully |
| Port A readback | `rtl/egret/egret_wrapper.sv` | Fixed - returns latch for port test |

### Current Issue: Port B DDR Never Written

The Egret firmware never writes to Port B DDR (`PB_ddr` stays 0x00), which means:
- CB1 cannot be driven as output (VIA clock)
- CB2 cannot be driven as output (VIA data)
- VIA shift register communication fails

**Root Cause Analysis:**

The firmware's startup loop at 0x0F71-0x0F7E has a problem:
```
0F71: LDA #$F0       ; DDR value for port test
0F73: BSR $0F3E      ; Port test subroutine
0F75: LDA #$0F       ; Second DDR value
0F77: BSR $0F3E      ; Port test again
0F79: DECX           ; Decrement loop counter
0F7A: STX $96        ; Store counter
0F7C: CPX #$00       ; Compare with 0
0F7E: BPL $0F71      ; Loop if N=0 (X >= 0 signed)
0F80: CLRA           ; Fall through if X went negative
0F81: SWI            ; Software interrupt (restarts at 0x0F71)
```

**The Problem:** X register is never initialized before this loop!
- Both MAME and our CPU initialize X=0 on reset
- After first loop iteration: DECX makes X=0xFF
- CPX #0 with X=0xFF sets N=1 (0xFF is negative in signed)
- BPL doesn't branch, falls through to SWI
- SWI vector is also 0x0F71, so it loops forever

The port initialization code at 0x123E (which writes Port B DDR) is never reached.

**Comparison with MAME:**
- MAME's m6805.cpp line 435: `m_x = 0` on reset (same as us!)
- MAME's m68hc05e1.cpp also uses this base class
- Both ROMs (341s0850 and 341s0851) have identical code at 0x0F71

## Memory Map (68HC05)

| Address Range | Size | Description |
|---------------|------|-------------|
| 0x0000-0x000F | 16B | I/O Registers (Ports A, B, C, DDR, Timer) |
| 0x0050-0x01FF | 432B | Internal RAM |
| 0x0F00-0x1FFF | 4KB | ROM (Egret firmware 341S0851, wraps every 4KB) |
| 0x1FF8-0x1FFF | 8B | Interrupt vectors |

### Interrupt Vectors (from ROM)
| Address | Vector | Handler |
|---------|--------|---------|
| 0xFFF8 | IRQ | 0x1E10 |
| 0xFFFA | Timer | 0x1E7F |
| 0xFFFC | SWI | 0x0F71 |
| 0xFFFE | Reset | 0x0F71 |

Note: SWI and Reset both point to 0x0F71!

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
| Bit | Dir | Function |
|-----|-----|----------|
| 7 | O | DFAC clock (I2C SCL) |
| 6 | I/O | DFAC data (I2C SDA) |
| 5 | I/O | CB2 - Shift register data |
| 4 | O | CB1 - Shift register clock |
| 3 | I | TIP from VIA (SYS_SESSION, active low) |
| 2 | I | VIA_FULL (active low) |
| 1 | O | TREQ to VIA (XCVR_SESSION, active low) |
| 0 | I | +5V sense |

### Port C ($02) - 68000 Control
| Bit | Dir | Function |
|-----|-----|----------|
| 3 | O | 680x0 reset |
| 2-0 | O | IPL2-0 |

## Firmware Analysis

### Reset Entry (0x0F71)
The reset vector points to 0x0F71, which starts with:
```
0F71: A6 F0    LDA #$F0      ; NOT RSP as old docs claimed!
0F73: AD C9    BSR $0F3E     ; Call port test
```

**Note:** Previous documentation incorrectly stated RSP at 0x0F71. Both ROM versions have LDA #$F0.

### Port Test Subroutine (0x0F3E)
Uses X register as port base address:
- X=0: Tests Port A
- X=1: Tests Port B
- X=2: Tests Port C

The subroutine writes a test pattern to the port and reads it back to verify I/O.

### Port Initialization (0x123E) - Never Reached!
This code should initialize Port B DDR but is never executed:
```
123E: LDA #$F7
1240: STA $02        ; Port C DDR = 0xF7
1242: LDA #$92
1244: STA $01        ; Port B = 0x92
```

### Main Loop (0x1ACE)
The Egret does reach its main loop but without proper port initialization:
```
1ACE: JSR $1E4E      ; RTC update routine
1AD1: BRCLR 4,$A2,.. ; Check flags
...                  ; Loop waiting for VIA events
```

## Current Simulation Behavior

1. Port A tests pass (all 4 iterations)
2. X wraps from 0 to 0xFF after first loop
3. Falls through to SWI, restarts at 0x0F71
4. Eventually enters main loop at 0x1ACE (unclear how)
5. Port B DDR remains 0x00 - CB1/CB2 cannot be driven
6. 68020 is released via auto-timer at cycle ~8192
7. VIA TIP toggles but no actual data transfer

## Key Differences: Our Implementation vs MAME

| Aspect | Our Implementation | MAME |
|--------|-------------------|------|
| CPU | m68hc05_core (OpenCores) | M68HC05E1 device |
| Clock | 8MHz (cen=1 always) | 4.194MHz (32.768kHz * 128) |
| Port A read | Returns latch (for test) | Returns (latch & DDR) | (input & ~DDR) |
| Port B DDR | Never written (0x00) | Should be 0x92 |
| X on reset | 0x00 | 0x00 (same!) |

## Files

```
rtl/egret/
├── egret_wrapper.sv    # Main wrapper with port handling
├── m68hc05_core.sv     # CPU core (from OpenCores)
├── 341s0850.bin        # Egret ROM v1.01 (earlier)
├── 341s0851.bin        # Egret ROM v1.01 (later) - ACTIVE
├── 344s0100.bin        # Egret ROM v1.00
├── egret_rom.hex       # Converted from 341s0851.bin
└── convert_firmware.py # ROM conversion script

verilator/
└── Makefile            # USE_EGRET_CPU define
```

## Next Steps

1. **Investigate firmware entry path** - How does MAME's Egret reach 0x123E?
2. **Check if port model difference matters** - MAME combines latch+input, we return latch only
3. **Compare with MAME runtime trace** - Run MAME with debug logging
4. **Consider patching reset vector** - Point to 0x0F6D where X is initialized to 2
5. **Alternative: Initialize X in CPU** - Change m68hc05_core to set X=2 on reset

## References

- MAME source: `mame/src/mame/apple/egret.cpp`
- MAME CPU: `mame/src/devices/cpu/m6805/m68hc05e1.cpp`
- Egret ROM: 341S0851 (4352 bytes with 256-byte header)
- 68HC05 datasheet for instruction timing
