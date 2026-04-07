#!/usr/bin/env python3
"""
Extract pin-level netlist from KiCad legacy schematic files (.sch) and
symbol library files (.lib) into a master CSV for Verilog comparison.

Approach:
  1. Parse .lib files to get pin definitions per component symbol.
  2. Parse each .sch file for components, labels, and wires.
  3. Build a coordinate-based connectivity graph to resolve net names.
  4. Output a CSV with one row per component pin.
"""

import csv
import glob
import os
import re
import sys
from collections import defaultdict

SCH_DIR = os.path.dirname(os.path.abspath(__file__))
LIB_DIR = os.path.join(SCH_DIR, "lib")

# ---------------------------------------------------------------------------
# Manual overrides — (sheet, ref, pin_number) -> net_name
#
# These are connections the geometric wire tracer cannot follow, typically
# because a passive component (series resistor, ferrite bead, decoupling cap)
# breaks the wire chain. Each entry has been manually verified against the
# source schematic.
#
# Special net names:
#   "<analog>"   — unnamed analog signal (no Verilog equivalent)
#   "<internal>" — internal to a subsystem, not cross-sheet
#   "<nc>"       — not connected
#   "<tp>"       — bare test point
# ---------------------------------------------------------------------------
MANUAL_OVERRIDES = {
    # ---- LC_CPU ------------------------------------------------------------
    # UB5 MC68020 CDIS pulled up via R95 4k7 -> +5V (cache disabled)
    ("LC_CPU", "UB5", "H1"): "+5V",

    # ---- LC_RAM ------------------------------------------------------------
    # All DRAM VCC/GND pins connect through decoupling caps to the power rails
    ("LC_RAM", "UI2", "26"): "GND",
    ("LC_RAM", "UI3", "13"): "+5V",
    ("LC_RAM", "UI3", "26"): "GND",
    ("LC_RAM", "UI4", "26"): "GND",
    ("LC_RAM", "UI5", "13"): "+5V",
    ("LC_RAM", "UI5", "26"): "GND",
    ("LC_RAM", "UI6", "26"): "GND",
    ("LC_RAM", "UI7", "13"): "+5V",
    ("LC_RAM", "UI7", "26"): "GND",
    ("LC_RAM", "UI8", "26"): "GND",
    ("LC_RAM", "UI9", "13"): "+5V",
    ("LC_RAM", "UI9", "26"): "GND",

    # ---- LC_V8 -------------------------------------------------------------
    # V8 ASIC (UG5) — RA[0..10] via 22R series damping resistors to RA bus
    ("LC_V8", "UG5", "7"):   "RA0",
    ("LC_V8", "UG5", "8"):   "RA1",
    ("LC_V8", "UG5", "13"):  "RA2",
    ("LC_V8", "UG5", "21"):  "RA3",
    ("LC_V8", "UG5", "44"):  "RA4",
    ("LC_V8", "UG5", "79"):  "RA5",
    ("LC_V8", "UG5", "84"):  "RA6",
    ("LC_V8", "UG5", "99"):  "RA7",
    ("LC_V8", "UG5", "108"): "RA8",
    ("LC_V8", "UG5", "116"): "RA9",
    ("LC_V8", "UG5", "121"): "RA10",
    # V8 — CAS/RAS/RAM_WE via 22R series damping resistors
    ("LC_V8", "UG5", "117"): "CAS0",
    ("LC_V8", "UG5", "80"):  "CAS1",
    ("LC_V8", "UG5", "119"): "CAS2",
    ("LC_V8", "UG5", "83"):  "CAS3",
    ("LC_V8", "UG5", "40"):  "RAS0",
    ("LC_V8", "UG5", "24"):  "RAS1",
    ("LC_V8", "UG5", "12"):  "RAM_WE",
    # V8 — /AS via wire and 4k7 pullup R17 to +5V
    ("LC_V8", "UG5", "18"):  "AS",
    # V8 — clocks
    ("LC_V8", "UG5", "11"):  "CPU_CLK",        # also drives SWIM_CLK via series R
    ("LC_V8", "UG5", "100"): "DFAC_CLK",       # also drives PDS_CLK via series R
    ("LC_V8", "UG5", "38"):  "OSC_31_3344MHZ", # from G1 oscillator
    ("LC_V8", "UG5", "42"):  "OSC_25_1750MHZ", # from G2 oscillator
    # V8 — VCC rails (filtered via ferrite beads)
    ("LC_V8", "UG5", "51"):  "+5V",  # VCC-2 via L6
    ("LC_V8", "UG5", "115"): "+5V",  # VCC-1 via L8
    # V8 — test points (bare test pads)
    ("LC_V8", "UG5", "33"):  "<tp>",
    ("LC_V8", "UG5", "48"):  "<tp>",
    ("LC_V8", "UG5", "49"):  "<tp>",

    # ---- LC_ROM ------------------------------------------------------------
    # 4x 27C080 EPROMs form a 4MB ROM (1M x 32-bit words).
    #   UB2 = "LL" byte lane -> D0-D7
    #   UC2 = "ML" byte lane -> D8-D15
    #   UD2 = "MH" byte lane -> D16-D23
    #   UE2 = "HH" byte lane -> D24-D31
    # All share the same address bus (CPU A2-A21 -> EPROM A0-A19) and
    # control signals (both ~CE and ~OE tied to SEL_ROM).
    # Geometric tracing does not work for these because the standard KiCad
    # Memory_EPROM:27C080 symbol isn't in our local .lib files, so all 128
    # ROM pins are resolved via this override table.
    #
    # 27C080 JEDEC pinout -> LC net mapping (same for all 4 EPROMs):
    #   Pin  1 (A19) -> A21      Pin 17 (DQ3) -> D[lane+3]
    #   Pin  2 (A16) -> A18      Pin 18 (DQ4) -> D[lane+4]
    #   Pin  3 (A15) -> A17      Pin 19 (DQ5) -> D[lane+5]
    #   Pin  4 (A12) -> A14      Pin 20 (DQ6) -> D[lane+6]
    #   Pin  5 (A7)  -> A9       Pin 21 (DQ7) -> D[lane+7]
    #   Pin  6 (A6)  -> A8       Pin 22 (~CE) -> SEL_ROM
    #   Pin  7 (A5)  -> A7       Pin 23 (A10) -> A12
    #   Pin  8 (A4)  -> A6       Pin 24 (~OE) -> SEL_ROM
    #   Pin  9 (A3)  -> A5       Pin 25 (A11) -> A13
    #   Pin 10 (A2)  -> A4       Pin 26 (A9)  -> A11
    #   Pin 11 (A1)  -> A3       Pin 27 (A8)  -> A10
    #   Pin 12 (A0)  -> A2       Pin 28 (A13) -> A15
    #   Pin 13 (DQ0) -> D[lane]  Pin 29 (A14) -> A16
    #   Pin 14 (DQ1) -> D[lane+1] Pin 30 (A17) -> A19
    #   Pin 15 (DQ2) -> D[lane+2] Pin 31 (A18) -> A20
    #   Pin 16 (GND) -> GND      Pin 32 (VCC) -> +5V

    # ---- LC_Audio ----------------------------------------------------------
    # DFAC UB10, LM3080 UB9, MC34119 UC9 form the analog audio signal chain.
    # Most of the pins connect through analog filter networks (resistors,
    # capacitors, ferrite beads) that don't match Verilog digital signals.
    # DFAC digital inputs (EGT_SND*, ASIC_SND*, /RST) are already resolved
    # as GLabels. Analog pins below are marked <analog>.
    ("LC_Audio", "UB10", "1"):  "<analog>",   # PIN_1 analog input (Lch)
    ("LC_Audio", "UB10", "2"):  "<analog>",   # PIN_2 analog input
    ("LC_Audio", "UB10", "5"):  "<analog>",   # PIN_5 analog filter node
    ("LC_Audio", "UB10", "6"):  "<analog>",   # PIN_6
    ("LC_Audio", "UB10", "7"):  "<analog>",   # PIN_7
    ("LC_Audio", "UB10", "8"):  "<analog>",   # PIN_8
    ("LC_Audio", "UB10", "9"):  "<analog>",   # PIN_9
    ("LC_Audio", "UB10", "10"): "<analog>",   # PIN_10
    ("LC_Audio", "UB10", "11"): "<analog>",   # PIN_11
    ("LC_Audio", "UB10", "12"): "<analog>",   # PIN_12
    ("LC_Audio", "UB10", "13"): "<analog>",   # PIN_13
    ("LC_Audio", "UB10", "23"): "<analog>",   # PIN_23 (to bottom row, analog)
    ("LC_Audio", "UB10", "24"): "<analog>",   # PIN_24
    ("LC_Audio", "UB10", "25"): "<analog>",   # PIN_25
    ("LC_Audio", "UB10", "27"): "<analog>",   # PIN_27
    ("LC_Audio", "UB10", "28"): "<analog>",   # PIN_28
    # LM3080 UB9 - operational transconductance amplifier (analog)
    ("LC_Audio", "UB9", "2"): "<analog>",   # IN-
    ("LC_Audio", "UB9", "3"): "<analog>",   # IN+
    ("LC_Audio", "UB9", "5"): "<analog>",   # BIAS_IN
    ("LC_Audio", "UB9", "6"): "<analog>",   # OUT
    ("LC_Audio", "UB9", "7"): "+8V",        # V+ to +8V rail
    # MC34119 UC9 - audio power amplifier
    ("LC_Audio", "UC9", "2"): "<analog>",   # FC2 (frequency comp)
    ("LC_Audio", "UC9", "3"): "<analog>",   # FC1 (frequency comp)
    ("LC_Audio", "UC9", "4"): "<analog>",   # Vin audio input
    ("LC_Audio", "UC9", "5"): "<analog>",   # VO1 speaker output
    ("LC_Audio", "UC9", "6"): "+5V",        # VCC via L16 ferrite bead

    # ---- LC_SCSI_Serial ----------------------------------------------------
    # 85C80 UE9 (SCC Serial Controller) — VDD via ferrite bead + decoupling
    ("LC_SCSI_Serial", "UE9", "1"):  "+5V",  # VDD
    ("LC_SCSI_Serial", "UE9", "12"): "+5V",  # VDD
    # 85C80 serial port signals — all internal to the serial subsystem,
    # routed via RC1/RC2 filter networks to AM26LS30 line drivers (UG9/UG10)
    # and then to the DB25 connectors. These are within-SCC-module signals
    # in Verilog terms, not cross-sheet wires.
    ("LC_SCSI_Serial", "UE9", "11"): "<internal>",  # /INTACK
    ("LC_SCSI_Serial", "UE9", "13"): "<internal>",  # W/REQA
    ("LC_SCSI_Serial", "UE9", "16"): "<internal>",  # RxDA
    ("LC_SCSI_Serial", "UE9", "17"): "<internal>",  # /TRxCA
    ("LC_SCSI_Serial", "UE9", "18"): "<internal>",  # TxDA
    ("LC_SCSI_Serial", "UE9", "19"): "<internal>",  # DTR/REQA
    ("LC_SCSI_Serial", "UE9", "20"): "<internal>",  # /RTSA
    ("LC_SCSI_Serial", "UE9", "21"): "<internal>",  # /DCDA
    ("LC_SCSI_Serial", "UE9", "23"): "<internal>",  # /DCDB
    ("LC_SCSI_Serial", "UE9", "24"): "<internal>",  # /RTSB
    ("LC_SCSI_Serial", "UE9", "25"): "<internal>",  # DTR/REQB
    ("LC_SCSI_Serial", "UE9", "26"): "<internal>",  # TxDB
    ("LC_SCSI_Serial", "UE9", "27"): "<internal>",  # /TRxCB
    ("LC_SCSI_Serial", "UE9", "28"): "<internal>",  # RxDB
    ("LC_SCSI_Serial", "UE9", "30"): "<internal>",  # W/REQB
    ("LC_SCSI_Serial", "UE9", "35"): "<internal>",  # /EOP
    # AM26LS30 UG9/UG10 line drivers — VCC +5V / VEE -12V analog rails
    ("LC_SCSI_Serial", "UG9",  "2"):  "+5V",
    ("LC_SCSI_Serial", "UG9",  "10"): "-12V",
    ("LC_SCSI_Serial", "UG10", "2"):  "+5V",
    ("LC_SCSI_Serial", "UG10", "10"): "-12V",
    # UG9/UG10 signal I/Os - all internal to serial subsystem
    ("LC_SCSI_Serial", "UG9",  "3"):  "<internal>",  # IN_A
    ("LC_SCSI_Serial", "UG9",  "9"):  "<internal>",  # IN_D
    ("LC_SCSI_Serial", "UG9",  "14"): "<internal>",  # OUT_C
    ("LC_SCSI_Serial", "UG9",  "18"): "<internal>",  # OUT_B
    ("LC_SCSI_Serial", "UG10", "3"):  "<internal>",  # IN_A
    ("LC_SCSI_Serial", "UG10", "4"):  "<internal>",  # IN_B/EN_AB
    ("LC_SCSI_Serial", "UG10", "8"):  "<internal>",  # IN_C/EN_CD
    ("LC_SCSI_Serial", "UG10", "9"):  "<internal>",  # IN_D
    ("LC_SCSI_Serial", "UG10", "13"): "<internal>",  # OUT_D
    ("LC_SCSI_Serial", "UG10", "14"): "<internal>",  # OUT_C
    # RC1/RC2 filter networks — each pin is an internal filter node between
    # the 85C80 and the line drivers / connectors. They have no independent
    # net name; each node is part of the serial signal path.
    ("LC_SCSI_Serial", "RC1", "2"):  "<internal>",
    ("LC_SCSI_Serial", "RC1", "9"):  "<internal>",
    ("LC_SCSI_Serial", "RC1", "12"): "<internal>",
    ("LC_SCSI_Serial", "RC1", "13"): "<internal>",
    ("LC_SCSI_Serial", "RC1", "14"): "<internal>",
    ("LC_SCSI_Serial", "RC1", "17"): "<internal>",
    ("LC_SCSI_Serial", "RC1", "18"): "<internal>",
    ("LC_SCSI_Serial", "RC1", "19"): "<internal>",
    ("LC_SCSI_Serial", "RC2", "2"):  "<internal>",
    ("LC_SCSI_Serial", "RC2", "3"):  "<internal>",
    ("LC_SCSI_Serial", "RC2", "4"):  "<internal>",
    ("LC_SCSI_Serial", "RC2", "7"):  "<internal>",
    ("LC_SCSI_Serial", "RC2", "8"):  "<internal>",
    ("LC_SCSI_Serial", "RC2", "9"):  "<internal>",
    ("LC_SCSI_Serial", "RC2", "12"): "<internal>",
    ("LC_SCSI_Serial", "RC2", "13"): "<internal>",
    ("LC_SCSI_Serial", "RC2", "14"): "<internal>",
    ("LC_SCSI_Serial", "RC2", "17"): "<internal>",
    ("LC_SCSI_Serial", "RC2", "18"): "<internal>",
    ("LC_SCSI_Serial", "RC2", "19"): "<internal>",

    # ---- LC_Video ----------------------------------------------------------
    # CULTDAC UJ10 - video DAC. VCC pins filtered via L7 ferrite bead to +5V.
    # RGB outputs drive the external video connector via 75R series / 100p
    # termination networks. PIN_28/PIN_29 are internal analog reference pins.
    ("LC_Video", "UJ10", "6"):  "+5V",       # VCC (AVCC filtered)
    # Pin 7 has a library collision (both VCC and /CBLANK numbered 7).
    # We use (sheet, ref, pin_number, pin_name) for disambiguation.
    ("LC_Video", "UJ10", "7", "VCC"): "+5V",
    ("LC_Video", "UJ10", "21"): "+5V",       # VCC
    ("LC_Video", "UJ10", "22"): "+5V",       # VCC
    ("LC_Video", "UJ10", "23"): "+5V",       # VCC
    ("LC_Video", "UJ10", "30"): "VREF",      # VREF from LM385-1.2 reference D2
    ("LC_Video", "UJ10", "25"): "VIDEO_RED",    # analog video output to connector
    ("LC_Video", "UJ10", "26"): "VIDEO_GREEN",  # analog video output
    ("LC_Video", "UJ10", "27"): "VIDEO_BLUE",   # analog video output
    ("LC_Video", "UJ10", "28"): "<internal>",   # analog comp pin
    ("LC_Video", "UJ10", "29"): "<internal>",   # analog reference pin
    # D2 LM385-1.2 voltage reference — both K pins tied to VREF node
    ("LC_Video", "D2", "6"): "VREF",
    ("LC_Video", "D2", "8"): "VREF",

    # ---- LC_Floppy ---------------------------------------------------------
    # SWIM UJ1 - floppy drive interface. VCC pins all tied to +5V through
    # decoupling caps. Drive interface signals go to J12/J13 connectors.
    ("LC_Floppy", "UJ1", "11"): "+5V",
    ("LC_Floppy", "UJ1", "22"): "+5V",
    ("LC_Floppy", "UJ1", "30"): "+5V",
    ("LC_Floppy", "UJ1", "44"): "+5V",
    # Floppy drive interface signals (to J12/J13 connectors)
    ("LC_Floppy", "UJ1", "3"):  "WRREQ",
    ("LC_Floppy", "UJ1", "19"): "ENBL2",
    ("LC_Floppy", "UJ1", "20"): "ENBL1",
    ("LC_Floppy", "UJ1", "21"): "SENSE",   # shared with RDDATA via junction
    ("LC_Floppy", "UJ1", "24"): "RDDATA",  # shared with SENSE via junction
    ("LC_Floppy", "UJ1", "31"): "PH3",
    ("LC_Floppy", "UJ1", "32"): "PH1",
    ("LC_Floppy", "UJ1", "35"): "PH0",
    ("LC_Floppy", "UJ1", "36"): "PH2",

    # ---- LC_EGRET ----------------------------------------------------------
    # EGRET UD8 — internal analog/power pins (do not cross sheets,
    # so irrelevant for Verilog matching)
    ("LC_EGRET", "UD8", "1"):  "<internal>",  # PIN_1 filter node
    ("LC_EGRET", "UD8", "2"):  "<internal>",  # /RST? internal reset
    ("LC_EGRET", "UD8", "3"):  "<internal>",  # OSC1 to Y1 32.768kHz
    ("LC_EGRET", "UD8", "4"):  "<internal>",  # OSC2 to Y1 32.768kHz
    ("LC_EGRET", "UD8", "12"): "<internal>",  # SYS_RST_IN from MC34064
    ("LC_EGRET", "UD8", "13"): "+5V",         # VCC via filter
    ("LC_EGRET", "UD8", "19"): "<internal>",  # ADB_OUT to BSR17A
    ("LC_EGRET", "UD8", "20"): "<internal>",  # ADB_IN via R34 22R
    ("LC_EGRET", "UD8", "24"): "<internal>",  # ADB_PWR sense via R47 4k7
    ("LC_EGRET", "UD8", "27"): "+5V",         # VCC via filter
    ("LC_EGRET", "UD8", "28"): "<internal>",  # PIN_28 filter node
}


def _build_rom_overrides():
    """Generate overrides for all 128 pins across the 4 LC_ROM EPROMs."""
    # (ref, data_lane_base) for each EPROM byte lane
    eproms = [
        ("UB2", 0),   # LL -> D0-D7
        ("UC2", 8),   # ML -> D8-D15
        ("UD2", 16),  # MH -> D16-D23
        ("UE2", 24),  # HH -> D24-D31
    ]
    # Standard 27C080 pin -> LC net name (non-data pins only)
    addr_map = {
        "1":  "A21",      # A19
        "2":  "A18",      # A16
        "3":  "A17",      # A15
        "4":  "A14",      # A12
        "5":  "A9",       # A7
        "6":  "A8",       # A6
        "7":  "A7",       # A5
        "8":  "A6",       # A4
        "9":  "A5",       # A3
        "10": "A4",       # A2
        "11": "A3",       # A1
        "12": "A2",       # A0
        "16": "GND",
        "22": "SEL_ROM",  # ~CE
        "23": "A12",      # A10
        "24": "SEL_ROM",  # ~OE
        "25": "A13",      # A11
        "26": "A11",      # A9
        "27": "A10",      # A8
        "28": "A15",      # A13
        "29": "A16",      # A14
        "30": "A19",      # A17
        "31": "A20",      # A18
        "32": "+5V",
    }
    result = {}
    for ref, lane in eproms:
        for pin, net in addr_map.items():
            result[("LC_ROM", ref, pin)] = net
        # Data lines DQ0..DQ7 at pins 13, 14, 15, 17, 18, 19, 20, 21
        data_pins = [("13", 0), ("14", 1), ("15", 2), ("17", 3),
                     ("18", 4), ("19", 5), ("20", 6), ("21", 7)]
        for pin, bit in data_pins:
            result[("LC_ROM", ref, pin)] = f"D{lane + bit}"
    return result


MANUAL_OVERRIDES.update(_build_rom_overrides())


# Electrical type codes from KiCad
ETYPE_MAP = {
    "I": "Input",
    "O": "Output",
    "B": "Bidirectional",
    "T": "Tri-state",
    "P": "Passive",
    "U": "Unspecified",
    "W": "Power",
    "w": "Power Flag",
    "C": "Open Collector",
    "E": "Open Emitter",
    "N": "Not Connected",
}


# ---------------------------------------------------------------------------
# 1. Parse library files
# ---------------------------------------------------------------------------

def parse_lib_file(path):
    """Return dict: component_name -> list of pin dicts."""
    components = {}
    current = None
    in_draw = False

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw_line in f:
            line = raw_line.strip().replace("\r", "")

            if line.startswith("DEF "):
                parts = line.split()
                current = parts[1]
                components[current] = []
                in_draw = False

            elif line == "DRAW":
                in_draw = True

            elif line == "ENDDRAW":
                in_draw = False

            elif line == "ENDDEF":
                current = None

            elif in_draw and line.startswith("X ") and current is not None:
                # X name number posx posy length orientation Snum Snom unit convert Etype [shape]
                parts = line.split()
                if len(parts) >= 11:
                    pin_name = parts[1]
                    pin_number = parts[2]
                    posx = int(parts[3])
                    posy = int(parts[4])
                    length = int(parts[5])
                    orientation = parts[6]
                    etype_code = parts[10]
                    inverted = len(parts) >= 12 and "I" in parts[11]

                    components[current].append({
                        "name": pin_name,
                        "number": pin_number,
                        "lib_x": posx,
                        "lib_y": posy,
                        "length": length,
                        "orientation": orientation,
                        "etype": ETYPE_MAP.get(etype_code, etype_code),
                        "inverted": inverted,
                    })

            # Handle ALIAS lines
            elif line.startswith("ALIAS ") and current is not None:
                aliases = line.split()[1:]
                for alias in aliases:
                    components[alias] = components[current]

    return components


# Built-in symbol definitions for KiCad standard library parts that are
# referenced by the schematic but not in our local .lib files.
# Format: component_name -> list of (pin_name, pin_number, etype)
# Coordinates are not provided here since these components are only added
# after geometric resolution failed — they are used to populate pin metadata
# only. The geometric coordinates must still be parsed from the matching
# KiCad standard library if precise pin-position resolution is needed.
BUILTIN_SYMBOLS = {
    # 27C080 - 8Mbit (1M x 8) EPROM, 32-pin DIP/PLCC
    # Standard JEDEC pinout
    "27C080": [
        ("A19",  "1", "I"), ("A16",  "2", "I"), ("A15",  "3", "I"),
        ("A12",  "4", "I"), ("A7",   "5", "I"), ("A6",   "6", "I"),
        ("A5",   "7", "I"), ("A4",   "8", "I"), ("A3",   "9", "I"),
        ("A2",  "10", "I"), ("A1",  "11", "I"), ("A0",  "12", "I"),
        ("DQ0", "13", "B"), ("DQ1", "14", "B"), ("DQ2", "15", "B"),
        ("GND", "16", "W"), ("DQ3", "17", "B"), ("DQ4", "18", "B"),
        ("DQ5", "19", "B"), ("DQ6", "20", "B"), ("DQ7", "21", "B"),
        ("~CE", "22", "I"), ("A10", "23", "I"), ("~OE", "24", "I"),
        ("A11", "25", "I"), ("A9",  "26", "I"), ("A8",  "27", "I"),
        ("A13", "28", "I"), ("A14", "29", "I"), ("A17", "30", "I"),
        ("A18", "31", "I"), ("VCC", "32", "W"),
    ],
}


def load_all_libs():
    """Load all .lib files in the lib directory."""
    pin_db = {}
    for lib_path in glob.glob(os.path.join(LIB_DIR, "*.lib")):
        pin_db.update(parse_lib_file(lib_path))

    # Add built-in symbols (metadata only — no coordinates, so geometric
    # tracing will not work, but pin names/numbers/types will appear in CSV)
    for name, pins in BUILTIN_SYMBOLS.items():
        pin_db[name] = [
            {
                "name": pname,
                "number": pnum,
                "lib_x": 0,
                "lib_y": 0,
                "length": 0,
                "orientation": "L",
                "etype": ETYPE_MAP.get(etype, etype),
                "inverted": pname.startswith("~") or pname.startswith("/"),
            }
            for (pname, pnum, etype) in pins
        ]

    return pin_db


# ---------------------------------------------------------------------------
# 2. Parse schematic files
# ---------------------------------------------------------------------------

def pin_connection_point(pin, comp_x, comp_y, matrix):
    """Calculate the schematic-space connection point of a pin.

    In KiCad legacy lib format, the pin (posx, posy) is the connection
    point in component-local space. We just need to apply the transform.
    """
    px, py = pin["lib_x"], pin["lib_y"]
    a, b, c, d = matrix
    sx = comp_x + a * px + b * py
    sy = comp_y + c * px + d * py
    return (sx, sy)


def parse_sch_file(path):
    """Parse a .sch file, returning components, labels, wires, junctions."""
    components = []
    glabels = []
    labels = []
    hlabels = []
    wires = []
    bus_entries = []
    junctions = []
    no_connects = []

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = [l.strip().replace("\r", "") for l in f.readlines()]

    sheet_name = os.path.splitext(os.path.basename(path))[0]
    title = sheet_name

    i = 0
    while i < len(lines):
        line = lines[i]

        # Sheet title
        if line.startswith("Title "):
            title = line.split('"')[1] if '"' in line else sheet_name

        # Component block
        elif line == "$Comp":
            comp = {}
            i += 1
            while i < len(lines) and lines[i] != "$EndComp":
                cl = lines[i]
                if cl.startswith("L "):
                    parts = cl.split()
                    comp["lib_part"] = parts[1]  # e.g. Macintosh_LC:V8_343S0121A
                    comp["ref"] = parts[2] if len(parts) > 2 else "?"
                elif cl.startswith("U "):
                    parts = cl.split()
                    comp["unit"] = int(parts[1]) if len(parts) > 1 else 1
                elif cl.startswith("P "):
                    parts = cl.split()
                    comp["x"] = int(parts[1])
                    comp["y"] = int(parts[2])
                elif cl.startswith("F "):
                    parts = cl.split('"')
                    field_idx_match = re.match(r"F\s+(\d+)", cl)
                    if field_idx_match:
                        fidx = int(field_idx_match.group(1))
                        if fidx == 0 and len(parts) >= 2:
                            comp["ref"] = parts[1]
                        elif fidx == 1 and len(parts) >= 2:
                            comp["value"] = parts[1]
                elif re.match(r"^\s*-?\d+\s+-?\d+\s+-?\d+\s+-?\d+\s*$", cl):
                    # Transform matrix line: a b c d
                    vals = cl.split()
                    comp["matrix"] = (int(vals[0]), int(vals[1]),
                                      int(vals[2]), int(vals[3]))
                i += 1
            if "lib_part" in comp:
                comp.setdefault("value", "")
                comp.setdefault("matrix", (1, 0, 0, -1))
                comp.setdefault("unit", 1)
                components.append(comp)

        # Global label
        elif line.startswith("Text GLabel "):
            parts = line.split()
            # Text GLabel x y orientation size type [italic] [bold]
            x, y = int(parts[2]), int(parts[3])
            orientation = int(parts[4])
            i += 1
            if i < len(lines):
                net_name = lines[i].strip()
                glabels.append({"x": x, "y": y, "name": net_name,
                                "orientation": orientation})

        # Hierarchical label
        elif line.startswith("Text HLabel "):
            parts = line.split()
            x, y = int(parts[2]), int(parts[3])
            orientation = int(parts[4])
            i += 1
            if i < len(lines):
                net_name = lines[i].strip()
                hlabels.append({"x": x, "y": y, "name": net_name,
                                "orientation": orientation})

        # Local label
        elif line.startswith("Text Label "):
            parts = line.split()
            x, y = int(parts[2]), int(parts[3])
            orientation = int(parts[4])
            i += 1
            if i < len(lines):
                net_name = lines[i].strip()
                labels.append({"x": x, "y": y, "name": net_name,
                               "orientation": orientation})

        # Wire
        elif line.startswith("Wire Wire Line"):
            i += 1
            if i < len(lines):
                parts = lines[i].split()
                if len(parts) >= 4:
                    wires.append(((int(parts[0]), int(parts[1])),
                                  (int(parts[2]), int(parts[3]))))

        # Junction / Connection
        elif line.startswith("Connection ~"):
            parts = line.split()
            if len(parts) >= 4:
                junctions.append((int(parts[2]), int(parts[3])))

        # Bus entry (diagonal wire connecting bus to signal wire)
        elif line.startswith("Entry Wire Line"):
            i += 1
            if i < len(lines):
                parts = lines[i].split()
                if len(parts) >= 4:
                    bus_entries.append(((int(parts[0]), int(parts[1])),
                                        (int(parts[2]), int(parts[3]))))

        # No-connect flag
        elif line.startswith("NoConn ~"):
            parts = line.split()
            if len(parts) >= 4:
                no_connects.append((int(parts[2]), int(parts[3])))

        i += 1

    return {
        "sheet_name": sheet_name,
        "title": title,
        "components": components,
        "glabels": glabels,
        "hlabels": hlabels,
        "labels": labels,
        "wires": wires,
        "bus_entries": bus_entries,
        "junctions": junctions,
        "no_connects": no_connects,
    }


# ---------------------------------------------------------------------------
# 3. Net resolution via union-find on coordinates
# ---------------------------------------------------------------------------

class UnionFind:
    def __init__(self):
        self.parent = {}

    def find(self, x):
        if x not in self.parent:
            self.parent[x] = x
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[ra] = rb


def point_on_segment(pt, seg_a, seg_b):
    """Check if point pt lies on the line segment from seg_a to seg_b.
    Only considers horizontal and vertical segments (KiCad wires)."""
    px, py = pt
    ax, ay = seg_a
    bx, by = seg_b

    # Horizontal segment
    if ay == by == py:
        return min(ax, bx) <= px <= max(ax, bx)
    # Vertical segment
    if ax == bx == px:
        return min(ay, by) <= py <= max(ay, by)
    return False


def resolve_nets(sch_data, pin_db):
    """Resolve net names for each component pin in a schematic sheet."""
    uf = UnionFind()
    wires = sch_data["wires"]

    # Add all wire segments — union endpoints
    for (x1, y1), (x2, y2) in wires:
        uf.union((x1, y1), (x2, y2))

    # Add bus entries — these are diagonal wires connecting buses to signals
    # The signal-side endpoint connects to the wire network
    for (x1, y1), (x2, y2) in sch_data.get("bus_entries", []):
        uf.union((x1, y1), (x2, y2))

    # Add junctions (they connect overlapping wires at that point)
    for jpt in sch_data["junctions"]:
        uf.find(jpt)  # ensure it exists
        # Union junction with any wire it touches (endpoint or mid-wire)
        for seg_a, seg_b in wires:
            if point_on_segment(jpt, seg_a, seg_b):
                uf.union(jpt, seg_a)

    # All connectable segments (wires + bus entries)
    all_segments = list(wires) + list(sch_data.get("bus_entries", []))

    # Helper: union a point with any wire/bus-entry it touches
    def connect_point_to_wires(pt):
        found = False
        for seg_a, seg_b in all_segments:
            if seg_a == pt or seg_b == pt or point_on_segment(pt, seg_a, seg_b):
                uf.union(pt, seg_a)
                found = True
        return found

    # Compute pin positions for all components
    comp_pins = []  # list of (component, pin_dict, schematic_point)
    for comp in sch_data["components"]:
        lib_key = comp["lib_part"].split(":")[-1]  # strip library prefix
        pins = pin_db.get(lib_key, [])
        for pin in pins:
            pt = pin_connection_point(pin, comp["x"], comp["y"], comp["matrix"])
            comp_pins.append((comp, pin, pt))
            connect_point_to_wires(pt)

    # Connect labels to wires (labels can land mid-wire)
    all_labels = (
        [(l, "global") for l in sch_data["glabels"]] +
        [(l, "hier") for l in sch_data["hlabels"]] +
        [(l, "local") for l in sch_data["labels"]]
    )
    for label, _ in all_labels:
        lpt = (label["x"], label["y"])
        connect_point_to_wires(lpt)

    # Power symbols provide net names too — connect and name
    net_names = {}
    for comp in sch_data["components"]:
        lib_full = comp["lib_part"]
        if lib_full.startswith("power:"):
            power_name = comp["value"] if comp["value"] else lib_full.split(":")[-1]
            pt = (comp["x"], comp["y"])
            connect_point_to_wires(pt)
            # Also connect power symbol to its pins (pin 1 at comp origin typically)
            lib_key = lib_full.split(":")[-1]
            power_pins = pin_db.get(lib_key, [])
            for pp in power_pins:
                ppt = pin_connection_point(pp, comp["x"], comp["y"], comp["matrix"])
                connect_point_to_wires(ppt)
                uf.union(pt, ppt)
            root = uf.find(pt)
            net_names[root] = power_name

    # Assign label names to nets (priority: global > hier > local)
    for label, ltype in all_labels:
        lpt = (label["x"], label["y"])
        root = uf.find(lpt)
        if ltype == "global":
            net_names[root] = label["name"]
        elif ltype == "hier":
            if root not in net_names:
                net_names[root] = label["name"]
        elif ltype == "local":
            if root not in net_names:
                net_names[root] = label["name"]

    # No-connect markers
    for pt in sch_data["no_connects"]:
        connect_point_to_wires(pt)
        root = uf.find(pt)
        if root not in net_names:
            net_names[root] = "NC"

    # Build set of all known net names for likely_net matching
    all_net_names = set(net_names.values())
    for label, _ in all_labels:
        all_net_names.add(label["name"])

    # Resolve each pin
    results = []
    sheet_name = sch_data["sheet_name"]
    for comp, pin, pt in comp_pins:
        root = uf.find(pt)
        net = net_names.get(root, "")

        # Manual override takes highest priority.
        # Try 4-tuple (with pin_name disambiguation) first, then 3-tuple.
        override = MANUAL_OVERRIDES.get(
            (sheet_name, comp["ref"], pin["number"], pin["name"]),
            MANUAL_OVERRIDES.get(
                (sheet_name, comp["ref"], pin["number"]), ""
            )
        )
        if override:
            net = override

        # If pin is a power pin (VCC/GND type), use the pin name as net
        if not net and pin["etype"] in ("Power", "Power Flag"):
            net = pin["name"]

        # For unresolved pins, derive a likely net name from the pin name
        # (strip leading / for inverted pins, which often matches GLabel names)
        likely = ""
        if not net:
            pname = pin["name"]
            clean = pname.lstrip("/")
            # Check if this pin name (or cleaned version) matches a known net
            if clean in all_net_names:
                likely = clean
            elif pname in all_net_names:
                likely = pname
            else:
                likely = clean  # use pin name as best guess

        results.append({
            "sheet": sch_data["sheet_name"],
            "title": sch_data["title"],
            "ref": comp["ref"],
            "lib_part": comp["lib_part"],
            "value": comp["value"],
            "pin_name": pin["name"],
            "pin_number": pin["number"],
            "pin_type": pin["etype"],
            "inverted": pin["inverted"],
            "net_name": net,
            "likely_net": likely,
            "pin_x": pt[0],
            "pin_y": pt[1],
        })

    return results


# ---------------------------------------------------------------------------
# 4. Also extract a label-only summary for signals without library pins
# ---------------------------------------------------------------------------

def extract_all_labels(sch_data):
    """Return all labels from a sheet for cross-reference."""
    rows = []
    for label in sch_data["glabels"]:
        rows.append({
            "sheet": sch_data["sheet_name"],
            "label_type": "GLabel",
            "net_name": label["name"],
            "x": label["x"],
            "y": label["y"],
        })
    for label in sch_data["hlabels"]:
        rows.append({
            "sheet": sch_data["sheet_name"],
            "label_type": "HLabel",
            "net_name": label["name"],
            "x": label["x"],
            "y": label["y"],
        })
    for label in sch_data["labels"]:
        rows.append({
            "sheet": sch_data["sheet_name"],
            "label_type": "Label",
            "net_name": label["name"],
            "x": label["x"],
            "y": label["y"],
        })
    return rows


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("Loading symbol libraries...")
    pin_db = load_all_libs()
    print(f"  Loaded {len(pin_db)} component definitions")
    for name, pins in sorted(pin_db.items()):
        print(f"    {name}: {len(pins)} pins")

    # Find all .sch files (excluding the top-level root sheet if it's just hierarchy)
    sch_files = sorted(glob.glob(os.path.join(SCH_DIR, "LC_*.sch")))
    # Exclude the root schematic that just contains sheet references
    sch_files = [f for f in sch_files if not f.endswith("LC_Schematics.sch")]

    all_pin_rows = []
    all_label_rows = []

    for sch_path in sch_files:
        sheet = os.path.basename(sch_path)
        print(f"\nProcessing {sheet}...")
        sch_data = parse_sch_file(sch_path)
        print(f"  Components: {len(sch_data['components'])}")
        print(f"  GLabels: {len(sch_data['glabels'])}, "
              f"HLabels: {len(sch_data['hlabels'])}, "
              f"Labels: {len(sch_data['labels'])}")
        print(f"  Wires: {len(sch_data['wires'])}")

        pin_rows = resolve_nets(sch_data, pin_db)
        label_rows = extract_all_labels(sch_data)

        resolved = sum(1 for r in pin_rows if r["net_name"])
        print(f"  Pins resolved: {resolved}/{len(pin_rows)}")

        all_pin_rows.extend(pin_rows)
        all_label_rows.extend(label_rows)

    # Write master pin CSV
    pin_csv_path = os.path.join(SCH_DIR, "LC_Master_Netlist.csv")
    with open(pin_csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "sheet", "title", "ref", "lib_part", "value",
            "pin_name", "pin_number", "pin_type", "inverted",
            "net_name", "likely_net", "pin_x", "pin_y",
        ])
        writer.writeheader()
        # Sort by sheet, ref, then pin number (natural sort)
        def sort_key(r):
            # Try numeric sort on pin number
            try:
                pn = int(r["pin_number"])
            except ValueError:
                pn = r["pin_number"]
            return (r["sheet"], r["ref"], pn if isinstance(pn, int) else 0, str(pn))
        all_pin_rows.sort(key=sort_key)
        writer.writerows(all_pin_rows)

    print(f"\n=== Written {len(all_pin_rows)} pin rows to {pin_csv_path}")

    # Write label cross-reference CSV
    label_csv_path = os.path.join(SCH_DIR, "LC_Labels_CrossRef.csv")
    with open(label_csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "sheet", "label_type", "net_name", "x", "y",
        ])
        writer.writeheader()
        all_label_rows.sort(key=lambda r: (r["net_name"], r["sheet"]))
        writer.writerows(all_label_rows)

    print(f"=== Written {len(all_label_rows)} label rows to {label_csv_path}")

    # Write net-grouped CSV: one row per net, listing all connected pins.
    # This is the most useful format for Verilog side-by-side comparison.
    net_pins = defaultdict(list)
    for row in all_pin_rows:
        net = row["net_name"]
        if not net:
            continue
        # Skip pseudo-nets that don't represent real connections
        if net in ("<analog>", "<internal>", "<tp>", "<nc>", "NC"):
            continue
        endpoint = f"{row['sheet']}:{row['ref']}.{row['pin_number']}({row['pin_name']})"
        net_pins[net].append({
            "endpoint": endpoint,
            "sheet": row["sheet"],
            "ref": row["ref"],
            "pin_type": row["pin_type"],
        })

    nets_csv_path = os.path.join(SCH_DIR, "LC_Nets.csv")
    with open(nets_csv_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "net_name", "pin_count", "sheet_count", "sheets", "drivers",
            "loads", "endpoints",
        ])
        for net in sorted(net_pins.keys()):
            pins = net_pins[net]
            sheets = sorted({p["sheet"] for p in pins})
            drivers = [p["endpoint"] for p in pins
                       if p["pin_type"] in ("Output", "Bidirectional",
                                            "Tri-state", "Open Collector",
                                            "Open Emitter")]
            loads = [p["endpoint"] for p in pins
                     if p["pin_type"] in ("Input", "Bidirectional")]
            endpoints = sorted(p["endpoint"] for p in pins)
            writer.writerow([
                net,
                len(pins),
                len(sheets),
                " | ".join(sheets),
                " | ".join(sorted(drivers)),
                " | ".join(sorted(loads)),
                " | ".join(endpoints),
            ])

    print(f"=== Written {len(net_pins)} nets to {nets_csv_path}")

    # Print a summary of inter-sheet signals
    print("\n=== Inter-sheet signal summary (GLabels) ===")
    glabel_sheets = defaultdict(set)
    for r in all_label_rows:
        if r["label_type"] == "GLabel":
            glabel_sheets[r["net_name"]].add(r["sheet"])
    for name, sheets in sorted(glabel_sheets.items()):
        print(f"  {name}: {', '.join(sorted(sheets))}")


if __name__ == "__main__":
    main()
