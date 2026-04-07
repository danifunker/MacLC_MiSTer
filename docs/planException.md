From plan Commit A (Steps 1+2), what's not in 4ae3f06:

  Step 2 — Real BERR on unmapped accesses (the headline value):
  - cpu_berr is wired up but only asserts on cpuFC == 3'b111 (autovector). The unmapped term (!_cpuAS && cpuBusControl && selectUnmapped) is omitted.
  - Enabling it BERR-storms on four addresses captured during boot:
    - $000000, $000002 (fc=101 supervisor data — likely overlay-timing artifact)
    - $F21C00 (fc=101 — unmapped peripheral hole between SWIM at $F16xxx and Ariel at $F24xxx)
    - $FC0000 (fc=101 — gap between VRAM end $FBFFFF and next region)
  - sim.v's .berr is still hard-wired to 1'b0 rather than cpu_berr, so even the autovector path isn't active in the simulator. The plan's Step 6 table called for parity here.

  Step 1 — addrDecoder high-bit unmapped detection:
  - The plan wanted addrDecoder to mark |address[31:24] as unmapped. Not done — addrDecoder still takes a 24-bit address port. High-bit visibility is via the parallel
  cpuAddrFullHi wire and the HIGH_ADDR $display only.

  Everything else from Commit A's scope (cpuAddr widening through the top level and addrController_top, selectUnmapped wiring in sim.v, diagnostic infrastructure) did land.
