# Porting the Snow-Style VIA1 SR / ADB Bypass from lbmactwo_MiSTer

Reference commit: `b082082` in `../lbmactwo_MiSTer`
("via1: Snow-style timer-based shift register for ADB")

## Summary of the lbmactwo fix

Snow emulates the VIA1 shift register as a **pure timer** instead of requiring
8 CB1 edges. The ROM's ADB init writes VIA1 ACR → shift-out + SR data, then
spins on IFR bit 2. The real CB1 clock chain can be flaky in sim, hanging boot
in a `BTST #5` loop at `$40806DD8`. Fix: after a ~3 ms delay, synthesize the
"SR complete" interrupt and hand the byte directly to the ADB transceiver.

With the bypass, lbmactwo boot advanced past the BTST loop and past the SCC
serial-diagnostic loop (next stall at `$4080329E`).

## Port plan for MacLC_MiSTer

### 1. `rtl/via6522.sv` — add three input ports + completion hook

```verilog
input  wire       sr_ext_complete,
input  wire       sr_ext_load,
input  wire [7:0] sr_ext_data,
```

In the SR always block, on `sr_ext_complete`:
- clear `shift_active`
- clear `bit_cnt`
- set `irq_flags[2]` (SR-complete interrupt)
- if `sr_ext_load`, load `shift_reg <= sr_ext_data`

Our `via6522.sv` matches lbmactwo's structure, so the diff applies almost
verbatim.

### 2. `rtl/dataController_top.sv` — bus-level detector + countdown timer

At the VIA1 instantiation (~line 554) wire the three new ports. On any second
VIA instance, tie them to 0 / `8'h00`.

Add a ~90-line always block that:

- Watches `selectVIA && !_cpuVMA && !_cpuRW` with `cpuAddrRegHi == 4'hA` (SR)
  / `4'hB` (ACR).
- Shadows ACR shift-mode bits. On transitions into `3'b111` (shift-out) or
  `3'b011` (shift-in), or on SR write while in those modes, loads
  `via1_shift_timer <= 100_000` (~3 ms @ 32.5 MHz — `SHIFT_DELAY`).
- On expiry: pulses `via1_sr_ext_complete`.
  - shift-out: also pulses `adb_din_strobe` / `adb_din <= via1_sr_shadow`.
  - shift-in: pulses `sr_ext_load` with `sr_ext_data <= kbd_to_mac`.

### Signal name mapping (lbmactwo → MacLC)

- `via1_sr_active` → MacLC's `via_sr_active` (rename new wires to
  `via_sr_ext_*` for consistency).
- `cpuAddrRegHi`, `_cpuVMA`, `_cpuRW`, `selectVIA`, `cpuDataIn`, `kbd_to_mac`,
  `adb_din`, `adb_din_strobe` all already exist in MacLC under the same names.
- The `machineType` gate (`if (via1_sr_out_done && machineType)`) is
  Mac II-specific — **drop it for MacLC** and deliver unconditionally.

## Caveats specific to this project

1. **MacLC boots via Egret, not raw VIA1 ADB.** ADB traffic goes through the
   HC05 Egret, not directly through VIA1's SR. Unless an ADB code path also
   pokes VIA1 SR (e.g. ROM self-test), the bypass may be a no-op. **Verify
   the ROM actually hits the VIA1 SR path before porting.**
2. **VIA SR simulation sensitivity** — per `CLAUDE.md`, any `via6522.sv` SR
   change must be verified with `--screenshot 350` to confirm the memory-test
   grey/black pattern still renders. Adding new inputs gated behind a
   `sr_ext_complete` branch should be safe (branch only enters on pulse),
   but run the check.
3. **Quartus single-driver rule** — the new `via1_shift_timer` logic must
   live in exactly one `always` block; don't split SR/ACR detection and
   countdown across blocks.
4. The lbmactwo commit also adds unrelated artifacts (Snow trace Rust tool,
   `boot2.rom`, debug doc) — skip those; only the two RTL files are needed.

## Verification

After port:

```bash
cd verilator && make clean && make
./obj_dir/Vemu --screenshot 350 --stop-at-frame 351 2>/dev/null 1>/dev/null
```

Check `screenshot_frame_0350.png` still shows the grey/black memory-test
pattern (regression guard for the VIA SR change), then run a longer boot to
see whether any previously-stuck VIA1-SR path now advances.
