# ADB ↔ Egret Wiring: MAME Reference vs Our Core

Cross-reference with MAME source: `../mame/src/mame/apple/maclc.cpp`,
`../mame/src/mame/apple/egret.cpp`, `../mame/src/mame/apple/macadb.cpp`.

## How MAME wires ADB on the Mac LC

From `maclc.cpp` ~line 418–433, the LC config connects three logical buses
between V8 (VIA), Egret (HC05), and MacADB (bit-level ADB bus):

### Host ↔ Egret handshake (VIA Port B + shift register)
```
v8.pb3 → egret.get_xcvr_session   // host reads XCVR_SESSION/TREQ
v8.pb4 → egret.set_via_full       // host writes VIA_FULL/BYTEACK
v8.pb5 → egret.set_sys_session    // host writes SYS_SESSION/TIP
egret.via_clock_callback → v8.cb1_w   // Egret drives VIA CB1 (shift clock)
egret.via_data_callback  → v8.cb2_w   // Egret drives VIA CB2 (shift data in)
v8.cb2_callback → egret.set_via_data  // VIA CB2 (shift data out) → Egret
```

### Egret ↔ ADB devices (bit-level ADB line)
```
egret.linechange_callback → macadb.adb_linechange_w  // Egret drives ADB line
macadb.adb_data_callback  → egret.set_adb_line       // Keyboard/mouse drive ADB line back
```

Internally in `egret.cpp`:
- `pa_w` bit 7 = ADB line **output** from Egret (writes `m_adb_in`,
  calls `write_linechange(...)`).
- `pa_r` bit 6 = ADB line **input** to Egret (reads `m_adb_in`).

So on real hardware the Egret HC05 has a single open-drain pin that is
both driven (PA7) and sampled (PA6), and `macadb` does the wire-OR with
any ADB device pulling the line low.

## How our core is wired today

We already have the host↔Egret handshake correct. `rtl/egret/egret_wrapper.sv`
even exposes the right pins:

```verilog
input  wire  adb_data_in,   // PA bit 6 — ADB line sampled into HC05
output reg   adb_data_out,  // PA bit 7 — ADB line driven by HC05
```

**But at instantiation in `rtl/dataController_top.sv` they are tied off:**

```verilog
// line 654-656 (USE_EGRET_CPU branch)
// ADB (not implemented yet)
.adb_data_in    (1'b1),
.adb_data_out   (),
```

…and again at line 707–709 in the `cuda_maclc` branch.

Instead, the `adb` module (lines 891+) is wired directly to the **VIA1
shift register** path (`kbd_to_mac`, `adb_din`, `adb_din_strobe`). That is
the legacy MacPlus-style ADB transceiver, where the 68K ROM talks to a
keyboard attached directly to VIA1's SR — **there is no Egret in that
path at all**. It's vestigial code inherited from the MacPlus core.

### Why this blocks boot

On the LC, the ROM's ADB init writes commands through VIA1 SR → CB1/CB2
→ Egret, expecting Egret to return ADB device data via the same CB1/CB2
shift path. Egret only has something to return if it can actually talk
to ADB devices on its PA6/PA7 pins. With PA6 hard-tied to `1'b1` and
PA7 left unconnected, Egret sees an idle ADB bus forever, never finds
keyboard/mouse, and never produces the response bytes the ROM expects.

This matches the symptom: the host side of the Egret handshake runs, 68
transactions complete (per `egret-protocol-fix` memory), but ADB device
enumeration never succeeds and the ROM hangs waiting.

## Fix plan — port MAME's wiring model

### Option A (minimum viable — matches MAME exactly)

1. **Delete / bypass** the legacy `adb adb(...)` instantiation at line 891
   and its VIA1-SR wiring (`kbd_to_mac`, `adb_din`, `adb_din_strobe`,
   `kbdclk` machinery in the kbd_transmitting block). This was the
   MacPlus path and does not belong in an LC with Egret.

2. **Build a bit-level ADB transceiver** that presents the wire-OR line
   to Egret. Inputs: PS/2 keyboard + mouse (we already decode them in
   `rtl/ps2_kbd.sv` / `rtl/ps2_mouse.v`). Output: a single `adb_line`
   net with open-drain semantics.

   This module needs to implement the ADB bus timing: attention pulse
   (800 µs low), sync (65 µs), command byte, stop bit, Tlt, then data
   packet with start/stop bits. See `src/mame/apple/macadb.cpp` for the
   reference state machine — it is compact and well-commented.

3. **Connect Egret's PA6/PA7 to the new transceiver** at both
   instantiation sites:
   ```verilog
   .adb_data_in  (adb_line),          // sampled by HC05 PA6
   .adb_data_out (egret_adb_drive),   // driven by HC05 PA7
   ```
   Where `adb_line = egret_adb_drive & kbd_adb_drive & mouse_adb_drive;`
   (wire-OR: any device pulling low wins).

### Option B (staging — unblock boot faster)

If building a full bit-level ADB transceiver is too much for a first
pass, the minimum to get Egret past init is to fake a
"self-test passes, no devices present" response:

- Wire `adb_data_in` to a simple model that follows `adb_data_out`
  (loopback with a small delay) so Egret's ADB self-test passes.
- See whether the LC ROM can then proceed past ADB init even with no
  devices enumerated.

This would confirm the diagnosis before investing in the full bit-level
state machine.

## Files to touch

- `rtl/dataController_top.sv` — remove legacy `adb adb(...)`
  instantiation, replace PA6/PA7 tie-offs at lines 655 and 708 with real
  wiring.
- `rtl/adb.sv` — either repurpose or delete; it's VIA1-SR-era code.
- **New:** `rtl/adb_bus.sv` (or similar) — bit-level ADB transceiver
  modeled on `macadb.cpp`, taking PS/2 keyboard + mouse events and
  producing an open-drain ADB line.

## Comparison to the Snow bypass idea

The Snow bypass (`docs/adb_snow_bypass.md`) is a workaround for a
**different** bug — Mac II-style cores where the ROM drives the VIA1 SR
directly and CB1 clocking is unreliable in sim. Our LC core already has
VIA SR ↔ Egret CB1/CB2 working (evidenced by the 68 successful
transactions at frame 350). Our problem is one layer deeper: the Egret
has nothing to say because its ADB-side pins are unconnected.

**Recommendation: pursue the MAME-style wiring instead of the Snow
bypass.** The bypass wouldn't help here because the stall isn't in VIA
SR timing, it's in ADB device enumeration behind the Egret.

## Verification

After wiring:

```bash
cd verilator && make clean && make
./obj_dir/Vemu --screenshot 350 --stop-at-frame 351 2>/dev/null 1>/dev/null
# Expect: memory-test grey/black pattern still renders (regression guard)

./obj_dir/Vemu --stop-at-frame 600 2>verilator/sim.err 1>verilator/sim.out
# Expect: boot advances past ADB init; grep sim.err for Egret ADB traces
```

Compare against MAME's `egret_init.log` (already present in `../mame/`)
to A/B the ADB line activity during the first 50 ms of boot.
