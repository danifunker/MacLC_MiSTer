# Egret Transaction Protocol — TODO

## Status: TIP Race Condition FIXED, Transaction Completion BROKEN

### What's Fixed (2026-03-22)
- **TIP gate in egret_wrapper.sv**: Holds TIP=HIGH from Egret's perspective for 4096 Egret cycles after 68020 reset release, then passes real value through. This lets Egret see the TIP falling edge even though the 68020 asserts TIP ~1240 cycles before Egret enters its idle loop (~3300 cycles after reset release).
- Egret now detects TIP, asserts TREQ, and SR byte transfers occur.

### What's Broken: Transaction Completion
The 68020 starts Egret transactions but they never complete. The CPU loops through the transaction handler at `$A4A2B8-$A4A330` and timeout poll at `$A4A442-$A4A448`, retrying endlessly.

**Evidence from 350-frame simulation:**
- 1628 TIP assertion/deassert cycles (transaction attempts)
- 7322 SR shift completions (~4.5 bytes per attempt)
- 1629 TREQ toggles (Egret responds to each attempt)
- TREQ IS visible in ORB reads (0x40, bit 3 = 0, asserted)
- SR IRQ fires (IFR bit 2 set) but VIA IER = 0x00 (all interrupts disabled)

### Investigation Leads

#### 1. VIA IER Always 0x00
The ROM's VIA register test sequence always ends with IER cleared to 0x00:
```
IER SET 0xFF → mask = 0x7F
IER CLEAR 0x01 → mask = 0x7E
IER CLEAR 0x7F → mask = 0x00  ← clears everything
IER SET 0x80 → mask = 0x00    ← no-op (bit7=1, bits6-0=0)
```
This repeats for each VIA test pass. No subsequent IER write re-enables SR interrupts.

**Question:** Does the Mac LC ROM use polled SR (reading IFR directly) or interrupt-driven SR? If interrupt-driven, why is IER never re-enabled?

**Possible cause:** The ROM initialization code that enables IER may depend on a prior step completing successfully (like an Egret transaction), creating a chicken-and-egg problem.

#### 2. BYTEACK (TACK) Toggling
Per the Linux via-cuda.c driver, TACK must be **toggled** for each byte:
- Host writes SR, toggles TACK
- Device processes byte, asserts TREQ when ready for next

The ORB reads during transactions show BYTEACK values but it's unclear if toggling happens correctly. Need to trace individual ORB WRITES (not reads) during a single transaction to verify TACK toggle timing.

#### 3. Egret TREQ Timeout
TREQ is asserted at Egret cycle ~1084329 and deasserted at ~1090427 (6098 Egret cycles = ~1.5ms). If the 68020's dbra loop takes longer than 1.5ms, it misses the TREQ window.

**Check:** Is the dbra loop too long for Egret's TREQ hold time?

#### 4. Egret Timing Requirements (from Linux driver)
```
EGRET_SESSION_DELAY      = 450 µs  (interrupt to session start)
EGRET_TACK_ASSERTED_DELAY = 300 µs  (TACK pulse duration)
EGRET_TACK_NEGATED_DELAY  = 400 µs  (gap before next byte)
```
These delays may not match our clock ratios (68020 at 8MHz, Egret at 4MHz).

#### 5. Collision Detection
The Linux driver detects "collisions" when both host and device start transactions simultaneously. If Egret asserts TREQ at the wrong time, the ROM may interpret it as a collision and abort.

### Files Involved
- `rtl/egret/egret_wrapper.sv` — TIP gate (fixed), TIP sync, pb_external mapping
- `rtl/dataController_top.sv` — TIP latch, VIA PB wiring, TREQ open-drain logic
- `rtl/via6522.sv` — VIA shift register, IER/IFR, ORB read logic

### How to Debug Next
1. Add IFR read logging to via6522.sv to see if the ROM polls IFR directly
2. Trace ORB WRITES (not reads) during one complete transaction attempt to verify BYTEACK toggling
3. Check if the ROM reads IFR at `$50F01A00` anywhere in the cpu_trace.log
4. Compare Egret TREQ hold time vs 68020 dbra loop duration
5. Consider adding a `$display` for every VIA register write during the transaction window (times 13132000-13134000)
