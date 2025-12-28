# Mac LC VIA/Egret Boot Sequence Testbench

This testbench reproduces the exact Egret-to-VIA communication sequence captured from MAME during Mac LC boot. Use it to verify your FPGA Mac LC core's VIA and Egret implementation.

## Files Included

- **maclc_via_egret_boot_tb.sv** - SystemVerilog testbench with boot sequence
- **generate_testbench.py** - Python script to analyze MAME logs and generate stimulus
- **Makefile** - Build and run simulation
- **MAME_BOOT_SEQUENCE_ANALYSIS.md** - Detailed analysis of the boot sequence

## Quick Start

### 1. Prepare Your VIA Module

Edit `maclc_via_egret_boot_tb.sv` and uncomment/modify the DUT instantiation around line 54:

```systemverilog
via_6522 dut (
    .clk(clk_16mhz),
    .reset_n(reset_n),
    .addr(via_addr[3:0]),
    .data_in(via_data_in),
    .data_out(via_data_out),
    .cs_n(via_cs_n),
    .rw(via_rw),
    .ca1(egret_via_clock),
    .ca2(),
    .cb1(),
    .cb2(egret_via_data),
    .irq_n(via_irq_n)
);
```

Adjust port names to match your VIA implementation.

### 2. Update Makefile

Edit the `Makefile` and add your VIA source files:

```makefile
DUT_SRC = ../rtl/via_6522.sv ../rtl/via_timer.sv
```

### 3. Run Simulation

```bash
# With Verilator (recommended)
make sim SIM=verilator

# Or with Icarus Verilog
make sim SIM=iverilog
```

### 4. View Waveforms

```bash
make wave
```

This opens GTKWave with the generated VCD file.

## Understanding the Test Sequence

The testbench simulates 9 key steps of the Mac LC boot:

### Step 0: Power-On
- All signals at 0
- 68020 held in reset

### Step 1: XCVR_SESSION Assertion
- Egret sets `XCVR_SESSION = 1`
- Egret sets `VIA_CLOCK = 1` at the same time
- **CRITICAL**: These happen simultaneously

### Step 2: 68020 Reset Release
- Egret releases 68020 from reset
- PRAM has been loaded

### Step 3: First Byte Transmission
- 8 clock pulses with `VIA_DATA = 0`
- Each pulse: `CLOCK = 1→0` (falling edge)
- VIA CA1 should trigger on falling edge

### Step 4: XCVR_SESSION De-assertion
- `XCVR_SESSION = 0`
- Marks end of transaction

### Step 5: Second Byte
- Another 8 clock pulses

### Step 6: Data Byte with Start Bit
- Start bit: `VIA_DATA = 1`
- 7 data bits
- Stop bit: `VIA_DATA = 1`

### Step 7: XCVR_SESSION Re-assertion
- Start of new transaction

### Step 8: 68020 VIA Access
- Simulates 68020 reading IFR register
- IFR should clear on second read

### Step 9: Continue Boot
- More data bytes transmitted

## Key Signals to Monitor

### Egret Outputs (Stimulus)
- `egret_via_clock` - Connected to VIA CA1
- `egret_via_data` - Connected to VIA CB2  
- `egret_xcvr_session` - Transaction framing
- `egret_reset_n` - 68020 reset control

### VIA Outputs (Monitor These)
- `via_irq_n` - Interrupt request (active low)
- `via_data_out` - Data bus output
- Internal `IFR` register - Should match expected patterns

## Expected VIA IFR Values

The testbench checks for these IFR patterns:

- `0x02` - CA1 interrupt flag only
- `0x12` - CA1 + interrupt enabled  
- `0x16` - CA1 + CB1 + enabled
- `0x1A` - CA1 + CB2 + enabled
- `0x1E` - CA1 + CB1 + CB2 + enabled

IFR bit meanings:
- Bit 1 (0x02) - CA1 (VIA_CLOCK edge detected)
- Bit 3 (0x08) - CB2 (VIA_DATA changed)
- Bit 4 (0x10) - CB1 (shift register ready)
- Bit 7 (0x80) - Interrupt enable

## Analyzing Real MAME Logs

If you have MAME logs from the real Mac LC, you can generate exact stimulus:

```bash
# Generate stimulus from your logs
python3 generate_testbench.py handshake.log > generated_stimulus.sv

# Analyze patterns
python3 generate_testbench.py handshake.log
```

The script will show:
- Total transitions
- Byte transmission sequences
- XCVR_SESSION patterns
- SystemVerilog code you can copy into the testbench

## Common Issues and Debug Tips

### Issue: VIA CA1 not triggering
- Check that CA1 is connected to `egret_via_clock`
- Verify CA1 edge detection (should be falling edge)
- Look for IFR bit 1 (0x02) setting

### Issue: IFR not clearing
- Ensure IFR reads are working
- Second read of IFR should clear the flags
- Check address decode for register 0x0D (IFR)

### Issue: Shift register not working
- Verify CB1 is connected to shift clock
- Check shift register mode configuration
- CB2 should read VIA_DATA
- Mode should be "shift in under external clock"

### Issue: Clock domain crossing problems
- Egret runs at ~2 MHz
- 68020 runs at 16 MHz
- Ensure proper synchronization between domains
- Add FFs for signal crossing if needed

### Issue: XCVR_SESSION timing
- Must be stable BEFORE first clock pulse
- Check that it asserts before VIA_CLOCK starts toggling
- Should remain stable during byte transmission

## Waveform Markers to Look For

When viewing in GTKWave, add these signals and look for:

1. **Power-on** - All signals low
2. **XCVR rise** - XCVR_SESSION goes high with VIA_CLOCK
3. **Clock pulses** - Regular 1→0→1→0 pattern on VIA_CLOCK
4. **IFR flags** - Should set on clock edges
5. **Data changes** - VIA_DATA transitions between clock pulses
6. **CPU reads** - VIA chip select and read strobes

## Integration with Your FPGA Core

To integrate this with your Mac LC FPGA core:

1. **Connect Egret Microcontroller**
   - Use actual 68HC05 ROM or HLE implementation
   - Wire Port B outputs to testbench signals

2. **Connect VIA**
   - Wire VIA CA1 to Egret's VIA_CLOCK
   - Wire VIA CB2 to Egret's VIA_DATA
   - Ensure CB1 gets shift register clock

3. **Add Clock Domain Crossing**
   - Synchronize Egret signals to 68020 clock domain
   - Use double-FF synchronizers

4. **Test Boot Sequence**
   - Run this testbench first to verify VIA
   - Then test with full Mac LC core
   - Compare to real MAME boot logs

## Next Steps

1. Run testbench and verify VIA behavior
2. Compare IFR patterns to expected values
3. Check timing in waveform viewer
4. Integrate verified VIA into Mac LC core
5. Test full boot sequence on FPGA

## References

- MAME source: `src/mame/apple/egret.cpp`
- VIA datasheet: R65NC22 Versatile Interface Adapter
- Mac LC schematics (if available)
- This analysis: `MAME_BOOT_SEQUENCE_ANALYSIS.md`

## Support

If you find issues or have questions:
1. Check waveforms match expected patterns
2. Verify IFR register behavior
3. Review MAME_BOOT_SEQUENCE_ANALYSIS.md
4. Compare your timing to MAME logs

Good luck debugging your Mac LC core!
