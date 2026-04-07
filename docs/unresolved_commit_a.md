# Commit A — Unresolved Items

Commit A (`4ae3f06`) landed cpuAddr widening + diagnostic infra, but the headline value (real BERR-on-unmapped) is **disabled**. Engaged plan's escape hatch.

## BERR storm addresses

Enabling `(!_cpuAS && cpuBusControl && selectUnmapped)` in `cpu_berr` regresses boot to a uniform-grey screen. CPU storms BERR on these 4 addresses during early ROM init:

| Address    | FC  | RW | Notes |
|------------|-----|----|----|
| `$000000`  | 101 | 1  | supervisor data read; overlay-timing artifact, ROM is supposed to be there |
| `$000002`  | 101 | 1  | same |
| `$F21C00`  | 101 | 1  | unmapped peripheral hole between SWIM (`$F16xxx`) and Ariel (`$F24xxx`). Likely a real LC peripheral we don't model |
| `$FC0000`  | 101 | 1  | gap between VRAM end (`$FBFFFF`) and `$Fxxxxx` peripheral region |

Diagnostic captured 41 events during boot; the unique-address set above is what BERR would trip on.

## Why BERR can't just be re-enabled

1. **TG68 68020 mode is incomplete.** `rtl/tg68k/TG68KdotC_Kernel.v` line 218 comment: `// 00->68000  01->68010  11->68020(only some parts - yet)`. 68020 BERR needs format `$A`/`$B` stack frames (~46–92 bytes with pipeline state). TG68 likely emits a 68000-style 14-byte frame → ROM's BERR handler reads garbage off the stack → CPU explodes.

2. **`clr_berr` is dangling** in the wrapper. `rtl/tg68k/TG68K.v:217` — `.clr_berr ( /*tg68_clr_berr*/ )`. The kernel's BERR-latch ack path is unwired. Not the immediate blocker (our `cpu_berr` is combinational and drops with AS), but means there's no host-visible "BERR consumed" handshake.

3. **`IPL_autovector` is hard-tied to `1'b0`** at `TG68K.v:215`. Autovector is implemented via the BERR-during-IACK convention (`cpuFC == 3'b111`) rather than the proper input. That's why flipping `verilator/sim.v`'s `.berr(1'b0)` to autovector (which would have given parity with `MacLC.sv`) regressed sim boot — IRQ handling depends on the existing path.

## Possible peripherals we don't model that might own these addresses

- `$F21C00` is in the V8 register region. Could be a V8 internal register, VIA2 mirror, or PDS-related. Worth cross-referencing `schematics/LC_Master_Netlist.csv` and the V8 schematic audit notes.
- `$FC0000` could be a mirror of something earlier in `$Fxxxxx`, or sense input space. Less likely a missing peripheral, more likely a probe.
- `$000000`/`$000002` is overlay ROM territory — these might fire post-overlay-disable from a stale fetch, in which case it's a timing bug not a missing device.

## Paths forward (in order of cost)

**(a) Sidestep — pre-filter at decoder.** Make `addrController_top`/`addrDecoder` return a quiet dummy read (e.g. `$FFFF`) for the 4 known addresses instead of `selectUnmapped`. Cheap, unblocks FPGA `0xCxxxxx` debug. Doesn't fix the underlying TG68 BERR issue.

**(b) Investigate `$F21C00` specifically.** Check schematics / MAME `v8.cpp` decode table for what real hardware does with that address. Might be a known register we can stub.

**(c) Audit TG68 68020 BERR + wire `clr_berr`.** Read `TG68KdotC_Kernel.v` (GHDL-converted Verilog from `how-to-convert-cpu.txt`) for `trap_berr`, stack frame format generation. Hard.

**(d) CPU core swap.** No mature open synthesizable 68020 core known. Musashi is software-only. Multi-week effort, wrong tool for unblocking the boot.

## How to apply

When resuming Commit A or chasing the FPGA `0xCxxxxx` stall, start with (a) to get visibility, then (b) to understand `$F21C00`. Don't re-enable real BERR until at least the TG68 stack frame question is answered.

## Related

- `docs/plan_040526.md` — original plan, Commit A description
- `4ae3f06` — what actually landed
