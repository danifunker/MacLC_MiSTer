# Boot Problems Log

## Current Status (2026-04-06)

Boot reaches **Stage 7e (SetUpTimeK)** successfully and completes timing calibration.
The Egret protocol is fully working (68 transactions, memory test visible at frame 350).
Boot then stalls in the **AppleTalk/LocalTalk driver** serial protocol loop at frame 360+.

**Fix applied:** See "AppleTalk Boot Hang" section below.

---

## AppleTalk Boot Hang — 2026-04-06

### Problem

Boot hangs at frame 360+ in an infinite SCC serial loop at ROM address `0xA49F00`.
The CPU endlessly writes bytes to SCC TX, polls for TX completion, and loops back.

### Root Cause

The LocalTalk (atlk) driver loads unconditionally during Boot3.a and performs a
self-test by writing WR14=0x11 to the SCC (BRG enable + local loopback). With the
SCC's internal loopback active, TX data echoes back to RX perfectly, so:

1. The self-test passes — driver thinks LocalTalk hardware is present
2. Driver enters an LLAP protocol loop trying to establish a network connection
3. With loopback, every frame echoes back, creating an infinite loop

Additionally, `SPConfig` (XPRAM byte 0x13) defaulted to 0x00. The ROM checks
`SPConfig & 0x0F`: zero means "AppleTalk active" (it's the default boot state).
This prevented the `emAppleTalkInactiveOnBoot` flag from being set.

### Fix (commit 83c226c)

Two changes applied:

1. **PRAM:** Set XPRAM 0x13 = 0x22 (both ports useAsync) in `egret_behavioral.sv`
   and `cuda_maclc.sv`. With `SPConfig & 0x0F = 2`, AppleTalk is flagged inactive
   on boot and never loaded.

2. **SCC:** Disabled local loopback in `rtl/scc.v` — RX always reads from the
   external pin, ignoring WR14 bit 4. The loopback self-test fails harmlessly and
   the driver skips LocalTalk initialization.

### PRAM Fixes (commit a516d0c)

Also fixed incorrect PRAM defaults that caused InitUtil to reinitialize XPRAM on
every boot:

- Added extended PRAM validity signature 'NuMc' at bytes 0x0C-0x0F
- Set XPRAM 0x10 = 0xA8 (SPValid) instead of incorrect 0x02
- Removed dead `rtl/rtc.v` (legacy Mac Plus serial RTC, unused in Mac LC)

---

## Egret Behavioral Boot Problem — 2026-03-30 (RESOLVED)

### Summary

## What Works

- Egret releases 68020 from reset after boot delay
- 68020 boots, runs RAM test (frames 0-17), memory clear (frames 19-32), XOR test (frames 33-123)
- Host sends AUTOPOLL command [0x01, 0x01, 0x00] — Egret receives all 3 bytes correctly
- Egret processes the command and builds response [PKT_ERROR=0x02, 0x00]
- SEND_NOTIFY (8 dummy CB1 edges) triggers VIA IFR[2], host wakes up and sees TREQ
- Host reconfigures VIA to shift-in mode, re-asserts TIP
- Response bytes are clocked correctly (verified via VIA SR READ traces)

## Where It Stalls

After the AUTOPOLL response is delivered, the host gets stuck in a tight polling loop
at 0xA14E6A:

```
A14E6A: btst #2, ($1A00,A1)   ; poll VIA IFR bit 2 (SR completion)
A14E70: beq  $A14E6A           ; loop if IFR[2] not set
A14E72: bset #5, (A1)          ; set ORB bit 5 (TACK toggle)
        ... handler via jmp (A5) ...
```

The host toggles TACK (ORB bit 5) after each byte and polls IFR[2] for the Egret's
response. After the last byte, the host gets stuck because either:
1. IFR[2] is never set (no more CB1 edges), or
2. IFR[2] is set but never cleared (handler reads ORB, not SR, when TREQ=0)

## Key Protocol Observations

### TACK Handshaking (Egret-specific)

The Mac LC ROM uses **TACK (byteack) handshaking** for the Egret protocol — this is
different from CUDA which doesn't use TACK. After reading each response byte from the
VIA shift register:

1. Host reads SR (clears IFR[2])
2. Host checks TREQ in ORB
3. Host toggles TACK (ORB bit 5)
4. Host polls IFR[2] waiting for Egret to respond with 8 CB1 edges
5. Repeat

The behavioral Egret must respond to TACK toggles. The CUDA reference (`cuda_maclc.sv`)
ignores TACK entirely because CUDA uses a different protocol.

### SEND_NOTIFY Required

The host does NOT continuously poll ORB for TREQ. Instead, after sending a command,
it polls IFR[2]. The Egret must clock 8 dummy CB1 edges (SEND_NOTIFY) to trigger IFR[2]
and wake the host. Without SEND_NOTIFY, the host never discovers TREQ and the Egret
times out in SEND_TREQ.

### SR Read Timing Problem

The host reads SR very fast — between the 8th CB1 **rising** edge (which triggers IFR[2])
and the 8th CB1 **falling** edge (32 clk8_en ticks later). The Egret transitions from
SEND_CLOCK to SEND_DONE at the falling edge, so `via_sr_read` pulse detection in
SEND_DONE misses it. TACK toggle detection works better because TACK changes later
(after the host has processed the ISR and returned to its main loop).

### End-of-Transaction: The Unsolved Problem

After the last response byte, the host toggles TACK and polls IFR[2]. The Egret must
provide 8 CB1 edges (a "dummy byte") so IFR[2] fires. But the host's handler for
this dummy byte behaves differently depending on TREQ:

- **TREQ=1**: Handler reads SR (clears IFR[2]), toggles TACK, expects more bytes
- **TREQ=0**: Handler reads ORB (does NOT read SR), IFR[2] stays set → infinite loop

This creates a catch-22:
- If TREQ=0 during dummy: IFR[2] never cleared, host loops forever
- If TREQ=1 during dummy: host thinks there are more data bytes

## What Was Tried This Session

### Attempt 1: Remove SEND_NOTIFY
**Hypothesis:** Host polls ORB for TREQ, not IFR[2].
**Result:** 0 transactions. Host never discovers TREQ. Egret times out in SEND_TREQ.
**Conclusion:** SEND_NOTIFY is required for Egret protocol.

### Attempt 2: Remove dummy byte after last response byte
**Hypothesis:** Host checks TREQ after last SR read, deasserts TIP without needing more CB1 edges.
**Result:** 1 transaction (AUTOPOLL). Host stuck polling IFR[2] at A14E6A — IFR[2] never set because no more CB1 edges.
**Conclusion:** Host always toggles TACK and polls IFR[2] after each byte, including the last.

### Attempt 3: Dummy byte + deassert TREQ at 8th rising edge of last byte
**Hypothesis:** Deassert TREQ early so host sees TREQ=0 when reading ORB after the last real byte's IFR[2]. Host then deasserts TIP.
**Result:** 1 transaction. Host still stuck. Host reads SR for last byte, but since TREQ is deasserted, the handler path doesn't lead to TIP deassertion (it toggles TACK and polls IFR[2] regardless).
**Conclusion:** Host always enters the TACK/IFR[2] loop after reading a byte, regardless of TREQ state.

### Attempt 4: Switch from SR-read to TACK detection in SEND_DONE
**Hypothesis:** Use TACK toggle to trigger next byte instead of via_sr_read (which has timing issues).
**Result:** 1 transaction. TACK detection worked for byte[0]→byte[1] transition. But after dummy byte, IFR[2] stays set (handler doesn't read SR when TREQ=0), causing infinite loop.
**Conclusion:** TACK detection works for inter-byte handshaking, but the end-of-transaction problem remains.

### Attempt 5: Deassert TREQ only when starting dummy (after last TACK) — NOT YET TESTED
**Hypothesis:** Keep TREQ=1 through the last real byte. After TACK toggle, deassert TREQ and clock dummy. Host handler for dummy sees TREQ=0 in ORB and deasserts TIP.
**Current state of code.** This is the next thing to test.

## What Was Working Before This Session

According to the conversation summary, the previous session had a version that completed
1563 GET_PRAM transactions (though stuck in a retry loop). That version used:
- SEND_NOTIFY for IFR[2] notification
- `via_sr_read` detection in SEND_DONE (with 50000-tick timeout fallback)
- Dummy byte after last response byte
- TREQ deasserted after SR read timeout

The exact mechanism that made it work for multiple transactions is unclear — it may have
relied on the 50000-tick timeout path creating specific timing that satisfied the host.

## Resolution

The Egret protocol issues were resolved in earlier sessions. The behavioral Egret now
uses the correct Apple protocol (xcvrSes/viaFull/sysSes) and completes 68+ transactions
successfully. Boot reaches the memory test pattern at frame 350.

## File References

- `rtl/egret_behavioral.sv` — the behavioral Egret (file being modified)
- `rtl/cuda_maclc.sv` — working CUDA reference implementation
- `rtl/via6522.sv` — VIA 6522 with shift register
- `rtl/dataController_top.sv` — VIA/Egret wiring, `via_sr_read` generation (line 446-470)
- `verilator/sim_main.cpp` — simulator with `--trace` FST support
- `docs/MacLC_ROM_disasm.txt` — partial ROM disassembly
