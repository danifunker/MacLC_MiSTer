# Egret HC05 Reimplementation — Session Findings & Plan

**Session date:** 2026-04-09
**Starting point:** Boot stuck at PC=`$A49F00` SCC poll loop (current `master`).
**Outcome of session:** Root-cause chain identified, new direction agreed: resurrect the real HC05 + Egret firmware path instead of extending `egret_behavioral.sv`.

## The chain of misdiagnoses this session untangled

1. **Initial hypothesis (from `docs/adb_egret_wiring_mame.md`):** ADB PA6/PA7 pins tied off → Egret can't enumerate devices → ROM hangs waiting for ADB init. **Wrong.** The ROM never sends a single `PKT_ADB` packet during the failing boot — every observed Egret transaction is `PKT_PSEUDO`.

2. **Second hypothesis:** `egret_behavioral.sv`'s `PKT_ADB` handler is too stubbed; extend it to fake autopoll responses. **Wrong for the same reason** — ADB packets never get sent.

3. **Third hypothesis:** The PRAM GET/SET loop (`offset=0xf9`, incrementing counter at `$fb`) is a panic handler writing a boot-failure record. **Wrong.** That's ordinary PRAM init chatter, unrelated to the stall.

4. **Fourth hypothesis:** ROM is stuck at PC `$A49F0E` in a tight `beq` loop. **Wrong — that was the EA (effective address), not the PC.** The actual PC at frame 600 is `$A49F00`-`$A49F10`, and `@50F04002` is the data address being touched.

5. **Fifth hypothesis:** The spin is waiting for SCC `RR0` bit 0 (Rx Character Available), which our SCC model forces to 0 via `post_loopback_a` gating. **Technically true, but not the root cause.**

6. **Correct diagnosis (found via `git log -p rtl/scc.v`):** This exact spin is a *known* open issue. Commit `a89c671` ("Fix pseudovia A0 routing, unify IER, re-enable SCC loopback") says verbatim:

   > "Boot still hangs at 0xA49F00 in the atlk LLAP protocol loop because the CPU SR mask blocks interrupts during that routine — to be addressed separately."

   So `$A49F00` is the **AppleTalk/LocalTalk LLAP driver's protocol loop**, not a generic SCC poll. The existing workaround — force XPRAM `$13=$22` (`SPConfig` = both ports useAsync = "AppleTalk inactive on boot") — is in place in `rtl/egret_behavioral.sv:224` and in the `CMD_WR_XPRAM` block at `~:540`, but the ROM still ends up in the LLAP loop anyway. Something about the workaround is no longer effective, or was always fragile.

## Root cause, stated properly

We've been patching symptoms of a deeper problem: **`egret_behavioral.sv` is a ground-up reimplementation of the 68HC05 Egret firmware in Verilog**, and it is full of stubs, approximations, and undocumented assumptions. Every command path the LC ROM exercises is a potential wrong-answer generator. The LLAP hang is likely one of many bugs that would be auto-fixed if we just ran the real firmware.

Specific gaps in `egret_behavioral.sv` (non-exhaustive):

### Completely stubbed pseudo-commands (return generic OK, do nothing)
- `$01` StartStopAutoPoll — no autopoll state, no asynchronous ADB packets sent to host
- `$0E` SendDFAC — no DFAC side effects
- `$11` PowerDown/ResetSystem — sets `reset_680x0 <= 1'b1` but never clears it; warm vs cold boot distinction missing
- `$12` SetIPL — ignored
- `$14`/`$16` Set/GetAutoRate — stubs
- `$19`/`$1A` Set/GetDeviceList — stubs
- `$1B` SetOneSecondMode — stub; no ~1Hz tick generated
- `$1C` **Unknown command, sent twice by LC ROM during boot** — we ack blind with no idea what the response should be
- `$22` GetSetIIC — stub

### Not implemented at all
1. **Asynchronous `PKT_ADB` uplink.** Real Egret, with autopoll enabled, initiates transfers to the host whenever an ADB device has data. Our model only sends in response to a host command.
2. **Meaningful `PKT_ADB` response body.** `rtl/egret_behavioral.sv:602-607` returns `[$00, $00, cmd_echo]` for *every* ADB command regardless of Talk R0 / Talk R3 / Listen / Flush.
3. **SRQ forwarding.** ADB devices' service-request bit is always reported as zero.
4. **Reset-cause reporting.** Always looks cold-boot.
5. **XPRAM write range semantics.** The offset `$13` block is a hack that assumes the ROM uses that exact offset. If the ROM uses a base+offset that *resolves* to `$13` through a different path, the block misses.
6. **Periodic 1Hz tick.** Timeout-driven code paths (including atlk) may depend on it.
7. **Multi-packet responses.** Our send path is strictly one-shot per command.

### Suspicious implementations
- `CMD_GET_PRAM` hardcoded to 32 bytes (`:504-517`), ignores the ROM's requested length
- `CMD_SET_PRAM` assumes exactly one byte (`:519-525`)
- `CMD_RESET_SYSTEM` sets reset line but never clears it

## Prior HC05 work — what already exists

This is **not** a from-scratch rebuild. `rtl/egret/` contains substantial prior infrastructure:

| File | Size | Purpose |
|---|---|---|
| `m68hc05_core.sv` | 1523 lines | Full 68HC05 CPU core, converted from Ulrich Riedel's VHDL `jt6805` |
| `m68hc05_alu.sv` | 81 lines | ALU helpers |
| `egret_wrapper.sv` | 1075 lines | Egret MCU wrapper: Port A/B/C, VIA CB1/CB2 glue, TIP gate, reset-release timer, ROM mapping |
| `egret_rom.hex` | — | **Real Egret firmware** (341S0851) converted to `$readmemh` format |
| `341s0850.bin` / `341s0851.bin` / `344s0100.bin` | — | Raw ROM binaries (multiple Egret variants) |
| `egret_rom_disasm.md` + `disasm_6805.py` | — | Disassembler + annotated notes |
| `convert_firmware.py` | — | Binary-to-hex converter |

Plus supporting docs: `rtl/egret/newest-egret.md`, `verilator/egret_implementation.md`, `docs/egret-transaction-todo.md`.

### Status when previously shelved (per `newest-egret.md` + `egret-transaction-todo.md`, dated 2026-03-22)

**Working:**
- HC05 CPU core runs real firmware; reset vector `$FFFE/FFFF → $0F71`
- Port A DDR init (`$FF`)
- 68020 reset released via auto-timer workaround (bypasses chicken-and-egg where Egret waits for VIA and VIA waits for 68020)
- Key port A bits discovered: **bit 5 = "Egret controls power" = 1**, **bit 1 = chassis on = 1**
- TIP gate in `egret_wrapper.sv` holds TIP high for 4096 Egret cycles after 68020 reset release, then passes real value through
- TIP detection triggers TREQ assertion; SR byte transfers occur

**Failure mode at shelving time (precise, from the todo doc):**
- 1628 TIP assertion/deassert cycles (transaction attempts)
- 7322 SR shift completions (**~4.5 bytes per attempt**)
- 1629 TREQ toggles
- TREQ visible in host ORB reads (`0x40`)
- **IFR bit 2 fires in VIA but host VIA IER = `0x00` (all interrupts disabled)**

Interpretation: handshake begins, ~4.5 bytes shift, transaction never completes cleanly, HC05 firmware never returns to its main idle loop, subsequent attempts compound the failure.

### Current state of the HC05 code in the tree

- `USE_EGRET_CPU` is a **misleading macro name** — currently selects `egret_behavioral`, not the HC05. Defined in both `verilator/Makefile` and `MacLC.qsf`.
- `rtl/egret/egret_wrapper.sv` and `m68hc05_core.sv` are listed in `files.qip` (so they compile as dead code) but **not instantiated anywhere** in `rtl/dataController_top.sv`.
- The 2026-03-22 HC05 status doc has **not been verified against current on-disk RTL** — may have bit-rotted against subsequent VIA/pseudovia/reset/clock changes.

## Firmware main-loop analysis (from `egret_rom_disasm.md`)

### Port B bit map (from the firmware's perspective)
```
bit 7: DFAC clock        (output)
bit 6: DFAC data         (I/O)
bit 5: CB2 data          (I/O — to/from VIA)
bit 4: CB1 clock         (output — to VIA)
bit 3: TIP/SYS_SESSION   (input — from host PB5)
bit 2: BYTEACK/VIA_FULL  (input — from host PB4)
bit 1: TREQ/XCVR_SESSION (output — to host PB3)
bit 0: +5V sense         (input — must be 1)
```

### Idle/wait loop at `$12A1`
```
12A1: JSR $120A              ; check +5V sense, state flags
12A4: BCS  $12B3              ; abort on error → JMP $0FAF (reset)
12A6: JSR $1E4E              ; RTC handler
12A9: JSR $1149              ; port B read helper
12AC: BRSET 3,$01,$12A1      ; loop while PB3 (TIP) high
12AF: BRSET 2,$01,$12A1      ; loop while PB2 (BYTEACK) high
12B2: RTS                    ; return to main when BOTH are LOW
```

**Key insight:** the firmware returns to idle ONLY when host has dropped both TIP and BYTEACK. If either stays asserted (or is observed asserted due to latching/sync issues), the firmware stays in this loop forever and never accepts the next command. This matches the 2026-03-22 symptom.

### State register `$A3`
The firmware uses zero-page byte `$A3` as its main state register. Bits referenced in the disasm:
- bit 7: set at `$1236` (after successful `$120A` check)
- bit 6: cleared at `$1210`, tested at `$1022`
- bit 5: toggled in `$14C0` CB1 clocking path, cleared in RTC ISR
- bit 4: set at `$1530`, `$102C`-ish path
- bit 3: set during init, tested in main
- bit 0: cleared at `$104A`, set at `$106B`

Tracing `$A3` writes gives a compact view of firmware state machine progress.

## Hypotheses to test (in priority order)

### H1 — BYTEACK (PB2) toggle timing mismatch (most likely)
Linux `via-cuda.c` specifies:
```
EGRET_TACK_ASSERTED_DELAY = 300 µs
EGRET_TACK_NEGATED_DELAY  = 400 µs
```
Firmware polls PB2 via `BRSET 2,$01` (~1.25 µs per check at 4 MHz). If the host's BYTEACK edges aren't visible to the firmware — either because they're too fast, latched wrong in `egret_wrapper.sv`, or the host driver doesn't actually toggle them — the `$12A1` idle loop never exits.

### H2 — TIP return-to-low not seen by firmware
Same loop structure: firmware waits for PB3 low. If the host-side TIP gate or sync circuit holds TIP high after the transaction from the firmware's POV, same stall.

### H3 — IER=0 chicken-and-egg (documented but likely obsolete)
Todo doc notes host VIA IER stays `$00` after ROM's VIA selftest. **However**, behavioral Egret now achieves 68 successful transactions with the same VIA, so either the ROM is polled not interrupt-driven, or subsequent VIA work made IER enable actually stick. Needs re-verification but probably not the current blocker.

### H4 — `$120A` init check failing (BCS to `$12B3` → reset)
If `$120A` returns carry-set, the firmware jumps to `$12B3 → JMP $0FAF` (soft reset). Triggers include:
- `BRCLR 0,$01` fails → PB0 (+5V sense) not high — **per `newest-egret.md` this MUST be 1**
- Internal state bits in `$A3` wrong

### H5 — Port A key bits wrong
`newest-egret.md` documents that PA5 = 1 (Egret controls power) and PA1 = 1 (chassis on) are **required** for correct firmware behavior. If `egret_wrapper.sv`'s port-A input mapping doesn't match this, firmware takes the wrong branch at `$0F83 BRSET 5,$00,$0F8A` during reset.

## Diagnostic plan

Execute in order. Each step has a clear expected result.

### Step 0 — Sanity-check the wrapper's port mappings against `newest-egret.md`
Before touching anything else, read `rtl/egret/egret_wrapper.sv`'s Port A / Port B input assignments and verify:
- `pa_in[5] = 1'b1` (Egret controls power)
- `pa_in[1] = 1'b1` (chassis on)
- `pb_in[0] = 1'b1` (+5V sense)
- `pb_in[3] = via_tip` (TIP from host)
- `pb_in[2] = via_byteack` (BYTEACK from host — **verify polarity**)
- `pb_in[5] = via_cb2_in` (CB2 from VIA)
- CB1 in/out, CB2 in/out bidirectional glue present and correct

**Expected:** matches `newest-egret.md`'s "working values" table. If not, fix here before sim.

### Step 1 — Resurrect the HC05 instantiation
Swap `dataController_top.sv`'s USE_EGRET_CPU branch to instantiate `egret_wrapper` instead of `egret_behavioral`. Single-branch change, no new ifdef needed — we can revert by git later.

**Expected:** builds clean under Verilator. If not, fix bit-rot against current VIA / reset / clock interfaces until it does.

### Step 2 — Confirm firmware reaches main idle loop
Add a `$display` in `m68hc05_core.sv` or `egret_wrapper.sv` that logs every PC fetch within `$12A0-$12B5` (the idle-loop address range). Run sim to frame 50.

**Expected (success):** many PC hits in that range, indicating firmware reaches idle.
**Expected (failure):** no hits → firmware stuck earlier; trace back to find where.

### Step 3 — Instrument `$A3` state writes
Log every write to address `$A3` with PC + new value. Gives a compact timeline of firmware state-machine progress.

**Expected:** steady sequence of bit sets/clears through init → idle → first transaction → return to idle. Watch for the point where progress stops.

### Step 4 — If firmware reaches idle but doesn't accept commands
Correlate firmware PB2/PB3 observations against host-side PB4/PB5 drives:
- Log every `BRSET 3,$01` / `BRSET 2,$01` instruction result in firmware
- Log every host write that changes `via_pb_o[4]` / `via_pb_o[5]`
- Compare timestamps

**Expected (H1 confirmed):** host toggles PB4 cleanly but firmware never observes PB2 going low.
**Expected (H2 confirmed):** host drops PB5 but firmware never observes PB3 low.
**Expected (H3/H5/etc):** different signature.

### Step 5 — Fix and validate
Once hypothesis is confirmed, propose minimal fix in `egret_wrapper.sv` or `dataController_top.sv`. Test by observing the firmware reach the `$12B2 RTS` idle-return after first transaction and accept a second command.

## Known risks

1. **HC05 firmware will eventually need real ADB bit-level bus.** Once past VIA init, the firmware tries to enumerate ADB devices via PA6/PA7. This requires `adb_bus.sv` (the original plan doc's Option A). We have a temporary loopback in place on PA6↔PA7 from earlier this session that may or may not be enough to satisfy the firmware's self-test.

2. **The 2026-03-22 "4.5 bytes per attempt" state may not reproduce.** Subsequent VIA/pseudovia/reset work may have changed the failure mode. We may see a different symptom entirely. Accept this and retrace.

3. **Debug cycle is slower.** HC05 trace + state register observation is less immediate than reading a Verilog state machine. Invest in good `$display` tracing early.

## Files involved

- `rtl/egret/egret_wrapper.sv` — primary instantiation target
- `rtl/egret/m68hc05_core.sv` — CPU core (should not need changes)
- `rtl/egret/egret_rom.hex` — firmware
- `rtl/egret/egret_rom_disasm.md` — reference for PC ranges and state bits
- `rtl/dataController_top.sv` — where the swap happens (USE_EGRET_CPU branch, ~line 619)
- `rtl/via6522.sv` — host-side CB1/CB2/IER/IFR behavior
- `rtl/egret_behavioral.sv` — current (working-ish) fallback; keep untouched during this work
- `docs/egret-transaction-todo.md` — prior HC05 status snapshot
- `rtl/egret/newest-egret.md` — prior HC05 session summary with key port values
- `verilator/egret_implementation.md` — prior implementation notes

## Commit `a89c671` — the "known issue" pointer
This commit message is the closest thing to a north-star for this work. It describes the exact hang we see today and identifies interrupt masking as the deferred root cause. Read it in full before starting Step 1.
