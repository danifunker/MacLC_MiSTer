# Egret Implementation Progress & Debug Plan

## Overview

Mac LC uses **Egret** (not CUDA) as its ADB/PRAM/RTC microcontroller. This document tracks the implementation of the real Egret using the m68hc05_core CPU (from OpenCores) and the actual Egret ROM (341S0851).

## Clock Configuration (Updated 2024-12)

### Reference: MAME maclc.cpp
| Signal | Frequency | Source |
|--------|-----------|--------|
| C32M | 31.3344 MHz | Master XTAL |
| C15M | 15.6672 MHz | C32M/2 - 68020, V8, ADB, SWIM |
| C7M | 7.8336 MHz | C32M/4 - SCC |
| Egret | 4.194 MHz | 32.768 kHz × 128 (M68HC05E1) |

### Current Implementation
| Component | Clock | Implementation |
|-----------|-------|----------------|
| System | 32 MHz | sim.v clk_sys |
| 68020 CPU | 16 MHz | TG68K with cpu=11 (68020 mode), status_turbo=1 |
| Egret HC05 | 4 MHz | 32 MHz / 8 divider in egret_wrapper.sv |
| VIA/V8 | 8 MHz | clk8_en_p/n from busPhase |

### Clock Divider Details
```verilog
// addrController_top.v - generates clock enables from 32 MHz
busPhase <= busPhase + 1;  // 2-bit counter
clk8_en_p = (busPhase == 2'b11);  // 8 MHz pulse
clk16_en_p = !busPhase[0];         // 16 MHz pulse

// egret_wrapper.sv - generates 4 MHz for HC05
reg [2:0] clk_div;
wire cen = (clk_div == 3'b000);  // 4 MHz pulse (32/8)
```

## Implementation Status

### Completed

| Component | File | Status |
|-----------|------|--------|
| Egret ROM extraction | `rtl/egret/egret_rom.hex` | Done - 4352 bytes, maps to 0x0F00-0x1FFF |
| m68hc05_core CPU | `rtl/egret/m68hc05_core.sv` | Converted from OpenCores, added cen input |
| Egret wrapper | `rtl/egret/egret_wrapper.sv` | Port handling, clock divider, PRAM loading |
| Build integration | `verilator/Makefile` | USE_EGRET_CPU define |
| Clock enable | `m68hc05_core.sv` | Added `cen` input for 4 MHz operation |
| PRAM loading | `egret_wrapper.sv` | Loads egret.pram on 680x0 reset assertion |
| Clock domain sync | `egret_wrapper.sv` | 3-bit synchronizers for VIA signals |
| Handshake state machine | `egret_wrapper.sv` | INIT_WAIT → INIT_ASSERT → INIT_DELAY → RUNNING |
| CB1 gating | `egret_wrapper.sv` | CB1 output gated until TIP is asserted |
| Reset delay (SIMULATION) | `dataController_top.sv` | Uses 0x2000 cycles at 8MHz |
| **Reset_680x0 logic fix** | `egret_wrapper.sv` | Changed from `& ~pc_out[3]` to `\| pc_out[3]` |
| **Wait for ROM download** | `sim.v` | n_reset held low until dio_download completes |

### Recent Fixes (2024-12-28)

#### Fix 1: reset_680x0 Logic Bug
The reset_680x0 signal was using incorrect logic:
```verilog
// BEFORE (wrong):
reset_680x0 = reset_680x0_override & ~pc_out[3];

// AFTER (correct):
reset_680x0 = reset_680x0_override | pc_out[3];
```
Per MAME egret.cpp: Port C bit 3 = 1 means ASSERT reset, bit 3 = 0 means RELEASE reset.

#### Fix 2: ROM Download Timing
The 68020 was being released from reset before ROM download completed (~frame 9).
System reset now waits for ROM download:
```verilog
// sim.v - n_reset stays low until download completes
if(~pll_locked || reset || dio_download) begin
    rst_cnt <= '1;
    n_reset <= 0;
end
```

### Current Issue: 68020 Still Not Running

After the above fixes, the 68020 still doesn't appear to execute code:
- `minResetPassed` stays 0 (reset delay timer not counting)
- Egret releases/asserts 68020 reset multiple times
- CPU trace shows no instruction fetches after download
- Screenshot at frame 360 is blank white

Suspected cause: The reset delay timer in dataController_top may not be starting
because `_systemReset` (n_reset) isn't going high after download completes.

## Memory Map (68HC05)

| Address Range | Size | Description |
|---------------|------|-------------|
| 0x0000-0x001F | 32B | I/O Registers (Ports A, B, C, DDR, Timer) |
| 0x0090-0x01FF | 368B | Internal RAM |
| 0x0F00-0x1FFF | 4352B | ROM (Egret firmware 341S0851) |

### ROM Mapping
```
CPU Address    ROM Offset   Content
0x0F00-0x0FFF  0x000-0x0FF  Copyright notice
0x1000-0x1FFF  0x100-0x10FF Main code
0x1FFE-0x1FFF  0x10FE-0x10FF Reset vector (0x0F71)
```

### I/O Register Map (M68HC05E1)
| Address | Register | Description |
|---------|----------|-------------|
| 0x00 | PORTA | Port A data |
| 0x01 | PORTB | Port B data |
| 0x02 | PORTC | Port C data |
| 0x04 | DDRA | Port A direction (1=output) |
| 0x05 | DDRB | Port B direction |
| 0x06 | DDRC | Port C direction |
| 0x07 | PLL | PLL control / timer prescale |
| 0x08 | TCR | Timer control |
| 0x09 | TSR | Timer counter (free-running) |
| 0x12 | One-second | 1-second timer control |

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

### Port B ($01) - VIA Interface
| Bit | Dir | Function | Notes |
|-----|-----|----------|-------|
| 7 | O | DFAC clock (I2C SCL) | |
| 6 | I/O | DFAC data (I2C SDA) | Tied high |
| 5 | I/O | CB2 - Shift register data | |
| 4 | O | CB1 - Shift register clock | Gated by TIP |
| 3 | I | TIP from VIA (SYS_SESSION) | PB5 from VIA |
| 2 | I | VIA_FULL (BYTEACK) | PB4 from VIA |
| 1 | O | TREQ to VIA (XCVR_SESSION) | Active LOW |
| 0 | I | +5V sense | Always 1 |

### Port C ($02) - 68000 Control
| Bit | Dir | Function |
|-----|-----|----------|
| 3 | O | 680x0 reset (active high = ASSERT reset) |
| 2-0 | O | IPL2-0 (active low) |

## VIA Shift Register Protocol

1. Egret asserts TREQ (PB1=0) to request transfer
2. VIA sets TIP (PB5=0) to acknowledge
3. Egret clocks CB1 8 times to shift data via CB2
4. VIA sets SR interrupt flag when byte complete
5. Process repeats for each byte

## Current Simulation Behavior

1. ✅ Egret ROM loads correctly (4352 bytes)
2. ✅ Egret CPU runs at 4 MHz
3. ✅ CB1 toggles from Egret firmware
4. ✅ CB1 gating added - only passes through when TIP=0
5. ✅ reset_680x0 logic fixed (was inverted)
6. ✅ System reset waits for ROM download
7. ⚠️ 68020 still in reset after download (investigating)
8. ❌ No VIA ↔ Egret communication occurs yet

## Files

```
rtl/egret/
├── egret_wrapper.sv    # Main wrapper with port handling, 4MHz clock, CB1 gating
├── m68hc05_core.sv     # CPU core with cen input
├── m68hc05_alu.sv      # ALU for CPU
├── egret_rom.hex       # ROM in hex format (4352 bytes)
├── egret.pram          # PRAM data (loaded on 680x0 reset)
├── convert_firmware.py # ROM to hex conversion
└── convertpram.py      # PRAM conversion script

verilator/
├── sim.v               # Top-level with TG68K in 68020 mode
├── sim_main.cpp        # Testbench with cfg_cpuType=2 (68020)
├── sim_output.txt      # Latest simulation log
└── Makefile            # USE_EGRET_CPU, SIMULATION defines
```

## Next Steps

1. **Debug n_reset assertion** - Verify n_reset goes high after ROM download
   - Check dio_download signal timing
   - Add debug output for n_reset transitions

2. **Verify reset delay timer** - Check minResetPassed
   - Confirm resetDelay counts down after n_reset asserts
   - Track when _cpuReset actually goes high

3. **Check Egret pc_out[3]** - When does firmware release 68020?
   - Egret should clear PC bit 3 to release 68020
   - Currently re-asserting reset too quickly

## References

- MAME source: `mame/src/mame/apple/egret.cpp`
- MAME CPU: `mame/src/devices/cpu/m6805/m68hc05e1.cpp`
- MAME Mac LC: `mame/src/mame/apple/maclc.cpp`
- Egret ROM: 341S0851 (4352 bytes)
- 68HC05E1 datasheet for timer and port behavior
