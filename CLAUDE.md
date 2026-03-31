# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Macintosh LC emulation core for the MiSTer FPGA platform. It's based on the MacPlus core by Sorgelig, which originated from the Plus Too project. The core emulates the Motorola 68000 CPU and various Macintosh peripherals.

**Current development focus:** The `change-to-verilog-cpu` branch is converting from TG68K (VHDL-based) to FX68K (pure Verilog) CPU implementation.

## Build Commands

### FPGA Build (Quartus)
The project uses Intel Quartus 17.0.2 Lite Edition:
- Open `MacLC.qpf` in Quartus
- Compile to generate RBF output in `output_files/`
- Deploy RBF to MiSTer SD card root

### Verilator Simulation
```bash
cd verilator
make        # Build simulator
make clean  # Clean build artifacts
./obj_dir/Vemu  # Run interactive simulator (requires SDL2, OpenGL)
```

#### Simulator Command Line Options
```bash
./obj_dir/Vemu --help                    # Show all options
./obj_dir/Vemu --screenshot 360          # Take screenshot at frame 360
./obj_dir/Vemu --stop-at-frame 400       # Exit after frame 400
./obj_dir/Vemu --screenshot 360 --stop-at-frame 361  # screenshot
```

Key options:
- `--screenshot <frame>` - Save PNG screenshot at specified frame number
- `--stop-at-frame <frame>` - Exit simulation after reaching frame count
- `--trace` - Enable FST waveform tracing (outputs to `trace.fst`)

Note: Boot takes approximately 360 frames to reach the Mac desktop.
Note: No hard drive is configured in the simulator, so the desktop won't fully load.

#### Boot Verification
```bash
cd verilator
./check_boot.sh              # Analyze existing cpu_trace.log
./check_boot.sh --run        # Run 30 frames + analyze
./check_boot.sh --run 100    # Run N frames + analyze
```
Exit codes: 0=PASS, 1=FAIL, 2=missing log. Suitable for pre-commit hooks.

#### Simulation Logs
- **CPU trace log:** `verilator/cpu_trace.log` - Contains 68K CPU instruction trace
- **Console output (stderr):** Contains HC05 (Egret) traces, VIA/peripheral debug messages
- **Important:** Do NOT re-run the simulator multiple times when diagnosing. Run once, then analyze the log files.

## Architecture

### Top-Level Module
- `MacLC.sv` - Main system module (module name: `emu`)
- Entry point for the MiSTer framework via `sys/sys_top.v`

### RTL Structure (`/rtl`)

**CPU Cores:**
- `fx68k/` - Cycle-accurate Motorola 68000 in Verilog (active)
- `tg68k/` - TG68K CPU core (being phased out)

**Memory & Storage:**
- `sdram.v` - SDRAM controller
- `scsi.v`, `ncr5380.sv` - SCSI hard drive interface
- `floppy.v`, `floppy_track_encoder.v` - Floppy drive emulation

**I/O Peripherals:**
- `via6522.sv` - Versatile Interface Adapter (parallel I/O, timers)
- `pseudovia.sv` - VIA emulation for LC models
- `iwm.v` - Integrated Woz Machine (floppy controller)
- `scc.v` - Serial Communication Controller
- `adb.sv` - Apple Desktop Bus
- `ps2_kbd.sv`, `ps2_mouse.v` - Keyboard/mouse input
- `rtc.v` - Real-Time Clock
- `uart/` - UART TX/RX modules

**Video Subsystem:**
- `maclc_v8_video.sv` - Mac LC Video Engine (V8)
- `ariel_ramdac.sv` - Video DAC
- `videoTimer.v`, `videoShifter.v` - Video timing/data
- `addrController_top.v`, `addrDecoder.v` - Address generation
- `dataController_top.sv` - Data control

### System Framework (`/sys`)
Standard MiSTer framework files (video scaling, HPS I/O, audio output). Generally should not need modification for core-specific work.

## Key Technical Details

- **Target FPGA:** Cyclone V (MiSTer DE10-Nano)
- **System clock:** Generated via `rtl/pll.v`
- **Memory:** 1MB/4MB RAM configurations, DDR3 SDRAM interface
- **Video modes:** 1/2/4/8/16 bpp
- **CPU speeds:** 8 MHz (original) or 16 MHz

## File Locations

- `files.qip` - Lists all RTL source files for Quartus
- `MacLC.qsf` - Quartus project settings
- `releases/` - Pre-built RBF files and ROM images

## CPU Conversion Notes

When working with CPU cores, see `how-to-convert-cpu.txt` for GHDL-based VHDL to Verilog conversion process using:
```bash
ghdl synth -fsynopsys -fexplicit --latches --out=verilog
```

## Verilator vs Quartus Compatibility

**Critical:** Verilator allows multiple `always` blocks to drive the same `reg`, but Quartus does not (Error 10028: "Can't resolve multiple constant drivers"). When writing or modifying RTL:

- Each `reg` must be driven from exactly **one** `always` block for Quartus synthesis
- If timer logic, PRAM loading, or other hardware needs to write the same register as a CPU write path, **merge them into a single `always` block**
- Use `if/else if` priority within the block to handle the different write sources
- Verilator builds (`make` in `verilator/`) will succeed even with multiple drivers — always verify the design is Quartus-clean before targeting FPGA

**Conditional compilation:** `USE_EGRET_CPU` and `SIMULATION` are defined in `verilator/Makefile` for simulation. For FPGA, `USE_EGRET_CPU` is set in `MacLC.qsf`. Guard simulation-only code (`$display`, debug counters) with `` `ifdef SIMULATION ``.

## VIA Shift Register — Simulation Sensitivity

**Critical:** Changes to the VIA SR logic in `rtl/via6522.sv` can break Egret communication and stall the boot. After any SR change, verify simulation still boots:

```bash
cd verilator && make clean && make
./obj_dir/Vemu --screenshot 350 --stop-at-frame 351 2>/dev/null 1>/dev/null
```

Check `screenshot_frame_0350.png` — it must show the grey/black alternating line pattern (memory test). Uniform grey means the SR change broke Egret communication.

**Known-bad patterns (do not re-introduce):**
- `ext_fall_edge_pending` — latching CB1 falling edges for shift-out. Use `shift_tick_f` instead.
- `cb2_latched` — capturing CB2 at CB1 rising edge for shift-in. Use live `cb2_i` instead.

These were attempted for FPGA timing improvement but cause the 4th Egret SR transfer to hang in Verilator (CPU stuck polling IFR bit 2 at `0xA14E5E`).

## Known Limitations

- Floppy disks are read-only
- SCSI writes work but are experimental
- Floppy won't read at 16 MHz CPU speed
- Bus retry via HALT signal not implemented on FX68K
