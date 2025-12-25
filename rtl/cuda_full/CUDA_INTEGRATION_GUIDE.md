# CUDA Implementation Comparison & Integration Guide

## Three Implementation Options

### 1. `cuda_stub.sv` - Your Original Minimal Stub
**Purpose**: Get past ROM initialization with minimal functionality

**Pros**:
- Very simple, easy to understand
- Low resource usage
- Already working in your Mac LC core

**Cons**:
- No actual CUDA protocol implementation
- Can't handle real CUDA commands
- Won't work with Mac OS fully booted
- Just auto-completes transfers with dummy data

**When to use**: Early development, ROM debugging, minimal functionality testing

### 2. `cuda_complete.sv` - Full Featured Implementation  
**Purpose**: Complete CUDA emulation with all protocol features

**Pros**:
- Comprehensive command support
- Full PRAM emulation (256 bytes)
- Real-time clock
- Proper state machine
- Ready for full Mac OS operation

**Cons**:
- More complex
- Higher resource usage
- May need tuning for your specific core

**When to use**: Production Mac LC core, full OS support needed

### 3. `cuda_maclc.sv` - Mac LC Optimized Version
**Purpose**: Tailored specifically for Mac LC/LC II integration

**Pros**:
- Clean VIA interface
- Optimized for MiSTer FPGA constraints
- Better signal naming for integration
- TypeScript-style state enums (SystemVerilog)
- Direct CB1/CB2 control

**Cons**:
- Requires SystemVerilog support
- Less generic than cuda_complete

**When to use**: Best choice for your Mac LC core on MiSTer

---

## Detailed Feature Comparison

| Feature | cuda_stub | cuda_complete | cuda_maclc |
|---------|-----------|---------------|------------|
| **Protocol** | None (dummy) | Full | Full |
| **PRAM** | ✗ | ✓ 256 bytes | ✓ 256 bytes |
| **RTC** | ✗ | ✓ 32-bit | ✓ 32-bit |
| **Commands** | 0 | 8+ | 8+ |
| **ADB** | ✗ | Stub | Stub |
| **I2C** | ✗ | Pins only | Pins only |
| **State Machine** | 5 states | 9 states | 12 states |
| **VIA Integration** | Basic | Generic | Optimized |
| **Lines of Code** | ~200 | ~600 | ~550 |
| **HDL Style** | Verilog-2001 | Verilog-2001 | SystemVerilog |

---

## Integration into Mac LC Core

### Current Stub Replacement

Your current cuda_stub.sv instantiation probably looks like:

```systemverilog
cuda_stub cuda (
    .clk(clk),
    .clk8_en(clk8_en),
    .reset(reset),
    .via_pb_i(via_portb_in),
    .cuda_pb_o(cuda_portb_out),
    .cuda_pb_oe(cuda_portb_oe),
    .via_sr_active(via_sr_active),
    .via_sr_out(via_sr_out),
    .cuda_sr_trigger(cuda_sr_int),
    .cuda_cb1(cuda_cb1),
    .cuda_cb1_oe(cuda_cb1_oe),
    .cuda_cb2(cuda_cb2),
    .cuda_cb2_oe(cuda_cb2_oe)
);
```

### Recommended Replacement (cuda_maclc)

```systemverilog
cuda_maclc cuda (
    .clk(clk),
    .clk8_en(clk8_en),
    .reset(reset),
    
    // Direct VIA signals
    .via_tip(via_portb_in[3]),          // Port B bit 3
    .via_byteack_in(via_portb_in[2]),   // Port B bit 2 (if VIA drives it)
    .cuda_treq(cuda_treq),              // Connect to Port B bit 1
    .cuda_byteack(cuda_byteack),        // Connect to Port B bit 2
    
    // CB1/CB2 shift register
    .cuda_cb1(cuda_cb1),
    .via_cb2_in(via_cb2_from_via),      // VIA's CB2 output
    .cuda_cb2(cuda_cb2_to_via),         // CUDA's CB2 output
    .cuda_cb2_oe(cuda_cb2_oe),
    
    // VIA SR events
    .via_sr_read(via_sr_read_strobe),   // VIA reads SR (shift-in complete)
    .via_sr_write(via_sr_write_strobe), // VIA writes SR (shift-out starts)
    .cuda_sr_irq(cuda_sr_interrupt),    // Set SR interrupt flag
    
    // Full Port B for compatibility
    .cuda_portb(cuda_full_portb),
    .cuda_portb_oe(cuda_full_portb_oe),
    
    // ADB
    .adb_data_in(adb_in),
    .adb_data_out(adb_out),
    
    // System control
    .reset_680x0(cuda_reset_cpu),
    .nmi_680x0(cuda_nmi_cpu)
);

// Combine Port B outputs
assign via_portb_in = (via_portb_oe & via_portb_out) |
                      (cuda_full_portb_oe & cuda_full_portb) |
                      (~(via_portb_oe | cuda_full_portb_oe) & 8'hFF);

// Handle CB2 bidirectional
assign via_cb2 = cuda_cb2_oe ? cuda_cb2_to_via : 1'bz;
assign cuda_cb2_from_via = via_cb2;
```

### VIA Shift Register Integration

The key to proper CUDA operation is correct VIA shift register handling:

**VIA Modes**:
- Mode 5: Shift out under external clock (CB1)
- Mode 7: Shift in under external clock (CB1)

**Important signals**:
```systemverilog
// Generate these in your VIA module:
wire via_sr_write_strobe;  // Pulse when CPU writes to SR
wire via_sr_read_strobe;   // Pulse when CPU reads SR
wire via_sr_mode_shift_in; // ACR[4:2] == 3'b111 (mode 7)
wire via_sr_mode_shift_out;// ACR[4:2] == 3'b101 (mode 5)

// In VIA:
always @(posedge clk) begin
    if (cpu_writes_to_sr_register) begin
        via_sr_write_strobe <= 1'b1;  // Pulse for one cycle
    end else begin
        via_sr_write_strobe <= 1'b0;
    end
end
```

---

## Understanding CUDA Protocol Flow

### Example: Reading PRAM Location 0x08

```
1. Mac ROM Setup:
   - VIA Port B bit 3 (TIP) = 1       // Start transaction
   - Wait for CUDA ready

2. Send Command:
   - VIA writes 0x07 to SR            // READ_PRAM command
   - CUDA generates CB1 clock pulses
   - CUDA receives byte via CB2
   - CUDA sets SR interrupt flag

3. Send Length:
   - VIA writes 0x01 to SR            // 1 data byte
   - CUDA clocks it in

4. Send Address:
   - VIA writes 0x08 to SR            // PRAM address 0x08
   - CUDA clocks it in

5. CUDA Processing:
   - CUDA looks up pram[0x08]
   - Prepares response
   - Asserts TREQ low (ready)

6. Mac ROM Response:
   - TIP = 0                          // Ready to receive
   - Wait for CUDA to send

7. Receive Length:
   - CUDA shifts out 0x02             // 2 bytes coming
   - VIA reads from SR

8. Receive Data:
   - CUDA shifts out 0x02             // CMD_PSEUDO
   - CUDA shifts out 0x13             // PRAM value
   - VIA reads each byte

9. Complete:
   - TIP returns to idle state
   - Transaction done
```

### Timing Diagram

```
          _____           _________           ________
TIP   ___/     \_________/         \_________/        \___

               ___   ___   ___   ___   ___   ___
CB1   ________/   \_/   \_/   \_/   \_/   \_/   \______
                ^ Command  ^ Length  ^ Data ^

        ____                     ____
TREQ  _/    \___________________/    \____________________
        ^Ready  ^Busy processing  ^Response ready
```

---

## Signal Mapping Reference

### Port B Bits (from MAME)

```
7: IIC_SCL   - I2C Serial Clock
6: IIC_SDA   - I2C Serial Data  
5: VIA_DATA  - Shift register data (unused in ext clock mode)
4: VIA_CLK   - Shift register clock (unused, CB1 used instead)
3: TIP       - Transaction In Progress (input from Mac)
2: BYTEACK   - Byte Acknowledge (output to Mac)
1: TREQ      - Transfer Request (output to Mac, ACTIVE LOW)
0: +5V_SENSE - Power supply present
```

### CB1/CB2 (VIA Handshake Lines)

```
CB1: Clock output from CUDA
     - CUDA generates clock pulses for shift register
     - Typically ~100-500 kHz
     - Polarity: sample on rising edge

CB2: Bidirectional data
     - When VIA → CUDA: CB2 is input to CUDA
     - When CUDA → VIA: CB2 is output from CUDA
     - Synchronized with CB1 clock
```

---

## Common Integration Issues

### Issue 1: TREQ Polarity

**Symptom**: Mac hangs waiting for CUDA

**Cause**: TREQ is active LOW in hardware

**Fix**:
```systemverilog
// WRONG:
assign portb[1] = cuda_treq;  // If cuda_treq is 1=ready

// CORRECT:
assign portb[1] = ~cuda_treq; // Invert: 1 in logic = 0 on wire = ready
```

### Issue 2: CB1 Not Toggling

**Symptom**: No shift register activity

**Cause**: CB1 enable not set or wrong mode

**Fix**:
```systemverilog
// Ensure CB1 is driven by CUDA, not VIA
assign cb1_final = cuda_cb1_oe ? cuda_cb1 : 1'b1;  // Default high
```

### Issue 3: SR Interrupt Not Firing

**Symptom**: VIA never sees data transfer complete

**Cause**: cuda_sr_irq not connected to VIA IFR

**Fix**:
```systemverilog
// In VIA module:
always @(posedge clk) begin
    if (cuda_sr_irq)
        ifr[SR_BIT] <= 1'b1;  // Set SR interrupt flag
end
```

### Issue 4: Wrong Shift Direction

**Symptom**: Garbage data transferred

**Cause**: CB2 driven when should be input or vice versa

**Fix**:
```systemverilog
// When VIA sending to CUDA:
assign cb2_mux = 1'bz;  // High-Z, let VIA drive it

// When CUDA sending to VIA:
assign cb2_mux = cuda_cb2_oe ? cuda_cb2 : 1'bz;
```

---

## Testing Strategy

### Phase 1: Basic Communication
1. Verify TREQ toggles on reset
2. Check TIP signal from ROM
3. Confirm CB1 toggles during transfers

### Phase 2: Command Testing
1. Monitor Read Version command (0x11)
2. Test PRAM read (0x07) - should return value
3. Test PRAM write (0x0C) then read back

### Phase 3: ROM Boot
1. Mac ROM should complete CUDA init
2. Check for PRAM validation
3. Look for RTC read attempts

### Debug Signals to Monitor

```systemverilog
// Add to top level for debugging:
(* mark_debug = "true" *) wire cuda_state_debug;
(* mark_debug = "true" *) wire [7:0] cuda_cmd_debug;
(* mark_debug = "true" *) wire cuda_treq_debug;
(* mark_debug = "true" *) wire via_tip_debug;

// In CUDA module:
assign cuda_state_debug = (state == IDLE) ? 1'b0 : 1'b1;
assign cuda_cmd_debug = command_byte;
```

---

## Resource Usage Estimates

**For Cyclone V (MiSTer)**:

| Module | Logic Elements | Registers | RAM Bits |
|--------|---------------|-----------|----------|
| cuda_stub | ~150 | ~50 | 0 |
| cuda_complete | ~800 | ~400 | 2048 |
| cuda_maclc | ~700 | ~350 | 2048 |

*PRAM storage (256 bytes) is the main RAM usage*

---

## Migration Path

### Step 1: Drop-in Test (Safest)
Keep your cuda_stub.sv, just add cuda_maclc.sv to project to ensure it compiles.

### Step 2: Parallel Testing  
Instantiate both, use a switch to select which is active:
```systemverilog
wire [7:0] cuda_stub_pb, cuda_maclc_pb;
assign cuda_pb = use_new_cuda ? cuda_maclc_pb : cuda_stub_pb;
```

### Step 3: Full Replacement
Remove cuda_stub entirely, use cuda_maclc as primary CUDA.

### Step 4: Validation
- Boot to Mac OS
- Test system preferences (uses PRAM)
- Check date/time (uses RTC)
- Verify keyboard/mouse if ADB implemented

---

## Next Steps After CUDA

Once CUDA is working, you can enhance:

1. **Complete ADB Protocol**
   - Implement bit-level timing
   - Add device polling
   - Support multiple ADB devices

2. **I2C/DFAC Support**
   - Add I2C master controller
   - Control audio if Mac LC has sound

3. **Power Management**
   - Soft power control
   - Proper shutdown sequencing

4. **Enhanced Compatibility**
   - Test with multiple ROM versions
   - Handle obscure commands
   - Match MAME timing more closely

---

## References & Resources

### MAME Source
- `mame/src/devices/machine/cuda.cpp` - Main reference
- `mame/src/devices/machine/cuda.h` - Header defines
- `mame/src/devices/cpu/m6805/` - 68HC05 emulation

### Mac Technical Documentation
- Inside Macintosh: Operating System Utilities
- Inside Macintosh: Devices (ADB section)
- Tech Note: CUDA and the Desktop Bus

### Community Resources
- 68k Macintosh Liberation Army Discord
- MiSTer FPGA Forums
- VintageApple.org

---

## Questions to Consider

Before integrating, think about:

1. **Do you need full PRAM?**
   - Some games/apps depend on PRAM settings
   - System 7 uses PRAM heavily

2. **Is RTC important?**
   - Mac OS uses it for file timestamps
   - Some copy protection checks date

3. **What about ADB?**
   - You probably have keyboard/mouse via USB adapter
   - Real ADB may not be necessary

4. **Resource constraints?**
   - cuda_stub uses least resources
   - cuda_maclc is good middle ground
   - cuda_complete most comprehensive

Choose based on your goals and FPGA capacity!

---

*This guide assumes you're familiar with your existing Mac LC core structure. 
Adapt signal names and connections as needed for your specific implementation.*
