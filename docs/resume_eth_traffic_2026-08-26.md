# RESUME (autonomous): ethernet TX dead / no traffic on 24-bit guests + 2 KB/s FTP

Work autonomously to root-cause and fix. Everything below is verified state as
of 2026-08-26 ~09:00. Branch `pds-enet-icache-fix` @ `d112b2e` (pushed to
origin). Read the memory index + `eth-24bit-decode-tester-wedge-fixed` first.

## The mission

Guest RX works at scale; **guest TX is dead** on fresh (24-bit) Systems, and
FTP on "the previous build" crawls at ~2 KB/s (the user's report; box/build
uncertain — measure, don't assume). Deliver: traffic passing both ways on both
boxes, FTP at healthy LAN throughput, then the release re-cut (seed roll for
margin) and the mister-devel publish package.

## The hard evidence already in hand (bench .143, RBF fc2657a8, guest =
## games/MACLC/MacLC_7-5-5.hda — a FRESH 24-bit 7.5.5 with EtherTalk active)

/tmp/mac_eth_stats after ~2 boots and minutes at the desktop:

```
rpc 152,804   rpc_us_avg 208   rpc_us_max 50,160   ring_max 227
rx_frames 163,845   rx_ours 148,072 (47.7 MB DELIVERED to guest RAM)
tx_frames 0   tx_bytes 0   txp_cmds 6   tx_fail 0   arp tx 0
regwr: 00=28 01=4 ... 14..18=2 (CAM/RRA) ... full driver init, cr=0028 imr=66F1
```

Decode: the driver is fully up; RX DMA floods happily; **the guest kicked
transmit SIX times (txp_cmds=6) and ZERO frames emerged, with ZERO recorded
failures**. Silent TX swallow. Meanwhile `rpc_us_max=50ms` and `ring_max=227`
(≥200 = backpressure engaged) show the pump straining under LAN broadcast
flood being DMA'd into the guest.

## ★ The sharpest evidence (captured last, read FIRST): .94 after a Fetch
## attempt ("Error: The connection opened halfway and then failed")

```
txp_cmds 36   tx_bytes 2112   tx_fail 0
arp tx 33     ip tx 0         (33 × ~64B = the 2112 bytes)
```

**ARP transmits WORK. IP transmits are ZERO.** ARP = tiny single-fragment
frames; IP/TCP = the SONIC driver's classic multi-fragment descriptors
(header fragment + payload fragment). So the defect is specifically the
MULTI-FRAGMENT path of `transmit_chain` — fragment pointer/count parsing —
with single-fragment frames passing clean. "Opened halfway" = ARP resolved,
then the SYN (first multi-fragment frame) vanished. This refines the lead
hypothesis below: look at the SECOND-fragment pointer/size fields (odd
addresses and/or 24-bit high-byte garbage) in the TDA parse, not just the
chain links.

## Lead hypothesis (check FIRST)

**The 24-bit theme, DMA edition.** The decode fix (`d112b2e`) made registers
reachable from 24-bit Systems — but the SONIC's transmit path walks
guest-RAM DESCRIPTOR CHAINS at addresses the DRIVER wrote into UTDA/CTDA/TDA
link fields. A 24-bit System hands over pointers whose TOP BYTE may carry
garbage/flags (24-bit Macs reuse it). Main's `mac_sonic.cpp transmit_chain`
DMA-reads those raw — a garbage high byte lands the read outside guest RAM →
`x_in_ram` fail or garbage descriptor → the 08-22-style silent TX abort.
RX survives because RBA/RRA buffer addresses appear to parse fine (verify
why — possibly the driver zeroes those high bytes but not TDA links, or RX
addresses come from a different allocation).

Checks, in order:
1. Main side: log/print UTDA/CTDA and each descriptor-fetch address in
   `transmit_chain` (fork `support/mac/mac_sonic.cpp`; TX_ABORT path from the
   08-22 fix is the landmark). One instrumented Main build + one guest TX
   attempt (open the Chooser or drop a file on an AppleShare target — or
   MacTCP ping via MacPPP's... simplest: open Fetch and connect anywhere;
   even a failing connect fires ARP = TX).
2. If high-byte garbage confirmed: mask DMA addresses to [23:0]-within-RAM
   semantics **only for guest-sourced pointers** (descriptor links, buffer
   pointers), mirroring how the real card on a real LC only sees 24 address
   lines from the PDS slot (A24-A31 don't exist there!). That last fact is
   the physical argument for masking: the REAL card cannot receive 32-bit
   addresses over an LC PDS — mask to the slot's reality.
3. tb coverage: `support/mac/test/mac_sonic_test.cpp` (36 checks) — add a
   descriptor chain whose addresses carry a dirty high byte; must transmit.
4. Re-measure FTP after the fix on BOTH boxes before touching anything else —
   the 2 KB/s report is probably the same defect surviving via retransmits
   (TX mostly-dead). If FTP is still slow with TX healthy, THEN pursue the
   documented pump/RX-flood angle: rpc_us_max=50ms spikes, ring backpressure
   (ring_max 227), the OPEN "periodic TX stall" from
   [[pds-ethernet-perf-2026-08-23]], and the ISR-shadow spin (~180 wr/frame
   lever noted in [[pds-ethernet-freeze-rootcause]]).

## Box/tooling state (both reachable with ~/.ssh/mister_only)

- **.143 bench**: RBF `fc2657a8` at `_Unstable/MacLC.rbf` (card ON via
  MACLC.CFG `18 00 08 00`), Main `35124266`, guest image s0 →
  `games/MACLC/MacLC_7-5-5.hda` (user-swapped; **`BaseImage7-5-5.hda` is
  REPORTED CORRUPT** — likely from the wedge-night power cycles; repair or
  re-source it separately, and don't trust old validations against it).
  `MACLC.s4` CD attach present (the stays-attached LAW resumes now that the
  user's diagnostic is done). `ethwatch.sh` TX-stall monitor lives in
  `/media/fat/linux/`. grab: `scripts/grab_fresh.sh`.
- **.94 tester twin**: fresh 24-bit 7.5.5, RBF `MacLC_relcand.rbf`
  (=fc2657a8) + `MacLC_HUDDBG.rbf` (=`c48648a9`, HUD rows 12/13/14) in
  `_Computer/`, Main `35124266` (stock backup `MiSTer.bak_stock_20260826`),
  remote installed via marked `/media/fat/linux/user-startup.sh`, memdump at
  `/tmp` (volatile — re-copy from .143 `/media/fat/linux/memdump` after
  reboots). grab: `scratch/grab94.sh`. Load cores OSD-free:
  `echo "load_core <path>" > /dev/MiSTer_cmd`.
- Mailbox contract (ARM phys): MAGIC `0x1FF20000`, WPTR `+8`, RPTR `+0xA8`,
  ring `+0x20800`, shadows w2+, DMA_CMD/STAT `+0xB0/+0xB8`; stats
  `/tmp/mac_eth_stats`. Guest-RAM dumps: one 32K block per DMA_CMD
  (`tools/guestdump/ramdump.sh` pattern; block = guest_addr>>15).
- HUD witness fit `c48648a9`: rows 12/13 = last two distinct bus addresses +
  IPL; row 14 = `{rdata[15:0], 8'b0, saw_stub, saw_regwr, 0,0, 0, wd_fired,
  cmd_queued, present}`; marker row 0 = A5C3F00F; bottom-left 4px cells.

## Gates for any fix

`tb_pds_enet` (47), `mac_sonic_test` (36 + new TX-dirty-address cases), sim
boot gates card-absent AND card-present (`+pds_magic +pds_rom=pds_declrom.hex`,
"?" shifts past ~500 = normal), then HW: 2+ eth-ON boots per box, an actual
guest TX (arp tx > 0, tx_frames > 0), an FTP transfer measured. Per-fit laws
apply (one boot never a verdict; the fc2657a8 fit is STA-met at only
+0.009 ns — roll a seed for the actual release and re-gate). Main rebuilds:
WSL, PATH=/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin, `make -j8`
in /mnt/c/Temp/mistercore/Main_MiSTer; deploy to /media/fat/MiSTer + reboot;
verify `/proc/$(pidof MiSTer)/exe` md5, never just the file.

## Parked adjacent items (don't lose)

- Bench-only frozen-"?" card-ON wedge (NCR5380 loop fingerprint, seeds 8/9
  era): never reproduced on .94; now confounded by the corrupt
  BaseImage7-5-5.hda AND the CD intermittent. Only re-open if a NON-flashing
  "?" recurs with a verified-good image; the HUD rows will fingerprint it.
- Release/publish: after TX works — re-cut releases/ (dated RBF + Main
  35124266 or its successor), then the user pushes to mister-devel (their
  repo/branch choice; master + add-pds-ethernet both currently ship pre-v2
  bits). Ethernet ships default-Off (`7ed2455`); 10MB-default Memory flip is
  a candidate for the same cut (fresh boxes boot 2MB today).
- .94 restock when done: remove user-startup.sh + Scripts/remote*.sh +
  restore MiSTer.bak_stock_20260826 (user's call).
- Guest-config law (the week's big lesson): 24/32-bit addressing, RAM size,
  PRAM freshness, and IMAGE HEALTH are part of every test matrix. Verify the
  image (`scripts/hfs_check.py`) before blaming RTL.
