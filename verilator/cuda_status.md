# CUDA/VIA Interface Status

## Completed Fixes

### 1. CB2 Timing (cuda_maclc.sv)
CUDA now outputs CB2 data on CB1 falling edge (instead of rising edge), giving proper setup time for VIA to sample. This matches the MAME reference implementation.

### 2. ST_WAIT_SR_READ State (cuda_maclc.sv)
Added proper handshaking where CUDA waits for ROM to read VIA SR before clocking out response data. This prevents CUDA from sending data before the VIA is ready to receive.

### 3. TREQ Open-Drain Behavior (dataController_top.sv)
Fixed Port B logic so CUDA can pull TREQ low even when VIA has the bit configured as output. This implements proper wired-AND behavior for the open-drain TREQ signal.

### 4. TIP Polarity (cuda_maclc.sv)
Fixed CUDA to detect TIP falling edge (1->0) for transaction start, not rising edge. TIP is active-low in the Apple CUDA protocol.

### 5. VIA PRB Initialization (via6522.sv)
Changed VIA's Port B Output Register reset value from 0x00 to 0xFF to prevent false TIP assertion at startup. This stops CUDA from falsely detecting a transaction start at power-on.

### 6. CUDA TREQ Initialization (cuda_maclc.sv)
Fixed treq_reg to start de-asserted (0) in idle state, and asserted (1) during attention and acknowledgment phases.

### 7. CUDA Attention Signal (cuda_maclc.sv)
Added ST_ATTENTION state where CUDA asserts TREQ at startup to signal its presence to the ROM. This is the standard CUDA power-on behavior.

## State Machine Updates

The CUDA state machine now has these states:
- ST_ATTENTION (0) - Startup: assert TREQ to signal presence
- ST_IDLE (1) - Wait for TIP falling edge
- ST_WAIT_CMD (2) - Wait for command byte
- ST_SHIFT_IN_CMD (3) - Clock in command
- ST_WAIT_LENGTH (4) - Wait for length byte
- ST_SHIFT_IN_LENGTH (5) - Clock in length
- ST_SHIFT_IN_DATA (6) - Clock in data bytes
- ST_PROCESS_CMD (7) - Process received command
- ST_PREPARE_RESPONSE (8) - Prepare response data
- ST_WAIT_SR_READ (9) - Wait for ROM to read VIA SR
- ST_SHIFT_OUT_LENGTH (10) - Clock out response length
- ST_SHIFT_OUT_DATA (11) - Clock out response data
- ST_COMPLETE (12) - Transaction complete
- ST_WAIT_TIP_RISE (13) - Wait for TIP to be released

## Current Status

The ROM now correctly sees TREQ=0 (active) during CUDA attention phase. However, the ROM doesn't respond by asserting TIP low to acknowledge.

Analysis shows the ROM is performing I2C communication first (toggling bits 4-5 in Port B writes with values 0xd9/0xe9/0xf9) and appears to be stuck in an I2C loop before reaching CUDA initialization code.

## Port B Bit Assignments (Mac LC)

- Bit 0: 5V Sense (input)
- Bit 1: TREQ - Transfer Request from CUDA (input, active LOW)
- Bit 2: BYTEACK - Byte Acknowledge (bidirectional)
- Bit 3: TIP - Transaction In Progress from CPU (output, active LOW)
- Bit 4: VIA_CLK / I2C related
- Bit 5: VIA_DATA / I2C related
- Bit 6: I2C SDA
- Bit 7: I2C SCL

## Next Steps

1. Investigate I2C interface - ROM may be waiting for I2C response before proceeding to CUDA
2. Check if additional hardware initialization is required
3. Verify CUDA protocol matches Mac LC specific requirements (vs other Mac models)

## Files Modified

- `rtl/cuda_maclc.sv` - Major state machine updates, timing fixes, polarity corrections
- `rtl/via6522.sv` - Added debugging, fixed PRB initialization to 0xFF
- `rtl/dataController_top.sv` - Added debugging, fixed TREQ open-drain behavior
