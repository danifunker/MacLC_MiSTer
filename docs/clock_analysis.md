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
