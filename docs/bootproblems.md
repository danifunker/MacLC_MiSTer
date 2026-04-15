# Boot Problems Log

## 2026-04-15 Session — Apple STM identified; SCC TX "All Sent" is the real blocker

**Headline:** the outer loop at `A498EC/A49FCA` is **Apple's Self-Test Monitor
(STM) serial debug console** (Scott Smyers, "STM Version 2.0"), not a
LocalTalk/LLAP driver as previously thought. It is entered *unconditionally*
on every boot via `A48D5C: braw 0xa498a0`. The inner hang at `A49F0E` is an
SCC channel-A "All Sent" (RR1 bit 0) poll that never reads 1 — the same bug
fires whether we reach STM fast (bit-0 cleared) or slow (via the full POST
path).

### STM entry map

Three `braw 0xa498a0` entries exist:

| Source | Gate | Notes |
|--------|------|-------|
| `A48D04` | `btst #26,d7` at A48CEC — fall-through when bit26 clear | "RAM-test STM" path |
| `A48D5C` | **unconditional** | Reached via normal boot chain at A48D3C→A49F78→(return)→A48D44 |
| `A48D92` | `btst #26,d7` at A48D76 — taken when bit26 set | Alternate path |

The "normal-boot-enters-STM" fact (A48D5C) was the surprise: on a real Mac LC,
STM is always entered briefly during POST. It exits via one of:
- An explicit `'S'` serial command (handler at `A49A72` clears d7 bits 16/22)
- The `0xAAAA5555` magic startup vector at `(A0@(4))+0..3` at `A48D1E`
- Never — STM otherwise polls forever

There is **no timeout counter** to hunt. `A49F9E` (previously suspected as a
timeout) is actually a VIA1-timer2-driven *prompt rate limiter* keyed off
`btst #5, a2@(0x1A00)` (IFR bit 5).

### STM command table (decoded from `A49948`)

Entries are `[word1:flags+char][word2:offset]`; handler = `A49948 + slot + 2 + offset`:

| Char | Handler | Likely meaning |
|------|---------|----------------|
| 'S' 0x53 | A49A72 | Stop — clears d7[16] and d7[22] |
| 'L' 0x4C | A49A82 | Load |
| 'B' 0x42 | A49AA2 | Branch/word load |
| 'D' 0x44 | A49AC0 | Display/deposit |
| 'C' 0x43 | A49AE4 | Checksum |
| 'G' 0x47 | A49B0A | Go (execute) |
| '0'-'7'  | A49B24+ | Register set (A0, A1, CACR etc) |
| 'A','H','R','M','E','I','P','T','N','V','Z' | … | Various |

### Why changing VIA1 PA bit 0 doesn't help

`ROM A46452: btst #0, a2@(0x1E00)` reads VIA1 ORA-no-handshake bit 0.
- Bit 0 = **1** (our `via_pa_i = 0x55`) → branch past `bset #26,d7` → d7[26] stays
  clear → `A48CEC bnes` falls through → STM entered via `A48D04`.
- Bit 0 = **0** → `bset #26,d7` runs → d7[26] set → `A48CEC` branches to A48D08
  (normal POST path) → POST runs → ... → **`A48D5C` unconditionally enters STM
  anyway**.

Both paths land in STM and hit the same `A49F0E` hang. Bit 0 only changes
*how quickly* we arrive. We reverted `via_pa_i` to `0x55` to preserve the
longer POST path.

### The real blocker at A49F0E

```
a49ef6: moveb #48, a3@(2,d3:l)   ; WR0 = 0x30 (error reset cmd)
a49efc: moveb d0, a3@(6,d3:l)    ; write byte to SCC ch A data
a49f00: movew #1, d0
a49f04: moveb d0, a3@(2,d3:l)    ; WR0 = 0x01 (point to RR1)
a49f08: btst #0, a3@(2)           ; read RR1 bit 0 = All Sent
a49f0e: beqs a49f00                ; loop until drain
a49f10: jmp fp@
```

The byte *does* transmit (external SERIAL_RX sees it) yet `~tx_busy_a` is
never observed as 1 by the CPU's poll. Possible causes to investigate next:
1. `tx_busy_a` actually stays high (txuart bug, clock gating, wrong baud)
2. `rindex_a` reset races the read so ctl read returns `rr0_a` instead of
   `rr1_a` (rr0_a bit 0 = rx-available, which stays 0 in async-out mode)
3. `tx_buffer_full_a` sticks high, causing perpetual re-arm of TX

### Next-session starting points

- Enable `SCC_TX_DEBUG` in `verilator/Makefile` and rerun — the
  `SCC_TX_BUSY: ch=A 1->0` transitions will show whether `tx_busy_a` is
  clearing at all.
- Instrument `rindex_latch` at the `A49F08` ctl read to confirm we return
  `rr1_a` and not `rr0_a`. The existing `SCC_CTRL_READ` trace line does
  this but it's not enabled without `DEBUG_SCC`.
- If `tx_busy_a` does drop to 0, check the time between it dropping and
  the CPU's next `btst` — the CPU runs ~every ~50ns, TX takes ~1ms at
  9600 baud, so the CPU should observe at least one 0 reading per byte.

---

## 2026-04-14 Session — SCC WR0 State-Machine Fix

Goal: continue investigating the `0xA49F0E` hang. Prior session had narrowed
it down to a question of whether the `beq` was being taken or whether A6 had
been corrupted.

### Root cause found: SCC WR0 pointer writes clobbered register state

In `rtl/scc.v`, the WR0 dispatch had a bug: whenever state was `READY` and a
write came in (interpreted as a pointer-set), the state machine
**unconditionally** transitioned to `REGISTER`, even when the new pointer
was 0. On a real Z8530, writes to WR0 are *always* commands — the pointer
"persisting" at 0 is meaningless because WR0 accesses never consume the
pointer.

The symptom: the ROM's SCC init issues sequences like `$30` (a WR0 command
with data[2:0]=0) followed by `$01` (select RR1 / WR1). Our state machine
treated `$30` as "set pointer to 0, enter REGISTER state", then treated the
subsequent `$01` as a **WR0 data write** instead of another WR0 command.
The RR1 pointer was never selected, so polling RR1 bit 0 ("All Sent") always
read `rr0_a` instead of `rr1_a`, and the driver never saw TX completion.

### Fix

Only transition to `REGISTER` state when the newly-written pointer would be
non-zero (`wdata[2:0] != 0 || wdata[5:3] == 3'b001`). If the pointer stays at
0, remain in `READY` so the next WR0 access is still interpreted as a
command. Applied to both channel A (lines ~333-350) and channel B
(lines ~359-378).

### Boot progress after fix

Previously: CPU stuck at `0xA49F00` from frame 356 with no forward progress.

Now, per `verilator/sim_err.log` over ~340M cycles:

- CPU runs productive code across `A46xxx`, `A470xx`, `A471xx`, `A4A4xx`
  ROM regions.
- Loopback self-test **passes**: `SCC_LOOPBACK` ENABLED @131M ns, DISABLED
  @303M ns (driver accepts the result and moves on).
- SCC channel A transmits two bytes externally: `SERIAL_RX: 0xE0` then
  `'*' (0x2A)`. These are real bytes flowing out of the Mac's SCC ch A TX
  pin — the AppleTalk sync byte `$2A` among them.
- Cycle 310M onwards: CPU returns to `A49F00`/`A49F0E` (`67F0 = beq -16`).

### The new hang: same PC, different context

The `A49F00` loop is the same ROM code, but this invocation is *after*
loopback has been turned off. Commit `a89c671` ("Fix pseudovia A0 routing,
unify IER, re-enable SCC loopback") deliberately suppresses RX after
loopback-off via `post_loopback_a`, modelling an unplugged LocalTalk bus:

```verilog
if (rx_wr_a && !post_loopback_a) begin   // rtl/scc.v:241
...
post_loopback_a ? 1'b0 : (rx_queue_pos_a > 0)  // RR0 bit 0 — rtl/scc.v:844
```

So the driver writes `$01` to SCC TX, polls RR0 bit 0 for RX Char Available,
sees 0 forever, and loops. This is the correct "no cable" behaviour of the
RTL — the bug is that whatever retry/backoff timer the driver uses in the
*outer* LLAP state machine isn't advancing within the ~30-frame observation
window.

### Status: partial progress, commit the fix

The WR0 state-machine fix is strictly an improvement — boot went from
"stuck at `A49F00` forever" to "completes loopback self-test, transmits
serial bytes, then stalls waiting for a response that will never come". The
remaining hang is a higher-level LocalTalk/LLAP issue that two deferred
plans already cover:

1. **Find the loop's memory-based timeout counter.** Per prior session
   notes (line 266-268 below), the outer `A498EC`/`A49FCA` state machine
   likely decrements an A2/A6-relative counter that we haven't identified.
   Lower blast radius.
2. **Implement SDLC + DPLL** (`docs/plan_040726.md`). Architecturally
   correct — with real SDLC framing the driver's higher-level retry logic
   would fire. Larger commitment; defer until #1 is ruled out.

The SCC fix is committed ahead of both of these so future sessions start
from a cleaner baseline.

---

## 2026-04-08 Session — ROM Patch Experiments

Goal: force-disable the LocalTalk/atlk path at the ROM level since
PRAM SPConfig=0x22 didn't prevent the load.

### Experiment 1 — Rename `.MPP` DRVR resource in ROM

Found four occurrences of the Pascal string `\x04.MPP` in `releases/boot0.rom`
at file offsets `0x52643`, `0x566cb`, `0x668e8`, `0x66913`. Patched all four
to `.xPP` so that any `OpenDriver('.MPP')` returns `fnfErr`. Recomputed the
ROM checksum (16-bit BE sum of all words from offset 4, stored at offset 0):
`350eacf0` → `350f2e1b`.

**Result: zero effect.** Trace tail at frame 407 was byte-identical to the
pre-patch hang at `0xA49F00`.

**Lesson:** the LocalTalk self-test that hangs the boot is **ROM-internal
code in the `0xA49xxx` range**, not a `.MPP` DRVR loaded by name from the
System file or ROM resource map. It's invoked by direct hard-coded address,
so renaming the resource doesn't intercept it. The `.MPP` rename would
still block any later AppleTalk client that opens by name, but the wedge
happens before that.

**Side note:** the ROM checksum at offset 0 (`350eacf0`) is a valid
sum-of-16-bit-BE-words from offset 4, so the algorithm is the standard Mac
ROM checksum. Whether this core actually verifies it on boot is unknown
(reverted patch booted fine either way), but recompute it on any future
ROM patch to be safe.

### Experiment 2 — Inner echo loop short-circuit at `0xA49F00`

Patched `A49F00` from `303C` (`move.w #1,D0`) to `4ED6` (`jmp (A6)`) so
the inner SCC byte-write/echo-poll subroutine returns immediately to its
caller. (First attempt used `4E75 rts` and crashed the CPU into garbage at
`0x6DDFFFxx` — that subroutine returns via `jmp (A6)`, not `rts`. A6 holds
the real return address; the stack does not. Lesson: read the original
exit instruction before guessing the return convention.)

**Result with `jmp (A6)`:** no crash, but no progress either. The trace
moved on from `A49F00` entirely, but the boot is now stuck in the **outer**
LLAP state machine at `A498EC ↔ A49A72`, which is a self-contained
`bra`-loop polling D7 bits that no longer change (they used to be set as
side effects of the inner subroutine we just bypassed).

### Why a higher-level patch is hard

Reverse-engineered the entry chain to the state machine:

```
A45E38: jmp (A6)              ; A6 loaded from A2 — returns to A498DA
A498DA: moveq #0,D5
A498DC: lea (6,PC),A6         ; A6 = A498E4
A498E0: jmp ($586,PC)         ; → A49E68 (init phase 1)
   ...A49E68..A49E94 → jmp(A5) → A498E4
A498E4: lea (6,PC),A6         ; A6 = A498EC
A498E8: jmp ($5ac,PC)         ; → A49E96 (init phase 2)
   ...A49E96..A49EDA → jmp(A5) → A498EC
A498EC: <state machine entry — no normal exit>
```

The original return address from the *outer* caller of this routine was
consumed by the `jmp (A6)` at `A45E38` (which loaded A6 from A2). After
that point, the routine doesn't preserve any path back to its outer
caller — A498DA freshly loads A6 to set up internal continuations and
never restores it. The state machine at `A498EC` is an **event loop**,
not a subroutine: it's designed to be exited only via interrupt or via
some D7 bit being changed by an interrupt handler.

**Implication:** there's no clean 2-byte `rts`-style patch we can drop
into `A498DC`/`A498E4`/`A498EC` that returns to the outer caller, because
the outer caller's return address no longer exists in any register or on
the stack by that point.

### Paths forward (revised priorities)

1. **Hunt further up the call stack from `A45E38`/`A498DA`.** Find the
   *original* `jsr`/`bsr` (or trap) that started this whole chain — that
   call site has a real stack-based return address and can be NOPed
   cleanly. Look for what set A2 to `A498DA` and trace back from there.
2. **Implement SDLC framing** (`docs/plan_040726.md`). With proper framing,
   the loopback echo will not deliver bytes for an unframed write, the
   state machine's RX timeout / error path will fire, and it will exit
   naturally. Bigger commitment but addresses root cause.
3. **Re-investigate why PRAM SPConfig=0x22 didn't take effect.** If the
   PRAM-based skip was supposed to work and didn't, that's a smaller fix
   than either of the above — verify the PRAM bytes the Egret actually
   delivers to the ROM at the right boot stage match what we set.

### Files touched and reverted this session

- `releases/boot0.rom` — patched twice, reverted to original both times.
  Final state: byte-identical to pre-session, checksum `350eacf0`.

---

## Current Status (2026-04-07)

Boot reaches the atlk/LocalTalk driver self-test and hangs at ROM address
`0xA49F00` starting at frame 356. The hang is deterministic: ~367 iterations
per frame of a 5-instruction polling loop inside an outer LLAP handshake
state machine, 100% CPU-bound, zero instructions executed outside the
`0xA498xx–0xA49Fxx` atlk range in frames 370–400.

**Not yet resolved.** Three commits landed during investigation; see below.

---

## 2026-04-07 Investigation Session

### Commits landed

1. **`a89c671`** — pseudovia A0 routing, unified IER, SCC loopback re-enabled
   - `MacLC.sv:949`: pseudovia now sees `tg68_a[0]` (was hardwired to 0).
     Odd-address writes to pseudovia native IER (`$13`) were aliasing to
     Slot IER (`$12`).
   - `rtl/pseudovia.sv`: collapsed `ier`/`ier_compat` into one register per
     MAME `pseudovia.cpp:167` (non-AIV3 chips share IER between native
     `$13` and compat reg 14). LC ROM never writes to either IER path so
     `irq_pending` now drives from `any_slot_irq` directly.
   - `rtl/scc.v`: re-enabled `rx_input_a = local_loopback_a ? tx_internal_a
     : rxd` and same for B. Removed the `rr0_cts_a = local_loopback_a` /
     `rr0_dcd_a = local_loopback_a` hack per MAME `z80scc.cpp` — loopback
     forces CTS/DCD internally for the TX/RX state machines but does NOT
     change RR0 bits 5/3, which reflect pin state only.
   - Verified: SCC self-test passes, VBlank IRQs now assert at level 2
     (confirmed via temporary `IPL_CHANGE` debug — `_cpuIPL` transitions
     from `111` to `101`).

2. **`1020346`** — verilator trace now filters extension words
   - TG68 issues a bus fetch for every code-space word; the previous trace
     logged all of them, so a single `move.w #imm, Dn` appeared as two
     entries with the extension word disassembled as nonsense
     (`ori.b #0, D0`). Loop iteration counts were inflated proportionally.
   - New `disassemble_68k_ext_len()` helper returns Musashi's instruction
     length; `sim_main.cpp` buffers consecutive sequential fetches and
     advances past extension words using that length. Non-sequential
     fetches (branches) flush the buffer first.

3. **`d467c4d`** — SCC: mark CS access consumed on WR9 hardware-reset writes
   - When the ROM writes `0xC0` to WR9 (hardware-reset command), the
     combinatorial `reset` signal fires and the top-level `if (reset)`
     branch runs. The old code cleared `cs_access_done` back to 0, which
     caused the same CS assertion to be re-processed on the next `cen`
     pulse as a spurious WR0 write (with the reset data `0xC0`). Fix:
     `cs_access_done <= ~reset_hw` — external hardware reset clears as
     before, CPU-initiated reset marks the cycle consumed.
   - Functional impact was benign (WR0 has no backing storage; subsequent
     RR0 reads naturally cleared the stale state), but the fix is a
     correctness cleanup and made the debug trace coherent.
   - **Did NOT unblock the boot hang.**

### Observations after the three commits

Clean trace of the inner loop at `0xA49F00`:

```asm
A49F00: move.w  #$1, D0
A49F04: move.b  D0, ($2,A3,D3.l)    ; TX byte to SCC ch A data ($50F04006)
A49F08: btst    #$0, ($2,A3)        ; poll RR0 bit 0 (Rx Char Available)
A49F0E: beq     $a49f00              ; loop until echo — NEVER TAKEN (echo works)
A49F10: jmp     (A6)                 ; return to caller
```

All three PCs (`A49F00`, `A49F08`, `A49F10`) have identical execution counts,
meaning the `beq` is never taken — the loopback echo arrives every iteration.
The loop exits via `jmp (A6)` into the outer LLAP state machine at
`0xA498EC`/`0xA49FCA`, which comes back around to call this inner loop again.

Outer LLAP state machine (reconstructed from the trace):

- `0xA498EC`: `lea ($6,PC),A6 / jmp ($6d8,PC)` — sets A6=`0xA498F4`, jumps to
  the `Snd` subroutine at `0xA49FCA`.
- `0xA49FCA`: `move.w #$8000,D0 / btst #$11,D7 / beq $a49ff8` — checks state
  bit 17 of D7; if clear, skip to end.
- `0xA49FD4`: `btst #$0,($2,A3) / beq $a49ff8` — checks RR0 bit 0.
- `0xA49FDC`: `moveq #$1,D0 / move.b D0,($2,A3,D3.l)` — TX byte.
- `0xA49FE2`: `move.b ($2,A3),D0 / andi.b #$70,D0 / beq $a49ff2` — read RR0,
  mask ext/status bits 4–6, skip if none.
- `0xA49FFA` onward: `tst.w D0 / bmi / cmp2.b / andi.b #$7f,D0 /
  cmpi.b #$2a,D0 / bne / bset #$0,D7` — compares received byte against
  `0x2A` (AppleTalk sync byte), sets D7 bit 0 on match.

D7 bit manipulations observed in the trace:

- `0xA49EC0 bset #$11,D7` — sets **bit 17** (happens once at frame 356)
- `0xA49904 bset #$13,D7` — sets **bit 19**
- `0xA49914 bclr #$13,D7` — clears bit 19
- `0xA49904 bset #$0,D7` — sets bit 0 (AppleTalk sync seen)
- `0xA49A10 bclr #$0,D7 / bclr #$17,D7` — clears bit 0 and bit 23

Bit 17 is set once at frame 356 and **never cleared** in the trace range.
The loop tests `btst #$11,D7` at `0xA49FCE` and falls through every iteration
because bit 17 is sticky. Bit 19 toggles set/clear within the loop. The loop
does NOT contain a byte counter or a timeout — it's a pure state-machine
handshake that runs deterministically at ~367 Snd calls per frame, with no
forward progress.

### SCC register-write reverse engineering

After the state-machine fix, the `SCC_WREG_A`/`SCC_WREG_A_PTR` debug prints
give a clean view of the ROM's SCC channel-A initialization sequence:

- **Registers written**: WR0, WR1, WR2, WR3, WR5, WR7, WR9, WR10, WR12, WR14, WR15
- **WR4 is NEVER observed** being written on channel A — stays at reset default
  (our RTL resets to `0x00` = 8-bit sync mode; Z8530 datasheet says reset
  default is `0x04` = async 1-stop, minor discrepancy worth fixing)
- **WR3 = 0x0F** → 8-bit RX + **hunt mode** (bit 4) + RX enable. Hunt mode is
  only meaningful in sync/SDLC modes.
- **WR7 = 0x0D then 0x0E** → sync character value. Only used in sync modes.
- **WR10 = 0x0B** → `0000_1011` = NRZ + Tx CRC enable + Mark Idle (bit 3).
  WR10 is entirely a sync/SDLC control register.
- **WR14 = 0x11** → Local Loopback + BRG enable.
- **WR15 = 0x08** → DCD ext/status interrupt enable (also Abort/Underrun in
  SDLC mode).

**Conclusion: the ROM is programming sync/SDLC-mode behavior**, but our SCC
has no sync or SDLC framing — it just echoes bytes as if in async mode.
Whether the driver is in monosync or SDLC mode specifically is ambiguous
without a WR4 value; the WR10 underrun bits and hunt-mode use suggest SDLC.

### What would SDLC + DPLL actually fix?

Analysis after careful look at the polling loop:

**Probably necessary but not clearly sufficient.**

- In SDLC mode, a single byte written to TX does NOT transmit immediately —
  it waits for an EOM or more payload before framing. So in true SDLC, the
  polling loop at `0xA49F00` (write 1 byte, wait for echo) should never see
  an echo because the byte sits in the TX FIFO. But in our sim, the echo
  arrives every time (because we don't implement SDLC framing), so the
  `beq` is never taken. This matches **async mode** behavior, suggesting
  the driver may actually be in async mode for this specific subroutine.

- On real hardware with no cable: DPLL never locks, RX never delivers a
  byte, driver's internal counter (stored somewhere in memory, not D7)
  times out and exits. SDLC+DPLL would reproduce this by making the
  loopback return no bytes when framing is invalid.

- BUT: bits 17 and 19 of D7 are set by explicit `bset` instructions
  at `0xA49EC0` and `0xA49904`, not by an interrupt handler. Those
  instructions DO execute (observed in frame 356). So the state machine
  IS advancing — it's just stuck in a steady-state orbit.

- **Open question**: where is the loop's actual exit condition? It may be
  a memory-location counter (A2-relative, A6-relative, etc) that we
  haven't identified. Searching for it would be the next investigative
  step before committing to SDLC+DPLL.

### Debug infrastructure left in tree

See `docs/extradebugging.md` for the current list. Summary:

- `rtl/scc.v`: `SCC_WREG_A[_PTR]` / `SCC_WREG_B[_PTR]` prints — still useful,
  keep until SCC init is settled.
- Earlier temporary debug (`SCC_STATE_A`, `SCC_CS`, `SCC_RREG_*`,
  `PVIA_VBL_DEBUG`, `PVIA_WRITE`, `IPL_CHANGE`) has been removed.

### Recommended next steps (ranked)

1. **Dedicated `wr4_a <= wdata` $display** — 15 min sanity check that WR4 is
   really never written, not just missed by the control-register state
   tracer. Rules out our debug having a blind spot.
2. **Grep the ROM for the atlk loop exit condition** — find what clears bit
   17 of D7 (or sets a different exit flag). If it's a memory counter, we
   can figure out what increments it.
3. **Investigate skipping the atlk driver load** — the ROM's LoadDrivers
   phase runs unconditionally; find the decision point. PRAM SPConfig byte
   `0x13` was tried previously and didn't prevent loading — that's the
   Mac Plus path, LC may use a different mechanism.
4. **Full SDLC + DPLL** (`docs/plan_040726.md`) — big commitment; defer
   until #1–#3 are ruled out.

The session ended without unblocking the boot hang, but with a much better
understanding of the atlk loop structure and cleaner debug infrastructure.

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
