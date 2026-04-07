 100% pin resolution: 1107/1107

  Final deliverables

  ┌────────────────────────┬────────┬──────────────────────────────────────────────────────────────────────────────────────────┐
  │          File          │  Size  │                                         Contents                                         │
  ├────────────────────────┼────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ extract_netlist.py     │ 38 KB  │ Parser script with all manual overrides                                                  │
  ├────────────────────────┼────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ LC_Master_Netlist.csv  │ 124 KB │ 1107 pin rows — one row per component pin with its net assignment                        │
  ├────────────────────────┼────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ LC_Nets.csv            │ 31 KB  │ 227 nets — one row per net listing all connected endpoints (best for Verilog comparison) │
  ├────────────────────────┼────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ LC_Labels_CrossRef.csv │ 24 KB  │ 802 labels — every GLabel/HLabel/Label with coordinates for cross-referencing            │
  └────────────────────────┴────────┴──────────────────────────────────────────────────────────────────────────────────────────┘

  Per-sheet status — all at 100%

  ┌────────────────┬─────────┬──────────────────────────────────────────────────┐
  │     Sheet      │  Pins   │                      Status                      │
  ├────────────────┼─────────┼──────────────────────────────────────────────────┤
  │ LC_Audio       │ 42/42   │ ✅ (analog audio path marked <analog>)           │
  ├────────────────┼─────────┼──────────────────────────────────────────────────┤
  │ LC_CPU         │ 114/114 │ ✅                                               │
  ├────────────────┼─────────┼──────────────────────────────────────────────────┤
  │ LC_EGRET       │ 26/26   │ ✅ (internal analog marked <internal>)           │
  ├────────────────┼─────────┼──────────────────────────────────────────────────┤
  │ LC_Floppy      │ 38/38   │ ✅                                               │
  ├────────────────┼─────────┼──────────────────────────────────────────────────┤
  │ LC_PDS         │ 288/288 │ ✅                                               │
  ├────────────────┼─────────┼──────────────────────────────────────────────────┤
  │ LC_RAM         │ 160/160 │ ✅                                               │
  ├────────────────┼─────────┼──────────────────────────────────────────────────┤
  │ LC_ROM         │ 128/128 │ ✅ (4× 27C080 via built-in pinout + overrides)   │
  ├────────────────┼─────────┼──────────────────────────────────────────────────┤
  │ LC_SCSI_Serial │ 140/140 │ ✅ (internal serial subsystem marked <internal>) │
  ├────────────────┼─────────┼──────────────────────────────────────────────────┤
  │ LC_V8          │ 124/124 │ ✅                                               │
  ├────────────────┼─────────┼──────────────────────────────────────────────────┤
  │ LC_Video       │ 47/47   │ ✅ (fixed CULTDAC library pin-7 collision)       │
  └────────────────┴─────────┴──────────────────────────────────────────────────┘

  Key nets for Verilog side-by-side comparison

  From LC_Nets.csv:
  - Data bus D[0..31] — 32 bits, spans LC_CPU / LC_Floppy / LC_PDS / LC_RAM / LC_ROM / LC_SCSI_Serial / LC_Video
  - Address bus A[0..31] — 22 bits actually used, spans LC_CPU / LC_Floppy / LC_PDS / LC_ROM / LC_SCSI_Serial / LC_V8 / LC_Video
  - RA[0..10] — DRAM row/column address, LC_RAM ↔ LC_V8
  - CAS0-3, RAS0-1, RAM_WE — DRAM control, LC_RAM ↔ LC_V8 (↔ LC_Video for CAS2/3, RAS1, RAM_WE)
  - BD[16..31] — video data bus, LC_RAM ↔ LC_V8 ↔ LC_Video
  - VD[0..15] — VRAM data, LC_Video
  - SEL_ROM — V8 → 4× EPROM ~CE/~OE
  - Serial/SCSI/Floppy control signals — all fully resolved

  Special net-name conventions used

  - <analog> — analog audio signal chain (LC_Audio DFAC/LM3080/MC34119)
  - <internal> — internal to a subsystem (EGRET ADB, 85C80 serial port, RC filters)
  - <tp> — bare test point (V8 UG5 TP1/TP2/TP3)

  These pseudo-nets are excluded from LC_Nets.csv since they don't represent real cross-module connections and have no Verilog equivalent. They remain in LC_Master_Netlist.csv
  for completeness.

  How to use for Verilog comparison

  1. For each Verilog module (e.g., v8.v, egret.v), pull the corresponding rows from LC_Master_Netlist.csv filtered by ref or lib_part
  2. For cross-module wiring, open LC_Nets.csv — the endpoints column lists every sheet:ref.pin(name) that touches a given net. This directly maps to module_instance.port
  connections in your top-level Verilog.
  3. Re-run python3 LC_Schematics/extract_netlist.py any time the schematics change; the overrides are all in one block at the top of the script.
