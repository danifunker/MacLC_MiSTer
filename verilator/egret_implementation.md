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

### Current Behavior

- CPU is executing from ROM (debug shows reads from ROM addresses)
- Reset vector at 0x1FFE correctly points to 0x0F71 (startup code)
- System boots but VIA/Egret communication may have issues

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

## MAME Trace Analysis (egret.txt)

### Startup Sequence (first ~5000 instructions)
1. **0x0F71**: RSP (Reset Stack Pointer)
2. **0x0F72-0x0F81**: Initialize I/O ports from table at 0x0F6A
3. **0x0F83-0x0F97**: Clear RAM ($90-$D6, $0100-$01FF)
4. **0x0F99-0x0FAF**: Set up internal variables
5. **0x0FB0**: CLI (enable interrupts)
6. **0x0FB1-0x0FC8**: Configure ports, timers
7. **0x0FFE+**: Initialize VIA communication

### Key Port Initialization (from trace lines 154-161)
```
123E: lda   #$F7
1240: sta   $02        ; Port C DDR = 0xF7
1242: lda   #$92
1244: sta   $01        ; Port B = 0x92 (1001_0010)
                       ;   bit 7 = 1: DFAC clock high
                       ;   bit 4 = 1: CB1 high
                       ;   bit 1 = 1: TREQ inactive (active low)
1246: clr   $00        ; Port A = 0x00
1248: bclr  3, $00     ; Clear Port A bit 3 (reset pulse off)
124A: bclr  3, $02     ; Clear Port C bit 3
124C: bset  3, $06     ; Set Port C DDR bit 3
```

### VIA Handshake Sequence (from trace)
1. Egret sets TREQ low (`bclr 1, $01`) to request transfer
2. Egret waits for TIP low from VIA (`brclr 3, $01`)
3. Egret clocks CB1 and reads/writes CB2 for each bit
4. After 8 bits, Egret sets TREQ high (`bset 1, $01`)
5. Wait for VIA to release TIP

### First VIA Transaction (trace lines 4797-4829)
```
1640: jsr   $1549
1549: bclr  1, $01      ; Assert TREQ (active low)
154B: ldx   #$04
154D: jsr   $1DD1       ; Short delay
      ... (delay loop)
1550: bclr  4, $01      ; CB1 low  (clock pulse 1)
1552: bset  4, $01      ; CB1 high
1554: bclr  4, $01      ; CB1 low  (clock pulse 2)
1556: bset  4, $01      ; CB1 high
      ... (8 clock pulses total)
156E: bset  4, $01      ; CB1 high (last pulse)
1570: jsr   $1149       ; Check status
```
This is Egret's initial "attention" sequence - it asserts TREQ and sends
8 clock pulses to signal the VIA that it wants to communicate.

### VIA Communication Pattern (from trace)
The Egret clocks CB1 and reads CB2 to receive bytes from VIA:
```
14EF: bclr  4, $01    ; CB1 low (clock low)
14F1: bset  4, $01    ; CB1 high (clock high)
14F3: brset 5, $01, $14F6  ; Read CB2 (data bit)
... (repeat 8 times for each bit)
```

### Key Port B Test Points
- `brset/brclr 0, $01` - Test +5V sense
- `brset/brclr 3, $01` - Test TIP from VIA
- `brset/brclr 6, $01` - Test DFAC data
- `bclr/bset 4, $01` - Toggle CB1 (clock)
- `brset 5, $01` - Read CB2 (data)

## Debug Plan

### Phase 1: Verify CPU Execution
1. **Add wider debug logging in egret.sv**
   - Log all addresses, not just 0x0F00-0x0F10
   - Log Port B changes
   - Compare with MAME trace

2. **Check reset vector reading**
   - Verify CPU reads from 0x1FFE-0x1FFF
   - Verify it jumps to 0x0F71

### Phase 2: Verify Port I/O
1. **Compare port initialization**
   - MAME shows: `sta $07` (Port B DDR = 0x92)
   - MAME shows: `sta $01` (Port B = 0x92)
   - Check if our egret.sv outputs match

2. **Verify Port B inputs**
   - TIP (bit 3) should reflect VIA PB5
   - VIA_FULL (bit 2) should be high
   - +5V sense (bit 0) should be high

### Phase 3: VIA Communication
1. **TREQ signal**
   - Egret asserts TREQ (bit 1 low) to request transfer
   - VIA should see this on PB3

2. **CB1/CB2 clocking**
   - Egret drives CB1 (bit 4) for external clock mode
   - Egret reads/writes CB2 (bit 5) for data

3. **Timing**
   - Check clock divider (should be ~4MHz from 8MHz)
   - Compare instruction timing with MAME

### Phase 4: Integration Test
1. Boot simulation for 360+ frames
2. Check if Egret completes initialization
3. Verify VIA interrupt handling
4. Test PRAM read/write

## Key Differences: Our Implementation vs MAME

| Aspect | Our Implementation | MAME |
|--------|-------------------|------|
| CPU | jt6805 (jtcores) | Custom 68HC05 emulator |
| Clock | 4MHz (8MHz/2) | 4.194MHz (32.768kHz * 128) |
| Port B mapping | Need to verify | Confirmed working |
| Interrupts | Timer only | Timer + external |

## Files Modified

```
rtl/
├── egret.sv           # New Egret implementation
├── egret_rom.bin      # Extracted ROM binary
├── egret_rom.hex      # ROM in hex format for $readmemh
├── dataController_top.sv  # Added ifdef switching
└── jt6805/            # CPU core files
    ├── jt6805.v
    ├── jt6805_alu.v
    ├── jt6805_ctrl.v
    ├── jt6805_regs.v
    ├── 6805.vh
    ├── 6805_param.vh
    └── 6805.uc

verilator/
└── Makefile           # Added jt6805 and USE_EGRET_CPU
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

1. Add comprehensive debug logging to egret.sv
2. Run simulation and compare Port B behavior with MAME trace
3. Fix any Port B input/output mismatches
4. Verify TREQ/TIP handshaking with VIA
5. Test CB1/CB2 shift register clocking
6. Debug any VIA interrupt issues

## References

- MAME source: `src/mame/apple/egret.cpp`
- Egret ROM: 341s0850 (4352 bytes)
- jt6805 source: jtcores/modules/jt680x
- 68HC05 datasheet for instruction timing
