# RESUME PROMPT — Apple PDS Ethernet (parked 2026-08-21, all build phases DONE)

Paste this file as the opening prompt of a session in
`C:\Temp\mistercore\MacLC_MiSTer`, branch **`apple-pds-ethernet`**. The
Main_MiSTer half lives in `C:\Temp\mistercore\Main_MiSTer`, branch
**`mac-ethernet`**. Nothing is pushed anywhere; both trees were committed
clean at park time.

## Mission and status in one paragraph

The LC PDS Ethernet feature was pivoted from the v1 Asante MacCON i LC to
**Apple's own Ethernet LC Twisted Pair card (board 820-0532-B, DP83934
SONIC-T)** and built END-TO-END in the 08-20/21 session: SONIC front-end +
guest-RAM DMA engine in RTL, the SONIC chip model + mailbox service inside
the user's Main_MiSTer fork, the standalone `hps/maclc_eth` daemon retired.
**Every local gate is green** (unit TBs, model test, icache-seam both modes,
A&S, full fit STA-met, full-boot sims both ways) and both deployable
artifacts exist. **Remaining: (1) the OSD-MAC config change below, (2) MAME
driver-trace ground truth, (3) hardware bring-up + Speedometer regression.**
User rulings baked in: Twisted-Pair variant only; zero M10K (declROM served
from DDR3, bytes embedded in Main); feature requires the modified Main.

## ★ NEW REQUIREMENT recorded at park time (do this first on resume)

**The Ethernet MAC address must be configurable from the MiSTer menu (OSD),
NOT via a file.** The current mechanism — optional
`/media/fat/games/MacLC/eth.cfg` with `iface=`/`mac=` lines, parsed in
`support/mac/mac_eth.cpp:load_config()` — was built before this ruling and
must be replaced (the file parsing goes away; a hand-edited file is exactly
what the user does not want). Design notes for the resume session:

- Read: the user should set the MAC (and ideally the iface mode) in the OSD;
  persistence through Main's normal config machinery (a config the OSD
  saves) is fine — the objection is to hand-created files, not to Main's own
  storage.
- Precedent A (mode): minimig's A2065 has an OSD " Ethernet : " row cycling
  modes in Main `menu.cpp` (~6410/6567), persisted via minimig_config, with
  availability probing. MacLC is a CONF_STR core though — its menu is
  auto-generated, so a mode option can ride the CONF_STR + status word
  instead (Main reads it back via `user_io_status_get(...)` — verify that
  API's exact shape in user_io.h before relying on it). status[19] is
  already "Ethernet On/Off" (`OJ`, 0 = On, consumed as `ena_osd=~status[19]`
  in MacLC.sv:96/1089 — sim.v hardwires ena_osd=1).
- The MAC itself is 48 bits — too wide for enumerated CONF_STR options. The
  realistic shape is a small Main-side OSD editor (menu.cpp) keyed to the
  Mac family, a2065-style, with nibble-stepped editing, persisted by Main.
  This adds fork-only common-code lines; the user already accepted the
  fork-only nature ("we will just allow this to work with the modified
  version of mister main"). Alternative worth weighing: keep MAC = derived
  default (Apple OUI 08:00:07 + FNV(hostname), already implemented and
  collision-safe per box) and expose only an OSD override for the low
  bytes; ask the user how much control they actually want before building.
- When implemented: delete `load_config()`'s file path entirely, keep the
  derived-MAC fallback, republish the cooked PROM (stage_macprom) whenever
  the OSD value changes while the card is down (MAC changes need a guest
  reset anyway — presence and CAM are latched by the running driver).

## Exact repo state at park

### MacLC_MiSTer, branch `apple-pds-ethernet` (based on `cpu-icache` @ 7ad72ef — contains the MacLC_20260819 release and the Asante v1 as ancestors)

| commit | what |
|---|---|
| `2525d2f` | declROM import: `releases/341-0740_AppleLCTwistedPair.BIN` (32768 B, CRC32 9d47245c, SHA1 447ce683…, Apple-CRC 185CEAA3 verifies, byteLanes $0F = flat, ~331 real bytes / 99.3% zeros, NO driver in ROM) |
| `734a7be` | `docs/pds_ethernet_scope.md` v2 — THE architecture contract; read it first |
| `3c460e2` | SONIC front-end swap in `rtl/pds/pds_enet.sv` (see map below); Asante artifacts deleted; `scripts/gen_enet_declrom.py` (hash-verifying generator: sim hex + Main C header) |
| `b10680c` | guest-RAM DMA engine + `rtl/sdram.v` 4th requester + both tops wired + sim_ram eth port |
| `7a607a2` | `hps/maclc_eth/` deleted; `docs/port_enet_to_nubus_cores.md` rewritten for the NuBus sibling (enetnbtp, SONIC + 128K LOCAL RAM = no DMA engine needed there); CLAUDE.md feature entry |

### Main_MiSTer fork (danifunker), branch `mac-ethernet`

- Base: **upstream master `79aaf02` "video: fix HDMI off/on issues."** (the
  branch was a fresh cut of up-to-date upstream; the user's PR #1255
  `035b86f0` — the support/mac placement pattern — is already inside it).
- Our commit: **`34b8994`** "Mac: PDS Ethernet service (Apple Ethernet LC
  Twisted Pair, 820-0532-B)" — +1227 lines, all under `support/mac/`:
  `mac_eth.h` (mailbox contract mirror), `mac_eth.cpp` (lifecycle/ring/
  shadows/DMA-RPC client/declROM+PROM staging), `mac_sonic.{h,cpp}` (the
  chip model), `mac_eth_iface.cpp` (tap/raw binding),
  `mac_eth_declrom.h` (GENERATED — never hand-edit; regenerate with
  `python scripts/gen_enet_declrom.py --c-header <path>` from the MacLC
  repo), `test/mac_sonic_test.cpp` (36 checks), plus ONE line in the
  existing `mac_poll()` hook in `mac.cpp`. Zero common-code changes.

### Built artifacts (regenerable; do NOT trust stale copies — rebuild after any edit)

- `output_files/MacLC.rbf` — full fit of `b10680c`-state RTL: **STA met
  +0.036 ns, SEED 4 (qsf line 51), 30,055/41,910 ALMs (72%; the whole
  ethernet swap cost +470), RAM blocks 506/553 UNCHANGED = the feature uses
  zero M10K, DSP 53.** Per-seed HW video gate law still applies at deploy.
- `Main_MiSTer/bin/MiSTer` — ARM ELF, clean build of `34b8994`.
- MAME oracle: **`~/repos/mame/maclc`** (WSL) — driver-subset mame0288
  build; romset staged + verified: `~/mameroms/enetlctp.zip` ("romset
  enetlctp is good").

## Architecture crib (details live in docs/pds_ethernet_scope.md — trust that file over memory)

- Guest map (32-bit forms only; Slot Manager scans in 32-bit mode): SONIC
  regs `$FE00'0000-$1FF` (64×16-bit, index = **A[7:2], no inversion**, word
  at longword+0, $100 bank mirrors once, +2 half serves $FFFF); MAC PROM
  `$FE04'0000` AND `$FE40'0000` ($200 windows, mirrors every 8; byte reads
  = cooked PROM byte, **word-wide reads return the $0028 probe magic**);
  declROM flat 32K at `$FEFF'8000`. IRQ = pseudovia slot-$E bit $20
  active-low (unchanged wire). `pds_claim` masks the selectRAM aliases
  ($FE00xxxx→$000000 page zero!, $FE40xxxx→$400000).
- Mailbox v2 @ ARM phys 0x1FF00000 (0x21000): +0 XFER 64K bounce, +0x10000
  ROM window (win byte i = guest $FEFF0000+i), +0x20000 control block
  (MAGIC **"McLCETH2"** 4D634C43_45544832 / WPTR / 16 shadow words = 64
  regs / INT / MACPROM / GEO=2 / RPTR / DMA_CMD / DMA_STAT), +0x20800 ring
  (256×u64: valid|tag[3:1]|reg[9:4]|data[31:16]; tags 0=REG_WR 1=RESET).
  Layout is triple-mirrored: pds_enet.sv header, mac_eth.h, scope doc.
- DMA engine: ARM posts {seq[7:0], dir[8], even guest byte addr[39:16],
  even count[55:40]}; engine moves words guest-SDRAM↔XFER, echoes seq into
  DMA_STAT ([8]=err: odd/range>$9FFFFF). `dma_first` adopts the staged seq
  at first sight post-reset (stale-command replay killer). Fast poll while
  DMA active + ~250 µs hot window (~32 µs pickup mid-chain; cold ≤ ~660 µs).
- `rtl/sdram.v` eth port: 4th requester, download-port discipline — level
  req/frozen values/level ack, starts only with `!(oe||we)` + `t[0]` parity
  + outside floppy window/guard + refresh-force, **NEVER touches
  cpu_done/cpu_dout**. Need = 1 word/1.6 µs at 10BASE-T peak.
- ★ The V8 RAM translation (SIMM/motherboard-high/mirror) is **DUPLICATED**
  in pds_enet.sv with keep-in-sync banners both ways against
  `addrController_top.v`; the TB's known-answer cases are the drift guard.
- Main service: exact-match core gate (`strcasecmp` vs "maclc" — the
  prefix-matching `is_core_named()` would hit MacLCII; daemon lesson
  0de9974), ~1 ms pace + 1 s name recheck, ≤4 RX frames/pass, DMA-RPC
  spins ≤50 ms then logs. Defaults: iface **eth0** (raw+promisc; "tapN"
  names open TUN/TAP), MAC = 08:00:07 + FNV(hostname). PROM cooking =
  per-byte nibble-reversed-bit swizzle + XOR-complement checksum byte 7
  (MAME enetlc.cpp ground truth; driver un-swizzles and loads the REAL MAC
  into the CAM).
- mac_sonic deliberate deltas from MAME dp83932c.cpp (documented in the
  file header): grouped guest transfers (ordering preserved), RX appends
  computed FCS (tap/raw frames arrive without one), loopback short-circuits
  TX→RX (Mac drivers self-test at open), TXP chain runs synchronously.

## ALL REQUIRED CHECKS (run after ANY change in the respective area)

1. **Front-end/mailbox/DMA unit TB — 43 checks** (any pds_enet.sv edit):
   ```
   cd verilator && verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps \
     --Mdir /tmp/obj_pdsenet --top-module tb_pds_enet \
     tb_pds_enet.v sim_ddr3.v ../rtl/pds/pds_enet.sv
   /tmp/obj_pdsenet/Vtb_pds_enet        # expect: ALL PASS (tb_pds_enet)
   ```
2. **SONIC model test — 36 checks** (any mac_sonic edit; Main repo):
   ```
   cd support/mac/test && g++ -O1 -Wall -o /tmp/mac_sonic_test \
     mac_sonic_test.cpp ../mac_sonic.cpp && /tmp/mac_sonic_test
   ```
3. **icache-seam TB, BOTH modes** — LAW after ANY sdram.v request/handshake
   edit (build cmds in tb_icache_seam.v header; normal must PASS 107
   checks, the `+define+SDRAM_NO_DONE_LEVEL_FIX` negative control must
   FAIL — a passing negative control means the gate lost its teeth).
4. **Quartus A&S**: `bash scripts/build_only.sh --check` (0 errors; also
   the multiple-driver check Verilator can't do).
5. **Full-boot sim, BOTH ways** (any RTL or sim.v/sim_ram.v edit):
   ```
   cd verilator && make clean && make
   ./obj_dir/Vemu --screenshot 450 --stop-at-frame 451              # absent
   ./obj_dir/Vemu --screenshot 520 --stop-at-frame 521 \
       +pds_magic +pds_rom=pds_declrom.hex                          # present
   ```
   Absent@450: grey dither desktop + arrow cursor + centered ?-floppy.
   **Present: the ?-icon lands PAST frame ~500** (the 32K ROM scan — ~460k
   $FEFF-window trace hits, ≈2× the v1 16K ROM — shifts it; at 450 you get
   desktop+cursor only and that is NORMAL, not a hang). Corroborate a
   suspect run via cpu_trace.log: distinct-PC count in the tail (~200 =
   advancing) + the FEFF hit count. Regenerate the hex only via
   `python scripts/gen_enet_declrom.py --hex verilator/pds_declrom.hex`.
6. **Main build** (WSL; the environment gotchas cost 2 failures on 08-21):
   ```
   export PATH=/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin:$PATH
   cd /mnt/c/Temp/mistercore/Main_MiSTer && make clean && make -j$(nproc)
   ```
   (`/usr/bin/arm-linux-gnueabihf-gcc` is the WRONG toolchain — the
   Makefile wants `arm-none-*` from /opt; and a stale `bin/` from another
   environment link-fails in unrelated sharpmz code → always clean first.)
7. **Fit + deploy laws**: full `bash scripts/build_only.sh`; STA met; ONE
   canonical MacLC.rbf on the box; per-seed HW video gate (this core is
   seed-sensitive; the parked fit is seed 4); clean guest Shut Down before
   any core load; the CD boot-attach STAYS attached during gates (retry
   boot hangs, never blame the build on one boot); HUD stays OFF in
   release fits.
8. **HW bring-up sequence** (user drives; both artifacts deploy TOGETHER —
   the core is ethernet-dead without the modified Main): card visible in
   Slots/TattleTech → Apple Network Software installed (user has this) →
   Network cpanel shows EtherTalk → Chooser zones → MacTCP/OT ping → file
   transfer soak. One guest reset after Main is up (presence latches at
   guest reset). Plus a **Speedometer regression run** — ethernet-off must
   not move the 97.0% CPU-perf result (the arbiter is idle-edges-only by
   construction; measure anyway).
9. **MAME ground truth** (the prepared first move if HW misbehaves):
   `~/repos/mame/maclc -rompath ~/mameroms maclc -lcpds enetlctp` plus the
   repo's `verilator/mame/` tap tooling (docs/mame_compare.md; debugger
   defaults to the Egret HC05, MAME PCs are 8-digit). Rebuild cmd if ever
   needed: `make SUBTARGET=maclc SOURCES=src/mame/apple/maclc.cpp
   USE_QTDEBUG=0 REGENIE=1 -j$(nproc)` (plain build fails wanting Qt moc).
   Trace goals = the open watch items: does the driver spin-poll CR (shadow
   staleness → may need the designed-but-unbuilt pending-command overlay),
   does it touch the 24-bit $00Exxxxx forms (v2 decodes 32-bit only), what
   does it expect from the reg-window +2 half (we serve $FFFF).

## Open items ranked

1. OSD MAC config (the new requirement above) — replaces eth.cfg.
2. HW bring-up (checks 7-8) — user-driven; artifacts ready.
3. MAME driver trace (check 9) — oracle ready; do before or during HW
   debugging as needed.
4. After HW validation: release stamping per repo convention, and the
   NuBus port has its own rewritten resume prompt
   (docs/port_enet_to_nubus_cores.md — enetnbtp, easier: local card RAM).

## Pointers

- `docs/pds_ethernet_scope.md` — the architecture contract (v2).
- `CLAUDE.md` ethernet bullet — condensed feature entry + gate list.
- `docs/port_enet_to_nubus_cores.md` — the NuBus sibling's resume prompt.
- Memory: `pds-ethernet-feature.md` (auto-memory) mirrors this state.
- Gate evidence at park: `scratch/boot_p3_absent.png`,
  `scratch/boot_p3_present_520.png` (gitignored scratch, regenerable).
