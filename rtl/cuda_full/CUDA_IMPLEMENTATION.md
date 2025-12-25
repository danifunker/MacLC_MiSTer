# Apple CUDA Controller - SystemVerilog Implementation

## Overview

This is a hardware implementation of the Apple CUDA (Cuda-Could've-Done-It-Right) 
microcontroller, based on MAME's `cuda.cpp` emulation by R. Belmont.

CUDA is actually a Motorola 68HC05E1 (v2.xx) or 68HC05E5 (v3.xx) microcontroller 
with custom firmware that handles several critical Mac functions:

- **ADB (Apple Desktop Bus)**: Keyboard and mouse communication
- **I2C/DFAC**: Serial bus for peripheral devices  
- **Power Management**: System power control and monitoring
- **PRAM**: 256 bytes of battery-backed parameter RAM
- **RTC**: Real-time clock with seconds counter

## Hardware Interface

### Port B Mapping (Primary Interface)

The CUDA communicates with the Mac's VIA (Versatile Interface Adapter) via Port B:

```
Bit 7: IIC_SCL   - I2C clock line
Bit 6: IIC_SDA   - I2C data line
Bit 5: VIA_DATA  - Shift register data
Bit 4: VIA_CLK   - Shift register clock
Bit 3: TIP       - Transaction In Progress (input from VIA)
Bit 2: BYTEACK   - Byte acknowledge (to VIA)
Bit 1: TREQ      - Transfer Request (CUDA ready, active low)
Bit 0: +5V_SENSE - Power supply monitoring
```

### Key Signals

**TREQ (Transfer Request)**
- Active LOW signal indicating CUDA is ready
- When high (inactive), CUDA is busy processing
- When low (active), CUDA can accept/send data

**TIP (Transaction In Progress)**  
- Driven by the host (VIA) to indicate an active transaction
- CUDA monitors this to know when the host wants to communicate

**BYTEACK (Byte Acknowledge)**
- CUDA asserts this after successfully receiving each byte
- Provides handshaking feedback to the host

### Shift Register Protocol

Communication uses the VIA's shift register in external clock mode:

1. **Host → CUDA (Command/Data)**:
   - VIA sets up shift register with data
   - Sets `via_sr_out` = 1, `via_sr_active` = 1
   - CUDA generates clock pulses on CB1
   - CUDA captures data on CB2/VIA_DATA

2. **CUDA → Host (Response)**:
   - CUDA asserts TREQ low when ready
   - VIA sets `via_sr_out` = 0, `via_sr_active` = 1  
   - CUDA shifts out data while generating clocks
   - VIA captures the response bytes

## CUDA Protocol

### Transaction Sequence

```
1. Host asserts TIP (bit 3 of Port B)
2. CUDA deasserts TREQ (busy)
3. Host sends command byte via shift register
4. Host sends length byte
5. Host sends data bytes (if length > 0)
6. CUDA processes command
7. CUDA asserts TREQ (ready with response)
8. CUDA sends response length
9. CUDA sends response data bytes
10. Host deasserts TIP
11. Transaction complete
```

### Command Codes

The implementation supports these essential commands:

| Command | Code | Description |
|---------|------|-------------|
| ADB_COMMAND | 0x00 | Execute ADB bus transaction |
| AUTOPOLL | 0x01 | Enable/disable automatic polling |
| PSEUDO | 0x02 | Pseudo-command (response header) |
| READ_RTC | 0x03 | Read real-time clock (4 bytes) |
| READ_PRAM | 0x07 | Read PRAM byte at address |
| WRITE_RTC | 0x09 | Write real-time clock |
| WRITE_PRAM | 0x0C | Write PRAM byte |
| READ_VERSION | 0x11 | Get CUDA firmware version |

### Command Format

**Read PRAM Example**:
```
Host → CUDA: [0x07][0x01][address]
CUDA → Host: [0x02][data_byte]
```

**Write PRAM Example**:
```
Host → CUDA: [0x0C][0x02][address][data]
CUDA → Host: [0x02]
```

**Read Version**:
```
Host → CUDA: [0x11][0x00]
CUDA → Host: [0x02][0x00][0x02][0x00][0x28]
                      ^^^^^^^^^^^^^^^^
                      Version 2.40 = 0x00020028
```

## Implementation Details

### State Machine

The CUDA operates with these states:

```
ST_IDLE         - Waiting for transaction start
ST_RECEIVE_CMD  - Receiving command byte
ST_SHIFT_BYTE   - Shifting byte (with clock generation)
ST_RECV_LENGTH  - Receiving length byte
ST_RECV_DATA    - Receiving data bytes
ST_PROCESS      - Processing command, preparing response
ST_SEND_LENGTH  - Sending response length
ST_SEND_DATA    - Sending response data
ST_WAIT_DONE    - Cleanup after transaction
```

### PRAM (Parameter RAM)

- 256 bytes of non-volatile storage
- Stores system configuration (boot volume, clock settings, etc.)
- In this implementation, stored in internal registers
- Key locations:
  - 0x08: Boot volume reference
  - 0x09: Startup disk settings
  - 0x10-0xFF: User preferences and system settings

### Real-Time Clock

- 32-bit seconds counter
- Counts from epoch (January 1, 1904 for classic Mac OS)
- Increments at ~1Hz using clock divider
- Can be read/written via CUDA commands

### ADB Interface

The ADB (Apple Desktop Bus) interface is simplified in this implementation:

- Single bidirectional data line
- Protocol uses specific timing for attention, sync, and bit cells
- CUDA acts as ADB controller
- Devices (keyboard, mouse) are ADB targets

For a complete implementation, you would need:
- ADB bit timing generation (100μs bit cells)
- Attention signal (800μs low)
- Service request monitoring
- Device polling state machine

### I2C/DFAC Interface

DFAC (Digital-to-Frequency Audio Converter) uses I2C protocol:

- SCL (clock) on Port B bit 7
- SDA (data) on Port B bit 6
- Pull-up resistors required externally
- Used for audio control in some Macs

## Differences from MAME Implementation

**MAME Approach**:
- Emulates actual 68HC05 CPU execution
- Runs real CUDA firmware ROM dumps
- Cycle-accurate timing
- Complete instruction set emulation

**This Verilog Approach**:
- Functional emulation at protocol level
- Implements same external behavior
- Simplified internal state machine
- No CPU emulation - direct logic

**Trade-offs**:
- ✓ Faster simulation
- ✓ Easier to understand
- ✓ Suitable for FPGA implementation
- ✗ Not cycle-accurate with original
- ✗ Won't run ROM diagnostics
- ✗ May miss edge cases in firmware

## Integration Guide

### Connecting to Mac LC FPGA Core

```systemverilog
// In your top-level Mac LC module:

cuda cuda_inst (
    .clk(clk_50mhz),
    .clk8_en(clk_8mhz_en),
    .reset(system_reset),
    
    // VIA Port B
    .via_pb_i(via_portb_in),
    .cuda_pb_o(cuda_portb_out),
    .cuda_pb_oe(cuda_portb_oe),
    
    // Combine VIA and CUDA outputs
    .via_sr_active(via_shift_active),
    .via_sr_out(via_shift_out),
    .via_sr_data_out(via_sr_out_data),
    .cuda_sr_data_in(cuda_sr_in_data),
    .cuda_sr_trigger(cuda_sr_int),
    
    // Shift register clock/data
    .cuda_cb1(cuda_cb1_out),
    .cuda_cb1_oe(cuda_cb1_oe),
    .cuda_cb2(cuda_cb2_out),
    .cuda_cb2_oe(cuda_cb2_oe),
    
    // ADB (connect to your ADB transceiver)
    .adb_data_in(adb_in),
    .adb_data_out(adb_out),
    .adb_data_oe(adb_oe),
    
    // I2C
    .iic_sda(iic_sda),
    .iic_scl(iic_scl),
    
    // System control
    .reset_out(cuda_reset_680x0),
    .nmi_out(cuda_nmi),
    .dfac_latch(dfac_latch)
);

// Combine Port B outputs
assign via_portb_in = (via_portb_oe & via_portb_out) |
                      (cuda_portb_oe & cuda_portb_out) |
                      (~(via_portb_oe | cuda_portb_oe) & 8'hFF);
```

### Clock Requirements

- Main clock: Any frequency (50MHz recommended)
- `clk8_en`: Enable pulse at ~8MHz (divide main clock)
  - CUDA protocol timing is not critical
  - 6-10MHz range acceptable

Example clock divider:
```systemverilog
reg [2:0] clk_div;
always @(posedge clk_50mhz) begin
    clk_div <= clk_div + 1'd1;
end
assign clk8_en = (clk_div == 3'd0);  // 50/8 = 6.25MHz
```

## Debugging Tips

### Common Issues

**1. TREQ Never Asserts**
- Check that CUDA is getting clk8_en pulses
- Verify reset is properly released
- Check state machine isn't stuck

**2. No Response to Commands**
- Verify TIP is being asserted by host
- Check shift register `via_sr_active` signal
- Monitor state machine progression

**3. Garbled Data**
- Check clock enable frequency
- Verify shift register timing
- Ensure proper bit order (MSB first)

### Simulation Waveform Analysis

Key signals to monitor:
```
via_pb_i[3]      - TIP (transaction start)
cuda_pb_o[1]     - TREQ (ready indicator)  
cuda_pb_o[2]     - BYTEACK (byte acknowledge)
via_sr_active    - Shift register active
cuda_cb1         - Shift clock output
state            - Internal state machine
```

Expected sequence:
1. TIP rises
2. TREQ goes high (busy)
3. Command bytes shift in
4. State progresses through states
5. TREQ goes low (ready)
6. Response bytes shift out
7. TIP falls

## Testing

The included testbench (`cuda_tb.sv`) provides:
- Basic protocol verification
- Command/response testing
- PRAM read/write tests
- Version query test

Run with:
```bash
iverilog -g2012 -o cuda_sim cuda_complete.sv cuda_tb.sv
vvp cuda_sim
gtkwave cuda_tb.vcd
```

## Future Enhancements

### High Priority
1. **Complete ADB Implementation**
   - Bit-level timing generation
   - Device polling
   - Service request handling

2. **I2C Master Controller**
   - Start/stop conditions
   - Byte transmission
   - ACK/NACK handling

3. **Power Management**
   - Soft power control
   - Power switch monitoring
   - Reset sequencing

### Nice to Have
4. **Autopoll Support**
   - Periodic ADB device polling
   - Async event generation
   - Proper interrupt timing

5. **PRAM Checksums**
   - Validate PRAM on startup
   - Auto-repair corrupted data
   - Proper default values

6. **Enhanced Compatibility**
   - Test with multiple ROM versions
   - Handle edge cases
   - Improve timing accuracy

## References

- **MAME Source**: `mame/src/devices/machine/cuda.cpp`
- **68HC05E1 Datasheet**: Motorola MC68HC05E1 Family
- **Inside Macintosh**: Apple Tech Publications
- **Mac ROM Disassemblies**: Various reverse engineering docs

## Version History

- **v1.0** (2024): Initial implementation
  - Basic protocol support
  - PRAM read/write
  - RTC support
  - Version queries

## License

Based on MAME's cuda.cpp (BSD-3-Clause)
This SystemVerilog implementation follows the same license.
