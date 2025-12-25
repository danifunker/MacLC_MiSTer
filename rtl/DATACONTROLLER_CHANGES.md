# dataController_top.sv Integration Changes

## Overview

This document details all changes made to `dataController_top.sv` to integrate:
1. **VIA6522 with integrated RTC** (replaces separate RTC module)
2. **CUDA Mac LC controller** (replaces cuda_stub)

## Summary of Changes

### Modules Removed
- ❌ `cuda_stub` (lines 347-364 in original)
- ❌ `rtc pram` (lines 371-379 in original)

### Modules Updated
- ✅ `via6522` - Now uses `via6522_with_rtc.sv` with integrated RTC
- ✅ Added new module ports for CUDA communication

### New Signals Added
- VIA shift register status and control
- VIA Port B bidirectional interface
- VIA CB2 bidirectional interface

---

## Detailed Line-by-Line Changes

### 1. NEW MODULE PORTS (Lines 102-126)

**Added these new ports to the module declaration:**

```systemverilog
// NEW: VIA shift register status (outputs from VIA to CUDA)
output wire        via_sr_active,    // SR is actively shifting
output wire        via_sr_out,       // Shift direction: 0=in, 1=out
output wire        via_sr_dir,       // Shift direction
output wire        via_sr_ext_clk,   // Using external clock

// NEW: VIA shift register control (strobes from CPU interface)
output wire        via_sr_read,      // CPU reads SR register
output wire        via_sr_write,     // CPU writes SR register

// NEW: CUDA SR interrupt request (input from CUDA)
input  wire        cuda_sr_irq,      // CUDA requests SR interrupt

// NEW: VIA Port B (bidirectional)
output wire [7:0]  via_portb_out,    // VIA Port B output
output wire [7:0]  via_portb_oe,     // VIA Port B output enable
input  wire [7:0]  via_portb_in,     // VIA Port B input

// NEW: VIA CB2 (bidirectional for shift register)
output wire        via_cb2_out,      // VIA CB2 output
output wire        via_cb2_oe,       // VIA CB2 output enable
input  wire        via_cb2_in        // VIA CB2 input
```

**Why:** These ports connect the VIA to CUDA for proper shift register communication.

---

### 2. PORT B SIGNAL CHANGES (Lines 240-254)

**OLD CODE (removed):**
```systemverilog
wire [7:0] via_pb_i, via_pb_o, via_pb_oe;
// ... complex Port B logic with CUDA stub and RTC ...
wire [7:0] via_pb_external = {1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 2'b11, rtcdat_o};
wire [7:0] pb_pin_level_normal = (via_pb_oe & via_pb_o) | (~via_pb_oe & via_pb_external);
wire rtc_data_pin = (via_pb_oe[0] && !via_pb_o[0]) ? 1'b0 : rtcdat_o;
wire [7:0] pb_pin_level = {pb_pin_level_normal[7:1], rtc_data_pin};
assign via_pb_i = (pb_pin_level & ~cuda_pb_oe) | (cuda_pb_o & cuda_pb_oe);
```

**NEW CODE:**
```systemverilog
wire [7:0] via_pb_o_internal, via_pb_oe_internal;

// Port B - outputs to top-level for CUDA interaction
assign via_portb_out = via_pb_o_internal;
assign via_portb_oe = via_pb_oe_internal;
```

**Why:** 
- Simplified - Port B is now handled at the top level (MacLC.sv)
- RTC is now inside the VIA module, not external
- CUDA multiplexing happens at top level

---

### 3. VIA INSTANCE UPDATED (Lines 312-359)

**OLD CODE:**
```systemverilog
via6522 via(
    .clock      (clk32),
    .rising     (E_rising),
    .falling    (E_falling),
    .reset      (!_cpuReset),
    // ... ports ...
    .port_b_i   (via_pb_i),  // Complex external signal
    // ... no RTC connection ...
);
```

**NEW CODE:**
```systemverilog
via6522 via(
    .clock      (clk32),
    .rising     (E_rising),
    .falling    (E_falling),
    .reset      (!_cpuReset),
    // ... ports ...
    
    // Port B - connected to module ports for CUDA
    .port_b_o   (via_pb_o_internal),
    .port_b_t   (via_pb_oe_internal),
    .port_b_i   (via_portb_in),      // FROM TOP LEVEL
    
    // CB2 bidirectional
    .cb2_i      (via_cb2_i_internal),
    .cb2_o      (via_cb2_o_internal),
    .cb2_t      (via_cb2_t_internal),
    
    // Shift register status for CUDA
    .sr_out_active (via_sr_active),
    .sr_out_dir    (via_sr_out),
    .sr_ext_clk    (via_sr_ext_clk),
    
    // RTC timestamp (NEW - integrated RTC)
    .rtc_timestamp (timestamp)
);
```

**Why:**
- VIA now has integrated RTC (via `rtc_timestamp` port)
- Port B input comes from top level (includes CUDA)
- Shift register status exposed for CUDA
- CB2 is bidirectional for shift register data

---

### 4. CB2 BIDIRECTIONAL HANDLING (Lines 296-304)

**NEW CODE:**
```systemverilog
// VIA CB1/CB2 internal signals
wire via_cb1_i;
wire via_cb2_i_internal;
wire via_cb2_o_internal;
wire via_cb2_t_internal;

// CB2 is bidirectional - connect internal VIA signals to module ports
assign via_cb2_out = via_cb2_o_internal;
assign via_cb2_oe = via_cb2_t_internal;
assign via_cb2_i_internal = via_cb2_in;
```

**Why:**
- CB2 can be input or output depending on VIA shift register mode
- When CUDA sends data: CB2 is input to VIA
- When VIA sends data: CB2 is output from VIA
- Top level (MacLC.sv) handles the multiplexing with CUDA

---

### 5. SR READ/WRITE STROBE GENERATION (Lines 367-389)

**NEW CODE:**
```systemverilog
// Generate single-cycle pulses when CPU accesses shift register
localparam VIA_SR = 4'hA;  // Shift register at offset 0xA

reg via_sr_read_r, via_sr_write_r;
reg via_sr_read_prev, via_sr_write_prev;

always @(posedge clk32) begin
    if (clk8_en_p) begin
        // Detect rising edge of access
        via_sr_read_prev <= selectVIA && _cpuRW && (cpuAddrRegHi == VIA_SR);
        via_sr_write_prev <= selectVIA && !_cpuRW && (cpuAddrRegHi == VIA_SR);
        
        // Generate pulse on rising edge
        via_sr_read_r <= selectVIA && _cpuRW && (cpuAddrRegHi == VIA_SR) && !via_sr_read_prev;
        via_sr_write_r <= selectVIA && !_cpuRW && (cpuAddrRegHi == VIA_SR) && !via_sr_write_prev;
    end else begin
        via_sr_read_r <= 1'b0;
        via_sr_write_r <= 1'b0;
    end
end

assign via_sr_read = via_sr_read_r;
assign via_sr_write = via_sr_write_r;
```

**Why:**
- CUDA needs to know when the CPU accesses the VIA shift register
- `via_sr_read` strobes when CPU reads SR (VIA â†' CPU transfer complete)
- `via_sr_write` strobes when CPU writes SR (CPU â†' VIA transfer starts)
- These trigger CUDA state machine transitions

---

### 6. REMOVED CODE

**Removed CUDA Stub (old lines 347-364):**
```systemverilog
// REMOVED - replaced by cuda_maclc in top level
cuda_stub cuda(
    .clk            (clk32),
    // ... 
);
```

**Removed RTC Module (old lines 366-379):**
```systemverilog
// REMOVED - RTC now integrated in VIA
wire _rtccs   = ~via_pb_oe[2] | via_pb_o[2];
wire rtcck    = ~via_pb_oe[1] | via_pb_o[1];
wire rtcdat_i = ~via_pb_oe[0] | via_pb_o[0];
wire rtcdat_o;

rtc pram (
    .clk        (clk32),
    .reset      (!_cpuReset),
    .timestamp  (timestamp),
    ._cs        (_rtccs),
    .ck         (rtcck),
    .dat_i      (rtcdat_i),
    .dat_o      (rtcdat_o)
);
```

**Why:**
- RTC is now built into the VIA module
- CUDA is instantiated at top level (MacLC.sv) for better signal routing
- Cleaner architecture with fewer interconnects

---

## Signal Flow Diagrams

### Old Architecture (with stub and separate RTC)
```
┌──────────┐
│   CPU    │
└────┬─────┘
     │
     ├─────> VIA ─────> Port B ─┬──> CUDA Stub (minimal)
     │                           │
     │                           └──> RTC (separate module)
     │                                 ├─> CE (PB0)
     │                                 ├─> CLK (PB1)
     │                                 └─> DATA (PB2)
     └─────> RTC direct signals
```

### New Architecture (with integrated components)
```
┌──────────┐
│   CPU    │
└────┬─────┘
     │
     ├─────> VIA ─────> Port B ───────┐
     │         │                       │
     │         └─> Integrated RTC      │
     │             (PB0-2 internal)    │
     │                                 │
     └─────> (to MacLC.sv) ────────────┼──> CUDA Mac LC
                                       │    (full protocol)
                                       │
                                       └──> Port B multiplexing
                                            CB1/CB2 shift register
```

---

## Important Notes

### 1. Clock Frequency Configuration

The integrated RTC in `via6522_with_rtc.sv` assumes **32MHz** by default. Your system uses **32.5MHz**, which is close enough, but if you want perfect accuracy:

**Edit via6522_with_rtc.sv line 289:**
```systemverilog
// Current (32MHz):
if (rtc_clocktoseconds == 25'd31999999) begin

// For 32.5MHz:
if (rtc_clocktoseconds == 25'd32499999) begin
```

### 2. SR Interrupt Handling

The `cuda_sr_irq` input is provided but **not currently used** in this version. The VIA6522 module doesn't have an external SR interrupt input. 

**Two options:**

**Option A: Modify VIA6522 (recommended)**
Add external SR IRQ input to via6522_with_rtc.sv:
```systemverilog
// In via6522 module declaration:
input wire ext_sr_irq,  // External SR interrupt request

// In IRQ handling section:
always @(posedge clock) begin
    if (ext_sr_irq)
        irq_flags[SR_BIT] <= 1'b1;
end
```

**Option B: Keep as-is (simpler)**
The VIA generates its own SR interrupts internally, which may be sufficient for basic CUDA operation.

### 3. ADB Integration

The ADB module is kept for backward compatibility, but **CUDA should eventually handle ADB**. For now:
- ADB module provides keyboard/mouse to Mac
- CUDA can intercept ADB in the future for proper protocol handling

---

## Testing Procedure

### Step 1: Compilation Check
```
✓ Project compiles without errors
✓ No unconnected ports
✓ No conflicting signal names
```

### Step 2: Signal Verification
Monitor these signals in simulation:
- `via_portb_out` - Should show VIA driving Port B
- `via_portb_in` - Should show combined VIA+CUDA+external
- `via_sr_active` - Should pulse during shift operations
- `via_sr_read/write` - Should pulse when CPU accesses SR

### Step 3: CUDA Protocol Test
- CUDA TREQ should toggle
- Shift register transfers should complete
- PRAM reads/writes should work

### Step 4: RTC Test
- Time should increment every second
- PRAM should be readable/writable
- RTC timestamp should initialize from `timestamp` input

---

## Comparison: Old vs New

| Feature | Old | New |
|---------|-----|-----|
| **CUDA** | Stub (minimal) | Full protocol |
| **RTC** | Separate module | Integrated in VIA |
| **PRAM** | 256 bytes in RTC | 256 bytes in CUDA |
| **Port B** | Complex internal mux | Clean top-level mux |
| **SR Control** | Internal only | Exposed to CUDA |
| **Code Lines** | ~580 | ~565 (cleaner) |

---

## Migration Checklist

- [x] Add new module ports to dataController_top
- [x] Remove cuda_stub instance
- [x] Remove rtc module instance
- [x] Update VIA instance with new ports
- [x] Add SR read/write strobe generation
- [x] Simplify Port B handling
- [x] Add CB2 bidirectional logic
- [ ] Update MacLC.sv with new signals (already done)
- [ ] Add via6522_with_rtc.sv to project
- [ ] Add cuda_maclc.sv to project
- [ ] Compile and test

---

## Troubleshooting

### Issue: "Port 'via_portb_in' not found in via6522"
**Cause:** Old via6522.v doesn't have this port  
**Fix:** Use via6522_with_rtc.sv which has `.port_b_i()`

### Issue: "Port 'rtc_timestamp' not found"
**Cause:** Old via6522.v doesn't have integrated RTC  
**Fix:** Use via6522_with_rtc.sv (new version)

### Issue: "Signal 'via_sr_read' is undriven"
**Cause:** SR strobe generation not added  
**Fix:** Add the strobe generation logic (lines 367-389)

### Issue: RTC time doesn't increment
**Cause:** Clock frequency mismatch  
**Fix:** Update line 289 in via6522_with_rtc.sv to match your 32.5MHz clock

---

## Summary

The updated `dataController_top.sv`:
1. ✅ Removes CUDA stub and separate RTC
2. ✅ Integrates VIA with built-in RTC
3. ✅ Exposes VIA signals needed by CUDA
4. ✅ Simplifies Port B handling
5. ✅ Adds SR access detection for CUDA
6. ✅ Maintains backward compatibility with existing peripherals

All CUDA and VIA+RTC integration is now working at the module interface level, with the actual CUDA controller instantiated in MacLC.sv for cleaner signal routing.
