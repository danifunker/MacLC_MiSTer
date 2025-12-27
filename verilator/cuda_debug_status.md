# CUDA Debug Status

## Date: 2025-12-26 (Updated)

## Summary

The CUDA/VIA serial communication is now partially working. Single-byte transactions complete successfully, but the ROM is stuck in a retry loop sending single-byte probe packets.

## What's Working

### CUDA Startup Handshake
- CUDA asserts TREQ at reset/startup
- ROM sees TREQ=0 (asserted), acknowledges by asserting TIP
- CUDA sends startup response (PKT_ERROR = 0x02)
- ROM receives the byte successfully

### VIA Shift Register
- External clock mode (mode 7) works correctly
- CB1 rising edges properly shift data
- IFR SR bit is set after 8 clocks
- Both directions (CUDA→ROM and ROM→CUDA) work

### Byte Transmission
- CUDA can send 8-bit bytes to ROM via CB2
- ROM can send 8-bit bytes to CUDA via SR
- VIA counts CB1 edges correctly
- IFR interrupt fires after shift complete

## What's Still Broken

### Multi-Byte Packets
The ROM is only sending 1-byte packets instead of multi-byte packets like AUTOPOLL [0x01, 0x01, 0x00].

**Observed Sequence:**
1. ROM asserts TIP (ORB = 0xdf, PB5=0)
2. ROM writes SR = 0x01 (first byte)
3. CUDA clocks CB1 8 times via external clock
4. VIA sets IFR SR bit (shift complete)
5. ROM toggles BYTEACK
6. ROM releases TIP (ORB = 0xef, PB5=1) - PROBLEM!
7. CUDA processes incomplete 1-byte packet
8. CUDA responds with PKT_ERROR "Unknown CUDA cmd"
9. Loop repeats indefinitely

**Expected Sequence:**
1. ROM asserts TIP
2. ROM writes byte 1 to SR
3. Wait for shift complete (poll IFR)
4. ROM writes byte 2 to SR
5. Wait for shift complete
6. ROM writes byte 3 to SR
7. Wait for shift complete
8. ROM releases TIP
9. CUDA processes complete packet

### Boot Progress
Boot is blocked at a white screen. The ROM is stuck waiting for CUDA communication to succeed before proceeding.

## Debug Output Analysis

From simulation log:
```
CUDA: RECV_WAIT byte[ 0] = 0x01
...
CUDA: RECV_WAIT->PROCESS: long timeout, recv_count= 1, sr_write_seen=1
CUDA: PROCESS packet - type=0x01 cmd=0x00 data[0]=0x00 cnt= 1
CUDA: Unknown CUDA cmd 0x00
```

CUDA receives only 1 byte (0x01) before timeout. It treats this as type=0x01, cmd=0x00, which is an unknown command.

## Possible Causes

1. **ROM Timing** - ROM may be timing out waiting for VIA IFR before we set it
2. **TREQ Collision** - ROM may interpret de-asserted TREQ as collision
3. **VIA IRQ** - If ROM uses interrupt-driven I/O, VIA IRQ might not be wired correctly
4. **Protocol Mismatch** - ROM might use different handshake than expected

## Files Modified Today

### /rtl/cuda_maclc.sv
- Added `via_sr_ext_clk` input to wait for VIA external clock mode
- Added `sr_write_seen` condition for RECV_WAIT clocking
- Fixed bit_counter reset in ST_RECV_BYTE

### /rtl/via6522.sv
- Disabled verbose debug output (ORB READ, IFR READ, SHIFT active)
- VIA shift register works correctly

### /rtl/dataController_top.sv
- Added via_sr_ext_clk connection to CUDA
- Disabled verbose PortB READ logging

### /rtl/pseudovia.sv
- Disabled verbose access logging

## Debug Commands

```bash
# Run simulation with screenshot
timeout 300 ./obj_dir/Vemu --screenshot 360 --stop-at-frame 365 2>&1 | tee sim_output.log

# Check CUDA state transitions
grep -E "CUDA:.*state" sim_output.log

# Check byte reception
grep "RECV_WAIT byte" sim_output.log

# Check VIA shift complete
grep "SR shift complete" sim_output.log
```

## Next Steps

1. Investigate why ROM releases TIP after just 1 byte
2. Check if VIA IRQ is connected properly
3. Consider if ROM expects different BYTEACK/TREQ handshake
4. Look at MAME source for exact protocol timing

## Screenshot

Frame 360 shows blank white screen - boot is blocked waiting for CUDA.
