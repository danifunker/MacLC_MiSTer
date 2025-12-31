# Egret/VIA Communication Debug Status

## Current Status: COMMUNICATION WORKING!

### Update Dec 31, 2024 - Major Fixes Applied

**FIXED!** The Egret/VIA communication is now working. Multiple bugs were identified and fixed:

1. **Artificial reset delay removed** - There was a 278K cycle delay in egret_wrapper.sv that didn't exist in MAME
2. **VIA Port B signal routing fixed** - Egret's Port B was incorrectly overriding VIA's Port B input

---

## Bugs Fixed

### Bug 1: Artificial 68020 Reset Delay (egret_wrapper.sv)

**Problem:** Code added a ~278,528 cycle delay before releasing the 68020 from reset:
```verilog
// OLD CODE - WRONG
if (reset_release_counter < 20'h44000) begin
    reset_680x0 = 1'b1;  // Hold in reset
end else begin
    reset_680x0 = pc_out[3];
end
```

**Fix:** Match MAME behavior - release 68020 immediately when Egret firmware writes Port C:
```verilog
// NEW CODE - CORRECT
// Hold in reset until firmware configures Port C (prevents early release)
reg pc_configured;  // Set when firmware writes Port C DDR or latch

// Mark Port C as configured when firmware writes to DDR or latch
if (port_cs && !cpu_wr && (cpu_addr[4:0] == 5'h02 || cpu_addr[4:0] == 5'h06)) begin
    pc_configured <= 1'b1;
end

// Match MAME: reset controlled by Egret firmware via Port C bit 3
reset_680x0 = pc_configured ? pc_out[3] : 1'b1;
```

**Result:** 68020 reset released at Egret cycle 21 (after DDR configured)

### Bug 2: VIA Port B Input Override (dataController_top.sv)

**Problem:** Egret's Port B output (cuda_pb_o) was incorrectly overriding VIA's Port B input:
```verilog
// OLD CODE - WRONG
assign via_pb_i = (pb_pin_level & ~cuda_pb_oe) | (cuda_pb_o & cuda_pb_oe);
```

This caused Egret's CB1 clock (pb_ddr[4]=1, pb_out[4]=0) to be seen by VIA as BYTEACK=0 (asserted), confusing the 68020.

**Fix:** Don't mix Egret's Port B with VIA's Port B:
```verilog
// NEW CODE - CORRECT
// VIA Port B input - just use the pin level directly.
// Don't mix in Egret's Port B output (cuda_pb_o) - the two Port B registers are on
// different chips with completely different meanings. TREQ (bit 3) is already handled
// via the pb3_open_drain logic above.
assign via_pb_i = pb_pin_level;
```

**Result:** VIA now correctly reads TREQ from Egret without false BYTEACK signals

---

## Working Communication Sequence

With the fixes applied, the Egret/VIA handshake now works correctly:

| Time | Event | Details |
|------|-------|---------|
| Egret cycle 0 | Boot starts | Egret begins initialization |
| Egret cycle 21 | 68020 released | Port C DDR configured, reset_680x0 = 0 |
| Egret cycle 501 | TREQ asserted | cuda_treq changes 0->1 |
| System cycle 4.5M | 68020 reads VIA | Sees TREQ asserted, BYTEACK not asserted |
| System cycle 4.5M | 68020 writes TIP | VIA ORB_W: 0x48 (TIP=1) |
| Egret cycle 5377 | TIP received | via_tip changes 1->0 |
| Egret cycle 5378 | Communication | Egret responds with CB2 data |
| System cycle 5.9M+ | SR transfers | Shift register read/write cycles |

### VIA Activity Log (Working)
```
VIA DDRB_W[4497371]: 00 (PB5_dir=0 PB4_dir=0 PB3_dir=0)
VIA ORB_W[4500411]: 48 TIP=1 BYTEACK=1 TREQ_in=1     <- 68020 asserts TIP
VIA DDRB_W[4500491]: f7 (PB5_dir=1 PB4_dir=1 PB3_dir=0)
VIA ORB_R[4500818]: 40 TREQ=1 TIP=1 BYTEACK=1        <- Both TIP and TREQ asserted
VIA: ACR WRITE = 0x1c (shift_mode=7, shift_dir=1, ext_clk=1)
VIA: SR WRITE = 0x01 (shift_active=0, shift_mode=7)  <- Data transfer begins
```

### Egret Activity Log (Working)
```
EGRET[5377]: TIP from VIA changed: 1 -> 0           <- Egret sees TIP
EGRET[5378]: PB OUT 0x49->0x41 (CB1=0 CB2=0 TREQ=0) <- Egret responds
EGRET[5398]: PB OUT 0x41->0x61 (CB1=0 CB2=1 TREQ=0) <- CB2 data output
EGRET pb_r: 61 TIP=1 BYTEACK=1 (PC=1230)            <- In message handling
```

---

## Signal Mapping Reference

### VIA Port B (V8 Protocol)
| Bit | Signal | Direction | Description |
|-----|--------|-----------|-------------|
| 5 | SYS_SESSION | Output | TIP to Egret |
| 4 | VIA_FULL | Output | BYTEACK to Egret |
| 3 | XCVR_SESSION | Input | TREQ from Egret |

### Egret Port B (68HC05)
| Bit | Signal | Direction | Description |
|-----|--------|-----------|-------------|
| 7 | DFAC SCL | Output | I2C clock |
| 6 | DFAC SDA | I/O | I2C data |
| 5 | VIA SR data | I/O | CB2 shift data |
| 4 | VIA clock | Output | CB1 shift clock |
| 3 | SYS_SESSION | Input | TIP from VIA |
| 2 | VIA_FULL | Input | BYTEACK from VIA |
| 1 | XCVR_SESSION | Output | TREQ to VIA |
| 0 | +5v sense | Input | Power good |

---

## Files Modified

### egret_wrapper.sv
- Lines 433-462: Removed artificial 278K cycle reset delay
- Lines 461-462: Added pc_configured flag for proper reset control
- Reset timing now matches MAME behavior

### dataController_top.sv
- Line 370: Fixed via_pb_i assignment to not use cuda_pb_o override
- Comment added explaining why Egret Port B shouldn't override VIA Port B

### via6522.sv
- Line 324-329: Added DDRB write logging
- Line 303-308: Unconditional ORB write logging for debugging

---

## Previous Fixes (All Working)

- VIA Mode 7 (Shift OUT): Fixed edge pulse detection
- VIA Mode 3 (Shift IN): Fixed external clock mode detection
- pb_in computation: Correctly reflects external signals
- 680x0 reset release: Now matches MAME timing
- Egret init sequence: Completes and enters main loop
- **NEW: TIP/TREQ handshake working**
- **NEW: Shift register data transfer working**
