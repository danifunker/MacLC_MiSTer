# VIA6522 with Integrated RTC - Integration Notes

## Overview
The VIA6522 module now includes integrated Apple 343-0042-B RTC support. The RTC connects directly to Port B pins 0-2.

## Key Changes to VIA Module

### 1. New Port (Line 63)
```systemverilog
input  wire [32:0] rtc_timestamp   // Unix timestamp for RTC initialization
```

### 2. RTC Pin Mapping (Port B)
- **PB0**: RTC CE (Chip Enable, active low)
- **PB1**: RTC CLK (Serial Clock)
- **PB2**: RTC DATA (Bidirectional)

### 3. Port B Input Modification (Lines 547-551)
```systemverilog
// Modified port_b_c to include RTC data input
// When PB2 is input (DDRB[2]=0), read from RTC
port_b_c[7:3] <= port_b_i[7:3];
port_b_c[2] <= pio_i_ddrb[2] ? port_b_i[2] : rtc_data_i;
port_b_c[1:0] <= port_b_i[1:0];
```

This is the critical change - when Port B bit 2 is configured as input (DDRB[2]=0), the VIA reads from the RTC instead of the external port_b_i[2] signal.

## Integration in Your System

### Option 1: Replace Existing VIA Module
Simply replace your existing `via6522.sv` with the new `via6522_with_rtc.sv` file.

**Update instantiation to include RTC timestamp:**
```systemverilog
via6522 via_inst (
    .clock(clk),
    .rising(phi2_rising),
    .falling(phi2_falling),
    .reset(reset),
    
    // ... existing connections ...
    
    .rtc_timestamp(rtc_timestamp_input)  // NEW: Add this
);
```

### Option 2: Keep Separate (Alternative)
If you prefer to keep the RTC as a separate module, you can:

1. Use the original `rtc.v` module
2. Modify Port B input multiplexing in your top-level:

```systemverilog
wire [7:0] via_port_b_in_modified;
wire       rtc_data_out;

// RTC instance
rtc rtc_inst (
    .clk(clk),
    .reset(reset),
    .timestamp(rtc_timestamp),
    ._cs(via_port_b_out[0]),
    .ck(via_port_b_out[1]),
    .dat_i(via_port_b_out[2]),
    .dat_o(rtc_data_out)
);

// Multiplex RTC data into Port B input
assign via_port_b_in_modified[7:3] = via_port_b_in[7:3];
assign via_port_b_in_modified[2] = via_port_b_ddr[2] ? via_port_b_in[2] : rtc_data_out;
assign via_port_b_in_modified[1:0] = via_port_b_in[1:0];

via6522 via_inst (
    // ...
    .port_b_i(via_port_b_in_modified),  // Use modified input
    // ...
);
```

## Clock Frequency Configuration

The RTC seconds counter assumes a **32MHz** system clock by default (line 289):
```systemverilog
if (rtc_clocktoseconds == 25'd31999999) begin  // 32MHz
```

**If your system clock is different**, update this value:
- 25MHz: `25'd24999999`
- 31.3344MHz: `25'd31334399`
- 16MHz: `25'd15999999`

Or make it parameterizable:
```systemverilog
module via6522 #(
    parameter CLOCK_FREQ = 32000000  // Hz
) (
    // ...
);

// In the RTC section:
if (rtc_clocktoseconds == (CLOCK_FREQ - 1)) begin
```

## PRAM Access (Advanced)

If you need to backup/restore PRAM externally:

```systemverilog
// Add to module ports:
output wire [7:0] rtc_pram_data,
input  wire [7:0] rtc_pram_addr,
input  wire       rtc_pram_we,
input  wire [7:0] rtc_pram_din

// In module:
assign rtc_pram_data = rtc_pram[rtc_pram_addr];

always @(posedge clock) begin
    if (rtc_pram_we && !reset)
        rtc_pram[rtc_pram_addr] <= rtc_pram_din;
end
```

## Testing

### Basic Functionality Test
1. Write seconds register via VIA Port B
2. Read back seconds register
3. Verify seconds increment every second
4. Test PRAM read/write at standard addresses (0x08-0x0B, 0x10-0x1F)
5. Test extended PRAM (commands 0x38-0x3F)

### Port B Direction Test
```systemverilog
// Configure PB0-1 as outputs, PB2 as input
VIA_DDRB = 8'b00000011;

// Send RTC command (PB2 must float high)
VIA_PRB = 8'b00000010;  // CE=0, CLK=1
// ... clock data in/out via PB2 ...
```

## Common Issues

**RTC not responding:**
- Verify `rtc_timestamp` is connected
- Check that PB2 direction is set correctly (input for read operations)
- Ensure clock frequency divisor matches your system

**Time not incrementing:**
- Check clock frequency divisor (line 289)
- Verify `rtc_test_mode` is not set
- Confirm reset is deasserted

**PRAM reads incorrect:**
- Verify extended command format for addresses > 0x1F
- Check write-protect bit not accidentally set
- Ensure proper command/address sequencing

## Compatibility

This implementation is compatible with:
- Mac LC ROM
- Mac LC II ROM  
- Classic II ROM
- Color Classic ROM

The CS debounce logic handles the Mac LC ROM's DDRB toggle behavior correctly.
