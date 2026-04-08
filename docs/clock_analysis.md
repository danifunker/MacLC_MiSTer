# MacLC MiSTer Clock Analysis

Comparison of FPGA implementation clocks vs MAME reference (real hardware specs).

## Base Crystal

| | Real Hardware | FPGA | Delta |
|---|---|---|---|
| System crystal | 31.3344 MHz (C32M) | 32.5 MHz | +3.7% |

Real Mac LC uses a 31.3344 MHz crystal. Our PLL generates 32.5 MHz from DE10-Nano's 50 MHz input (50 × 13/10 = 65 MHz, /2 = 32.5 MHz). All derived clocks inherit the +3.7% offset.

## Clock Comparison

| Clock | Real HW (MAME) | FPGA | Delta | Notes |
|-------|----------------|------|-------|-------|
| CPU (68020) | 15.6672 MHz (C32M/2) | 16.25 MHz | +3.7% | |
| 8 MHz bus | 7.8336 MHz (C32M/4) | 8.125 MHz | +3.7% | |
| VIA E clock | 783.36 kHz (C15M/20) | ~812.5 kHz (16.25M/20) | +3.7% | eCntr 0-9, E_div=1 |
| Egret HC05 | 4.1943 MHz (32768×128) | ~4.066 MHz (32.5/8) | **-3.1%** | PLL outclk_2 (4.194 MHz) exists but unused |
| SCC | 7.8336 MHz (C7M) | 8.125 MHz | +3.7% | |
| SCC baud gen | 3.6864 MHz | Not checked | | |
| Video pixel | 25.175 MHz (VGA) | 16.25 MHz | -35% | Expected: MiSTer framework scales |
| Audio sample | 22,257 Hz (DFAC) | ~22 kHz | ~0% | |

## Egret/VIA Timing Ratio

The relative speed between Egret and VIA matters for the SR handshake protocol.

| | Real HW | FPGA | Delta |
|---|---|---|---|
| Egret / VIA_E ratio | 5.35:1 | 5.00:1 | -6.5% |

The Egret is slightly slower relative to the VIA than on real hardware. Protocol is edge-driven so this shouldn't break handshake, but timing windows differ.

## PLL Configuration (rtl/pll/pll_0002.v)

- Input: 50 MHz (CLK_50M from DE10-Nano)
- outclk_0: 65 MHz (clk_mem → SDRAM)
- outclk_1: 32.5 MHz (clk_sys → everything else)
- outclk_2: 4.194304 MHz (**unused** — intended for Egret)

## Clock Derivation Tree

```
50 MHz (DE10-Nano)
└─ PLL
   ├─ 65 MHz (clk_mem) → SDRAM controller
   ├─ 32.5 MHz (clk_sys)
   │  ├─ /2 → 16.25 MHz (clk16_en_p/n) → CPU, pixel clock
   │  ├─ /4 → 8.125 MHz (clk8_en_p/n) → bus, peripherals
   │  │  └─ /135078 → 60.15 Hz (tick_60hz) → VIA CA1
   │  ├─ /20 → 812.5 kHz (E clock via eCntr) → VIA
   │  └─ /8 → 4.066 MHz (Egret cen) → HC05
   └─ 4.194 MHz (outclk_2) → UNUSED
```

## E Clock Generation (rtl/tg68k/tg68k.v)

E_div=1 causes en_E to toggle every phi1, halving the counter rate:
- eCntr counts 0→9 (10 states) at half phi2 rate
- phi2 = clk16_en_n = 16.25 MHz
- E period = 20 × (1/16.25 MHz) = 1.231 µs → ~812.5 kHz
- Real: 15.6672 MHz / 20 = 783.36 kHz

## Potential Improvements

1. **Use PLL outclk_2 for Egret** — Would give exact 4.1943 MHz instead of approximate 4.066 MHz. Requires clock domain crossing since it's a separate clock domain.
2. **Adjust PLL for closer base frequency** — 31.3344 MHz is hard to derive cleanly from 50 MHz. Would need fractional-N PLL settings.
3. **VIA E clock** — Proportionally correct (C32M/20×2), just inherits base crystal error.

## 2026-04-08 Audit — Findings vs. Current Wiring

Cross-checked `MacLC.sv:215-221`, `rtl/pll.v` XML metadata, and
`docs/plan_040526.md` against this document's reference table.

### What the PLL actually generates

`rtl/pll.v` defines outputs `outclk_0..outclk_17`. Only the first three
are interesting; the rest sit at default 100 MHz placeholders and are
unused.

| outclk | Frequency       | Wired in `MacLC.sv` | Purpose            |
|--------|-----------------|---------------------|--------------------|
| 0      | 65.0 MHz        | `clk_mem`           | SDRAM controller   |
| 1      | 32.5 MHz        | `clk_sys`           | Everything else    |
| 2      | 4.194304 MHz    | **NOT WIRED**       | Intended for Egret |
| 3..17  | 8.125 / 100 MHz | unused              | —                  |

### Issues to fix (priority order)

1. **Egret HC05 is on the wrong clock — and the right clock already
   exists in the PLL but is dangling.** `outclk_2` is configured for
   exactly 4.194304 MHz (the real C8M÷2 / 32768×128 Egret rate), but
   `MacLC.sv:215` only wires `outclk_0` and `outclk_1`. Egret currently
   runs at 4.066 MHz derived as `clk_sys/8` — **−3.1% slow**, opposite
   sign from the rest of the system's +3.7% skew, so the Egret-vs-VIA
   timing ratio is doubly wrong (see "Egret/VIA Timing Ratio" above:
   real 5.35:1, current 5.00:1, −6.5%). Fix requires:
   - adding `.outclk_2(clk_egret)` to the `pll` instantiation
   - feeding `clk_egret` into `egret_wrapper` as a separate clock domain
   - CDC handshake on the VIA SR / TIP / TACK signals between `clk_sys`
     and `clk_egret`

2. **SCC baud generator is mis-sourced.** Real Z8530 derives baud rates
   from a 3.6864 MHz RTxC input. The current implementation in
   `rtl/scc.v` feeds the BRG directly with `clk_sys` (32.5 MHz) and
   uses fudged baud constants (e.g. `baud_divid_speed_a <= 24'd3385`
   for "9600 baud at 32.5 MHz"). `docs/plan_040526.md:137-143` proposes
   a Bresenham divider in `rtl/v8_clocks.sv` producing a 3.672 MHz
   `rtxc_en` clock-enable from `clk_sys` (32.5e6 / 3.672e6 ≈ 8.851,
   `+5/−4` accumulator gives <1% error). **Status: unimplemented as of
   the latest commit.** Not a PLL change — a clock-enable change inside
   the SCC's existing `clk_sys` domain.

3. **System-wide +3.7% skew.** 50 × 13/10 / 2 = 32.5 MHz is the best
   simple integer ratio from a 50 MHz reference; getting 31.3344 MHz
   exactly requires fractional-N PLL settings. Documented compromise,
   inherits to CPU, bus, VIA E, video timer. Not boot-breaking.

### Audit caveats

This audit verified against MAME's reference numbers as documented in
this file's "Clock Comparison" table — those constants were not
independently re-fetched from MAME source or Apple's *Mac LC Developer
Note*. If precise verification matters before implementing #1, fetch
`mame/src/mame/apple/maclc.cpp` (or the V8 chip definition) and confirm
the C32M / Egret-clock numbers.

### Are clocks responsible for the boot hangs?

- **AppleTalk hang at `0xA49F00` (sim + FPGA both):** unlikely. The loop
  is a `move.b → btst → beq` against SCC RR0 that fires whenever a TX
  byte echoes back. A 3.7% skew or wrong baud doesn't change whether
  the byte echoes — our SCC has no SDLC framing at all. Fix #2 won't
  unblock this loop on its own.
- **FPGA-only boot failure (CPU runs into unmapped 0xCxxxxx — see
  `fpga_boot_debug_2026_03_21.md`):** more plausibly clock/SDRAM
  related, but symptom is more consistent with an SDRAM data-path bug
  than with PLL frequency error. If the PLL were catastrophically wrong
  the CPU would not execute at all.
