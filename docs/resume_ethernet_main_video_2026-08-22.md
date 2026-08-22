# RESUME — PDS Ethernet HW bring-up: guest hangs at boot when the card is ON

Paste as the opening prompt in `C:\Temp\mistercore\MacLC_MiSTer`. Two trees:
- Core: `MacLC_MiSTer`, branch **`pds-enet-icache-fix`** (ethernet + I-cache fix).
- Main (HPS): `C:\Temp\mistercore\Main_MiSTer`, branch **`mac-ethernet`** @ `34b8994`.

Bench `.143` (`scripts/local.env`). Load cores via the **OSD**, never
`/api/settings/system/reboot`. Never hard-reload a running Mac guest — Special ▸
Shut Down first. A Main-binary swap DOES require a full reboot (that's fine when
no guest is running: check `coreRunning` empty first).

## ★ THE OPEN PROBLEM (start here)

**With the Ethernet card ENABLED (OSD Ethernet = On, `status[19]=0`,
`ena_osd=1`), the Mac guest HANGS during startup — only one extension icon
appears.** With Ethernet **OFF** (`status[19]=1`) the guest boots fine. So the
card being *active* stalls early boot.

**Key clue — the HPS half works:** `dmesg` shows `device eth0 entered
promiscuous mode`, i.e. the Main `mac_eth` service is running and bound to the
NIC. So the hang is on the **guest/core side**, not the daemon.

**Most likely mechanism (this is the classic sim-passes/HW-hangs pattern seen
before on this core — icache, SCSI stale-done):** when the card is enabled it
CLAIMS slot-$E cycles (`card_sel`), and a claimed CPU access is **not completing
on hardware** — `card_ack`/DTACK never asserts → the 68k hangs forever. "One
icon" = the hang is at the **Slot Manager's declROM probe** (very early, pre-
driver), not the guest driver. When the card is OFF, `card_sel=0` and slot space
falls through to the hardware-validated open-bus `$FFFF` ack (cardless path), so
boot proceeds — which is exactly why disabling it boots.

### Diagnostic / fix plan (next session)
1. **Confirm where it hangs.** Reproduce with Ethernet On; the guest should be
   probing slot $E. The declROM is served **from DDR3** (the Main stages
   `AppleLCTwistedPair.BIN` into DDR3, then answers guest reads via the mailbox).
   Suspect the guest read of the declROM (or the card regs) never returns
   `card_ack` → CPU DTACK never asserts.
2. **Audit `rtl/pds/pds_enet.sv` `card_sel`/`card_ack`/`card_dout` + the
   `mem_rd → mem_rvalid → card_ack` handshake.** Does EVERY claimed cycle
   complete (ack or bus-error) within a bounded time? On HW the DDR3 mailbox
   round-trip (guest read → pds_enet → DDR3 → Main service → response) has real
   latency the sim doesn't model. If the response can stall, the CPU hangs.
3. **Add a timeout/bus-error backstop** on a stalled card access (mirror the
   SCSI pseudo-DMA `SDMA_TIMEOUT` in MacLC.sv: a claimed cycle that isn't served
   in N must BUS-ERROR, which the boot ROM tolerates, instead of hanging). This
   alone may turn the fatal hang into a graceful "no card".
4. **Ground truth:** compare the guest's slot-$E probe sequence to MAME's LC
   ethernet enumeration (SONIC + declROM reads) — `verilator/mame/` tooling,
   `docs/mame_compare.md`.
5. **Instrument on HW:** the HUD/JTAG bus-cycle probes on the card's slot
   accesses; `docs/pds_ethernet_scope.md` is the architecture contract; the
   mailbox/DMA discipline is in `rtl/sdram.v`'s 4th requester + the Main
   `support/mac/mac_eth*.cpp`.
6. The guest driver ("network drivers 1.5.1") is downstream of enumeration — the
   one-icon hang is BEFORE it, so fix enumeration first; the driver is not the
   suspect yet.
7. Offline gates still green (`tb_pds_enet` 43/43, `mac_sonic_test` 36/36) — the
   defect is HW-timing, invisible offline. When adding a card-side timeout/ack
   change, re-run `tb_pds_enet` and rebuild the core.

## ★ RESOLVED THIS SESSION — video regression (was gray screen)

Deploying the ethernet Main first gave a **gray screen / no video**. Root cause:
the on-disk **08-21 pre-built `bin/MiSTer` (`8d31da27`) was a bad/stale build**
even though it was "the same commit". A **clean rebuild** (`make clean && make`
from `mac-ethernet` @ `34b8994`) produced **`fb147563`** → **video works**.
LESSON: never trust an old pre-built Main; always `make clean` + rebuild.
- Toolchain: `/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin`
  (Makefile `BASE=arm-none-linux-gnueabihf`), output `bin/MiSTer`.
- **Deployed Main = `fb147563`** at `/media/fat/MiSTer`. Overwrite trick (the
  running Main locks the file): `scp` to `MiSTer.new`, then `mv -f` over it.
- Recovery-only backup (no-ethernet, old): `/media/fat/MiSTer.bak_pre_eth`
  (`dda65f18`, 2026-08-01, upstream base `4510442`). **Do NOT roll back** — the
  ethernet Main must stay (user ruling); it also carries the CD/toolbox support.

## ★ SHIPPED — I-cache crash fix (do not reopen)

8bpp+32-bit Finder crash FIXED, zero-cost, HW-confirmed on **two** independent
fits (varA and the ethernet+fix core) → functional, not placement luck. **One
line:** `fetch_cache .enable` from constant `1'b1` to a **non-constant net** =1
(`~status[11]`, bit 11 free) — stops Quartus folding `enable_r`, so the
hit/DTACK/suppression structure no longer races. Immediate hit answer kept
(~97%). Handoff for the Analogue Pocket: `docs/pocket_icache_fix_handoff.md`
(never edit the Pocket tree). Repro to test any core rebuild: 256 colors +
32-bit addressing persisted via **Special ▸ Shut Down** (in-core Restart broken),
reboot + open windows; **1-bit HIDES it**. Golden NVRAM saved:
`scratch/MacLC.nvr.CRASHCFG_8bpp32bit_20260822` (`66181d2e`) + on box. Desktop-
agnostic `scratch/classify.py`.

## Box state

- `/media/fat/MiSTer` = **`fb147563`** (ethernet+CD Main, video-good). Backup
  `MiSTer.bak_pre_eth` = `dda65f18`.
- `/media/fat/_Unstable/MacLC.rbf` = **`d09b3e20`** (canonical: ethernet +
  I-cache fix). `MacLC_20260821.rbf` = `8896c2b2` (verified I-cache fix, no
  ethernet — fallback). `MacLCii*` / `_Computer/*` untouched.
- `MACLC.cfg` = `18 00 00 00` → Ethernet **On** (`status[19]=0`), 10MB, I-cache
  on. To BOOT the guest set Ethernet Off (`status[19]=1` → cfg byte2 `|= 0x08`);
  to REPRO the hang set it On.

## Repo state (core)

| branch | commit | what |
|---|---|---|
| `pds-enet-icache-fix` | `d4c4efd` | CURRENT — off `apple-pds-ethernet` 6d89710; ethernet (SONIC+DMA) + I-cache fix. `MacLC.rbf` = `d09b3e20` |
| `apple-pds-ethernet` | `6d89710` | full ethernet, pristine |
| `icache-osd-relbase` | `ad53af0` | `varA` = release + only enable fix = `8896c2b2`. `eef20ac` = dlysel source (`c3c9ca50`) |
| release | `454429e` | `MacLC_20260819` = `65332d3b` (`.enable(1'b1)`, crashes) |

Main fork `mac-ethernet` @ `34b8994` (only an untracked `lib/miniz/ChangeLog.md`
touched). Gates: `tb_pds_enet`/`mac_sonic_test`/`tb_fetch_cache`/`tb_icache_seam`
all PASS.

## What NOT to do
- Do NOT roll the Main back to `dda65f18` (fix forward — user ruling).
- Do NOT reopen the I-cache fix (shipped, HW-confirmed twice).
- Do NOT trust the old `8d31da27` pre-built — rebuild clean.
- Do NOT edit `sys/` piecemeal or the Analogue Pocket tree.
