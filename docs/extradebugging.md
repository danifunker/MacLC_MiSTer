# Extra Debug Statements

Temporary `$display` / debug hooks added during boot-hang investigation.
These should be reviewed and removed once the related work settles.

## rtl/scc.v

- **`SCC_WREG_A_PTR` / `SCC_WREG_A` / `SCC_WREG_B_PTR` / `SCC_WREG_B`** —
  combined always-block just after the `wreg_a`/`wreg_b` assigns (~line 186)
  that prints every control-register write, distinguishing the WR0
  pointer-select write from the targeted-register write. Used to reverse
  engineer which SCC registers the ROM is programming (and in what order)
  during the atlk/LocalTalk driver init. Gated by `` `ifdef SIMULATION ``.
  Still useful; keep until SCC init is well-understood.

  Earlier variants of this debug included `SCC_STATE_A` transition logging,
  `SCC_CS` edge logging, `SCC_RREG_A`/`SCC_RREG_B` read tracers and extra
  `state_was=` fields — they were used once to chase the cs_access_done
  re-entry bug (commit fixing SCC access double-processing on HW reset) and
  then pruned back to the minimal version above.

## rtl/pseudovia.sv

- *(none currently — previous `PVIA_WRITE` and `PVIA_VBL_DEBUG` prints were
  removed after commit `a89c671`.)*

## rtl/dataController_top.sv

- *(none currently — previous `IPL_CHANGE` debug block was removed after
  commit `a89c671`.)*

## Notes

- All debug prints are inside `` `ifdef SIMULATION `` so FPGA builds are
  unaffected.
- When removing, also delete corresponding entries from this file.
