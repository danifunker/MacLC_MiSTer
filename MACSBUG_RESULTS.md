# MacsBug Dump Analysis - Real Macintosh LC

Analysis of register dumps from real Macintosh LC hardware.

## Typos / Misreads in Dump

A few commands had address typos (noted for re-verification):
- `dm F0000` → read $000F0000 (ROM area, not VIA) - should be `dm F00000`
- `dm f100008` → read $0F100008 (extra zero, hit ROM) - should be `dm F10008`
- `dm f0600` → read $000F0600 (wrong address) - should be `dm F06000`
- `dm d26001` → read $00D26001 (RAM, not PseudoVIA) - should be `dm F26001`
- `dm d26200` → read $00D26200 (RAM, not PseudoVIA) - should be `dm F26200`
- `dm f160900` → read $0F160900 (extra zero) - should be `dm F16900`
- `dm f400000` → read $0F400000 (extra zero, hit ROM) - should be `dm F40000`

These didn't affect the overall analysis much since we have good reads for most registers.

---

## VIA1 ($F00000 - $F01FFF)

Register values (upper byte of each read, since VIA is on upper data bus):

| Reg | Addr | Name | Value | Binary | Notes |
|-----|------|------|-------|--------|-------|
| 0 | $F00000 | ORB (Port B) | $4F | 0100_1111 | Port B output state |
| 1 | $F00200 | ORA (handshake) | $F6 | 1111_0110 | Port A with handshake |
| 2 | $F00400 | DDRB | **$F7** | 1111_0111 | Bit 3 = input, rest output |
| 3 | $F00600 | DDRA | **$2F** | 0010_1111 | Bits 7,6,4 = input; 5,3,2,1,0 = output |
| 4 | $F00800 | T1C-L | (missed) | | Typo in command |
| 5 | $F00A00 | T1C-H | ~$56 | (counting) | Timer 1 counting down |
| 6 | $F00C00 | T1L-L | **$FF** | 1111_1111 | Timer 1 latch low |
| 7 | $F00E00 | T1L-H | **$A0** | 1010_0000 | Timer 1 latch high |
| 8 | $F01000 | T2C-L | (varying) | | Timer 2 counting |
| 9 | $F01200 | T2C-H | ~$6D | (counting) | Timer 2 counting |
| 10 | $F01400 | SR | **$FF** | 1111_1111 | Shift register |
| 11 | $F01600 | ACR | (missed) | | Command not in dump |
| 12 | $F01800 | PCR | **$00** | 0000_0000 | All negative edge, no handshake |
| 13 | $F01A00 | IFR | **$C2** | 1100_0010 | Timer1 + CA1 flags active |
| 14 | $F01C00 | IER | **$A6** | 1010_0110 | Timer2, SR, CA1 enabled |
| 15 | $F01E00 | ORA (no HS) | $F6 | 1111_0110 | Same as Reg 1 |

### VIA1 Interpretation

**DDRB ($F7):** Port B pin directions: bits 7,6,5,4,2,1,0 = output; bit 3 = input.
- This matches Egret/ADB usage: most pins drive Egret, bit 3 is input from Egret.

**DDRA ($2F):** Port A pin directions: bits 5,3,2,1,0 = output; bits 7,6,4 = input.

**Timer 1 latch = $A0FF** (41,215 cycles). At the VIA's E clock rate (~783 kHz for LC),
this gives a ~52.6 ms period. This is the system tick timer.

**IER ($A6) = enabled interrupts:** Timer 2, Shift Register, CA1.
- Timer 1 is NOT enabled for interrupt (bit 6 = 0), even though its flag is set.
- Shift Register interrupt enabled → used for ADB/Egret communication.
- CA1 interrupt enabled → used for VBlank on older Macs, but on LC this may be
  routed through PseudoVIA instead.

**PCR ($00):** All control lines set to negative edge triggered, no handshaking.

**Missing reads:** Reg 4 (T1C-L) and Reg 11 (ACR) were missed due to command typos.
Recommend re-reading: `dm F00800 2` and `dm F01600 2`.

---

## SCC ($F04000 - $F05FFF)

From the dump at $F04000, the 4 SCC registers repeat with 2-byte stride:

| Addr | Register | Value | Notes |
|------|----------|-------|-------|
| $F04000 | Ch B RR0 (Control) | **$54** | 0101_0100 |
| $F04002 | Ch A RR0 (Control) | **$44** | 0100_0100 |
| $F04004 | Ch B Data | $FF | No data |
| $F04006 | Ch A Data | $01 | |

### SCC RR0 Bit Interpretation

| Bit | Name | Ch B ($54) | Ch A ($44) |
|-----|------|-----------|-----------|
| 7 | Break/Abort | 0 | 0 |
| 6 | Tx Underrun | 1 | 1 |
| 5 | CTS | 0 | 0 |
| 4 | Sync/Hunt | 1 | 0 |
| 3 | DCD | 0 | 0 |
| 2 | Tx Buffer Empty | 1 | 1 |
| 1 | Zero Count | 0 | 0 |
| 0 | Rx Char Available | 0 | 0 |

Both channels show normal idle state: Tx buffer empty, Tx underrun (nothing to send).
Ch B has Sync/Hunt set (bit 4), Ch A does not. This is a valid idle configuration.

---

## SCSI - NCR5380 ($F10000 - $F11FFF)

| Addr | Reg | Name | Value | Notes |
|------|-----|------|-------|-------|
| $F10000 | 0 | Current SCSI Data | $00 | No data on bus |
| $F10008 | 1 | Initiator Command | **$00** | Idle (confirmed in 2nd session) |
| $F10010 | 2 | Mode | $00 | |
| $F10018 | 3 | Target Command | $00 | |
| $F10020 | 4 | Bus Status | $00 | Bus idle |
| $F10028 | 5 | Bus & Status | $00 | No activity |
| $F10030 | 6 | Input Data | $07 | |
| $F10038 | 7 | Reset Parity/IRQ | $07 | |

SCSI bus is completely idle - all zeros for status. $07 in regs 6-7 may be latched
data from last SCSI transaction.

### SCSI DRQ Windows - IMPORTANT FINDING

| Addr | Expected | Actual | Notes |
|------|----------|--------|-------|
| **$F06000** | SCSI DRQ Window 1 | **BUS ERROR** | Not accessible when SCSI idle! |
| $F12000 | SCSI DRQ Window 2 | $0E | Accessible, returns data |

**Key finding:** The SCSI pseudo-DMA window at $F06000 causes a bus error on real hardware
when no SCSI DMA transfer is active. Our core maps this address to `selectSCSI` unconditionally
in `addrDecoder.v` line 127. This may need to be gated by SCSI DRQ status, or it may
simply be acceptable (software wouldn't read it outside of a transfer).

The $F12000 window IS accessible and returns $0E. The asymmetry between the two DRQ
windows is notable and should be investigated.

---

## ASC - Apple Sound Chip ($F14000 - $F15FFF)

### FIFO Area
$F14000: All bytes read as **$80**. This is the FIFO buffer area (1KB × 2 channels).
The $80 value represents silence (midpoint of unsigned 8-bit audio).

### Control Registers (starting at $F14800)

| Offset | Name | Value | Notes |
|--------|------|-------|-------|
| $800 | **Version** | **$E8** | Confirmed: ASC chip present |
| $801 | Mode | $01 | FIFO mode active |
| $802 | Control | $01 | |
| $803 | FIFO Status | $00 | FIFOs empty/idle |
| $804 | FIFO IRQ Status | $03 | Both channel IRQs? |
| $805 | Wave Control | $00 | Wavetable inactive |
| $806 | Volume | **$60** | ~37.5% volume |
| $807+ | (remaining) | $00 | Unused/zero |

### ASC Analysis

- **Version $E8** confirms this is the standard ASC (not EASC or other variant). Our stub
  returns this correctly.
- **Mode $01** = FIFO playback mode (vs $00 = off, $02 = wavetable synthesis).
  System 7 uses FIFO mode for alert sounds and UI feedback.
- **Volume $60** = the system volume setting. Our stub doesn't track this.
- **FIFO reads as $80** = silence. Important: our stub doesn't implement the FIFO buffer
  at all. Real ASC has 2×1KB FIFO at offsets $000-$3FF and $400-$7FF.

---

## IWM/SWIM ($F16000 - $F17FFF)

| Addr | Reg | Value | Notes |
|------|-----|-------|-------|
| $F16000 | 0 (CA0 off) | $FF | |
| $F16100 | 1 (CA0 on) | $FF | |
| $F16200 | 2 (CA1 off) | $72/$3D | Alternating pattern |
| $F16300 | 3 (CA1 on) | $72/$3D | |
| $F16400 | 4 (CA2 off) | $FF | |
| $F16500 | 5 (CA2 on) | $FF | |
| $F16600 | 6 (LSTRB off) | $72/$3D | |
| $F16700 | 7 (LSTRB on) | $72/$3D | |
| $F16800 | 8 (ENABLE off) | $FF | |
| $F16900 | 9 (ENABLE on) | $FF | Confirmed in 2nd session |
| $F16A00 | 10 (SELECT off) | $72/$3D | |
| $F16B00 | 11 (SELECT on) | $72/$3D | |
| $F16C00 | 12 (Q6 off) | $FF | |
| $F16D00 | 13 (Q6 on) | $FF | |
| $F16E00 | 14 (Q7 off) | $72/$3D | Status register |
| $F16F00 | 15 (Q7 on) | $72/$3D | |

**$F19000: BUS ERROR** - Correctly outside IWM range. Confirms $F16000-$F17FFF boundary.

### IWM Pattern Analysis

Two distinct values appear:
- **$FF** at even registers (0, 1, 4, 5, 8, 12, 13)
- **$72/$3D alternating** at odd registers (2, 3, 6, 7, 10, 11, 14, 15)

The $723D pattern in 16-bit reads suggests the SWIM chip returns different data on
even vs odd byte addresses within each register. This is consistent with the SWIM
(not IWM) having a different bus interface.

**Status register ($F16E00):** The $72 value = 0111_0010. For IWM status, this indicates:
- Bit 5: Motor on
- Other bits: Various sense line states

This data suggests the floppy controller is actually a **SWIM** (as TattleTech reported),
not a pure IWM. Our core only implements IWM. The alternating byte pattern may be
SWIM-specific behavior that our IWM implementation doesn't replicate.

---

## Ariel RAMDAC ($F24000 - $F25FFF)

The RAMDAC has auto-incrementing behavior, so sequential reads advance the palette pointer.

First read at $F24000: `00B2 8800 00B2 8800 01B2 8800 0195 8800`

The palette data reads at $F24002 show sequential RGB values with auto-increment.
Each subsequent `dm F24002` returns different data as the pointer advances through
the 256-entry CLUT:
- Read 1: entries ~0-2 (palette start)
- Read 2: entries ~3-5
- Read 3: entries ~6-8
- Read 4: entries ~9-11

The control byte at $F24004 appears to be **$88** based on the repeating pattern.

**Note:** The auto-increment behavior makes it hard to read specific entries via `dm`.
A more targeted approach would be: write address to $F24000, then read exactly 3 bytes
from $F24002 for one R,G,B entry.

---

## PseudoVIA / RBV ($F26000 - $F27FFF)

### CRITICAL FINDING: Register Mirroring

The dump reveals a **4-byte repeating pattern** in native mode:

At $F26000: `4F E6 3F 92 4F E6 3F 92 4F E6 3F 92 ...`

This means the V8 chip only decodes **2 address bits** (A1:A0) within each register
group, plus **bit A4** to select between two groups. Registers mirror every 4 bytes.

### Native Mode Registers

**Group 0** (offsets $00-$0F, mirrored every 4 bytes):

| Offset | Name | Value | Binary | Notes |
|--------|------|-------|--------|-------|
| $00 | Port B | **$4F** | 0100_1111 | |
| $01 | RAM Config | **$E6** | 1110_0110 | 10MB RAM encoding |
| $02 | Slot/VBlank Status | **$3F** | 0011_1111 | VBlank active (bit 6=0) |
| $03 | IFR | **$92** | 1001_0010 | IRQ pending, slot IRQ |

**Group 1** (offsets $10-$1F, mirrored every 4 bytes):

| Offset | Name | Value | Binary | Notes |
|--------|------|-------|--------|-------|
| $10 | Video Config | **$10** | 0001_0000 | Monitor ID=2, bpp=0 |
| $11 | (unknown) | **$00** | 0000_0000 | |
| $12 | Slot IER | **$78** | 0111_1000 | Slots 3-6 enabled |
| $13 | IER | **$0A** | 0000_1010 | Bits 3,1 enabled |

### VIA-Compatible Mode

All VIA-compat mode reads return native Group 0 register data:

| Addr | VIA-compat Reg | Expected | Actual | Notes |
|------|---------------|----------|--------|-------|
| $F26200 | 1 (Port A) | Port A data | **$47 E6 3F 92** | Returns native Group 0 pattern |
| $F27A00 | 13 (IFR) | IFR value | **$4F E6 3F 92** | Returns native Group 0 pattern |
| $F27C00 | 14 (IER) | IER value | **$4F E6 3F 92** | Returns native Group 0 pattern |

**IMPORTANT FINDING:** VIA-compat mode does NOT provide a separate register bank on real
V8 hardware. All three tested VIA-compat registers return the same native Group 0 data
(Port B, RAM Config, Slot Status, IFR). The $47 vs $4F difference in Port B between
sessions is expected - bit 3 is a live Egret input that toggles dynamically.

Our `pseudovia.sv` implements VIA-compat mode as a separate register space (Port A returns
$D5, IFR/IER have independent storage). This does not match real hardware. The VIA-compat
mode address range ($F26100-$F27FFF) likely just aliases to the native registers, with the
upper address bits being ignored.

### PseudoVIA Analysis

**RAM Config ($E6) - MAJOR DISCREPANCY:**
Our core returns $04-$07 (2-bit encoding). Real hardware returns **$E6** for 10MB.
The encoding is:
- $E6 = 1110_0110
- Our core's 2-bit `ram_config` input is insufficient. The V8 likely encodes both
  soldered RAM and SIMM size independently.
- Need to research MAME's v8.cpp for the full encoding table.

**Video Config ($10):**
- Bits 5:3 = **010** → Monitor ID = 2 (12" RGB, 512×384)
- Bits 2:0 = **000** → Video mode 0 (1bpp)
- This tells us what monitor was connected. If running in 1bpp that's the system
  default for the 12" monitor.

**Slot/VBlank Status ($3F = 0011_1111):**
- Bit 6 = 0 → VBlank IS active (active low). Matches our core's formula.
- Bit 5 = 1 → No slot IRQ
- Bit 4 = 1 → No ASC IRQ
- Bits 3-0 = 1111 → No other slot IRQs
- Our core's implementation: `{1'b0, ~vblank_irq, ~slot_irq, ~asc_irq, 3'b111, 1'b1}`
  matches this format.

**Slot IER ($78 = 0111_1000):**
- Bits 6,5,4,3 enabled → VBlank, slot, ASC, slot0 interrupts all enabled
- Our core stores this correctly.

**IER ($0A = 0000_1010):**
- Bits 3,1 enabled
- Bit 1 = slot IRQ summary enable

**Register Mirroring - IMPORTANT FOR CORE:**
Our `pseudovia.sv` uses `addr[7:0]` for full 256-byte register decode. Real hardware
mirrors with only ~6 decoded address bits (A4, A1, A0 minimum). This means our core
accepts writes to "registers" $04-$0F as separate storage, but real hardware treats them
as mirrors of $00-$03. This could cause bugs if software writes to mirrored addresses
expecting them to alias.

**Port B is dynamic:** Confirmed across two sessions - Port B value changed from $4F to
$47 (bit 3 toggled). Bit 3 is the Egret input line and changes in real-time. The 4-byte
mirroring pattern reflects this: the mirror at offset $04 shows the same live value as
offset $00.

---

## VRAM ($F40000 - $FBFFFF)

$F40000: First ~64 bytes mostly zeros (black pixels at top-left of screen), then
dithered patterns ($AAAA, $B6DB6DB6) which represent the classic Mac desktop pattern.
This confirms VRAM is mapped correctly at $F40000.

---

## ROM ($A00000)

| Offset | Value | Notes |
|--------|-------|-------|
| $A00000 | **$350EACF0** | ROM checksum - matches TattleTech ($350EACF0) |
| $A00004 | $0000002A | |
| $A00008 | $067C | ROM version $67C (124) - matches TattleTech |
| $A0000C | $4EFA0080 | JMP instruction (reset vector) |

ROM is confirmed present and matches expected checksums.

---

## RAM Boundaries

| Address | Result | Interpretation |
|---------|--------|----------------|
| $000000 | Readable | RAM present (low memory vectors visible) |
| $3FFFC0 | Readable | RAM present through 4MB |
| $7FFFC0 | Readable | RAM present through 8MB |
| $9FFFC0 | Readable | RAM present through 10MB |

All 10MB of RAM is accessible. At $9FFFE0 the string "WLSC" is visible - this appears
to be a system-placed marker in high memory.

No bus errors at any RAM boundary, confirming full 10MB contiguous RAM.

---

## Summary of Discrepancies (Core vs Real Hardware)

### Critical

1. **PseudoVIA RAM Config register:** Core returns $04-$07, real hardware returns $E6
   for 10MB. Encoding is completely different and needs MAME research.

2. **PseudoVIA register mirroring:** Real V8 mirrors native registers every 4 bytes
   (only A4, A1:A0 decoded). Our core decodes full addr[7:0]. May cause issues.

3. **SCSI DRQ at $F06000:** Bus error on real hardware when SCSI idle. Our core
   always responds. May need DRQ gating.

### Moderate

4. **ASC FIFO buffer:** Real hardware has 2×1KB FIFO reading as $80 (silence).
   Our stub has no FIFO at all.

5. **ASC registers:** Real hardware has Mode=$01, Volume=$60, FIFO IRQ=$03.
   Our stub may not track these correctly.

6. **SWIM vs IWM:** Real hardware shows SWIM-specific behavior ($72/$3D alternating
   pattern). Our core only implements IWM.

### Minor / Still Outstanding

7. **VIA-compat mode PseudoVIA:** Now confirmed - all VIA-compat reads return native
   Group 0 data. Our core's separate VIA-compat register bank is wrong.

8. **VIA1 Reg 4 (T1C-L):** Still missing. Need: `dm F00800 2` (low priority - timer counter)

9. **VIA1 Reg 11 (ACR):** Still missing. Need: `dm F01600 2` (useful - shows timer/SR modes)

## Remaining Commands

These two VIA1 registers are still unread (low priority):

```
dm F00800 2       ; VIA1 Reg 4 - Timer 1 Counter Low
dm F01600 2       ; VIA1 Reg 11 - ACR (Auxiliary Control Register)
```
