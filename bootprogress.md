  Boot progression (4.3M instructions total):

  ┌──────────┬──────────┬──────────────────────────────────────────────────────────────────────────────┐
  │   Line   │ PC Range │                                 Description                                  │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 1        │ $000000  │ Reset vector                                                                 │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 568      │ $A02Exx  │ Early ROM init                                                               │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 2190     │ $A463xx  │ Main ROM startup                                                             │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 4195     │ $A14Cxx  │ Hardware init routines                                                       │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 31909    │ $A464DE  │ RAM test/sizing (the $A46AF0 checksum loop runs from here until line ~1.34M) │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 1342662  │ $A02Fxx  │ Post-RAM-test                                                                │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 1350043  │ Various  │ ROM initialization continues ($A465xx, $A4A5xx)                              │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 1352294  │ $A466DA  │ Enters memory clear/init region                                              │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 1352353+ │ $A4685E  │ Stuck here — memory init loop with MOVEM/EOR pattern                         │
  └──────────┴──────────┴──────────────────────────────────────────────────────────────────────────────┘

  The CPU is advancing through the ROM — it got past reset, early init, RAM testing, and entered memory
  initialization. But at line ~1.35M (out of 4.3M lines) it enters the $A4685E-$A46880 loop and never exits. This is
   a memory initialization/zeroing loop using MOVEM to blast data. Let me check if this loop is actually making
  progress (A2 advancing) or truly stuck.

⏺ Bash(# Check the loop at A4685E - is the CMPA/BLE making progress?
      # Look at the BLE instruction (A46880) - does it ever fall through?…)
  ⎿  Running…
