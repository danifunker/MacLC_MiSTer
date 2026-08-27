# RESUME (autonomous): Main_MiSTer ethernet PR-prep — restyle + branch surgery

Work autonomously. Everything below is verified state as of 2026-08-27
~08:45 EDT. The FEATURE is done and HW-validated (see `memory/`
`eth-upload-wedge-rootcauses` + `eth-tx-and-throughput-fixed`); this
mission is purely about making the Main_MiSTer branch submittable
upstream. The user will open the PR themselves — prepare the branch,
never open or merge a PR.

## The verdict on the fork's master (already checked — do not re-derive)

- Fork `master` = `79aaf02`, **0 ahead / 7 behind** `upstream/master`
  (`0a8fb44`, remote `upstream` = MiSTer-devel/Main_MiSTer, already added
  to the local repo).
- **Upstream ALREADY CONTAINS `support/mac/`** — PR #1255 (BlueSCSI
  Toolbox/CD) merged as upstream `035b86f`. The user's belief is
  confirmed: no rebase is NEEDED. Base file `support/mac/mac.cpp` blob
  `4c06e81` is byte-identical in fork master, upstream master, and the
  base of `mac-ethernet` — the eth diff applies to upstream cleanly.
- Optional hygiene (recommended, safe): fast-forward fork master
  (`git checkout master && git merge --ff-only upstream/master &&
  git push origin master`) so the PR branch bases on current upstream.
  It CANNOT conflict (fork is 0 ahead).

## Branch surgery (do this FIRST, then restyle on the new branch)

- `mac-ethernet` @ `b308dbf` (pushed) stays UNTOUCHED = the dev branch.
  It keeps `support/mac/test/` (mac_sonic_test.cpp 104 checks +
  tcpsnoop.c) and the full 20+-commit history. It gets rebased onto the
  PR branch LATER (not this mission).
- Create **`mac-ethernet-pr`** from (ff'd) master. Squash the feature
  onto it as a SMALL curated series in which `support/mac/test/` NEVER
  EXISTS (the user requires the test code absent from the submitted
  branch's history, not merely deleted at the tip). Suggested series:
  1. `Mac: PDS Ethernet card support (Apple Ethernet LC Twisted Pair)`
     — mac_eth.cpp/.h, mac_eth_iface.cpp, mac_eth_declrom.h,
     mac_sonic.cpp/.h, the 5-line mac.cpp hook.
  2. `rtc: DST-aware UTC->local conversion for the Mac cores` — the
     user_io.cpp hunk alone (shared-code change reviewers will want
     isolated).
  Mechanics: `git checkout -b mac-ethernet-pr master &&
  git checkout mac-ethernet -- support/mac user_io.cpp &&
  git rm -r --cached support/mac/test && rm -rf support/mac/test`
  then commit in the two groups above (restyled — see below — BEFORE
  committing, so the PR history is born clean).
- Keep the `sonic_txd` witnesses / `/tmp/mac_eth_stats` in the PR —
  they are production diagnostics, not test code.
- `support/mac/test/tcpsnoop` (compiled binary) is untracked — never add.

## The restyle (apply on mac-ethernet-pr before its first commit)

House style was MEASURED against upstream (user_io.cpp, menu.cpp,
psx.cpp, x86.cpp, and support/mac's own mac.cpp/mac_cdrom.cpp):
comments are 1-line with rare 2-4-line exceptions; braces are next-line
(Allman) ~40:1; tabs; `printf("prefix: ...")` logging.

**Fix 1 — comments max ONE line, everywhere (user's hard rule).**
Current violations: mac_eth.cpp 29 blocks >1 line (max 15),
mac_sonic.cpp 22 (max 17), mac_eth_iface.cpp 4, mac_eth.h 1 (10 lines),
mac_sonic.h 6, and a 9-line block in the user_io.cpp hunk. Compress each
to a single line stating the INVARIANT or CONSTRAINT only (the "why
this must stay", never the discovery story). The archaeology is fully
preserved in `mac-ethernet` commit messages and MacLC_MiSTer
docs/memory — delete with zero loss. Examples of the target register:
- reload-release: `// leaving via reload must release in_use like a normal advance (driver defers frees on in_use!=0)`
- drain: `// bounded + publish per entry: the guest ISR spins until its acks read back applied`
- TX_PARK: `// abnormal exits park on the descriptor start; advancing past consumed words desyncs the ring walk`
- user_io hunk: `// Mac cores: resolve DST for the date so the guest RTC gets true local time`

**Fix 2 — no session language.** Zero dates, zero first person, zero
narrative. Gate: `grep -nE "2026-|watched|user request|stall #|lesson|today" <files>` must return nothing.

**Fix 3 — braces next-line** for functions AND control statements in
the NEW files (mac_eth.cpp currently 32 same-line vs 24 next-line;
mac_sonic.cpp 18 vs 16; mac_eth_iface 4 vs 9). Do not restyle any
upstream file beyond our own hunks.

**Fix 5 — nits.** `sonic_tx_new_chain()` → `static` (it is model-
internal; add a forward decl if placement needs it). Wrap the two
>100-column lines in mac_eth.cpp. Keep tabs; keep LF (the local working
tree shows CRLF warnings on commit — git normalizes, ignore them).

Re-audit gate (must be clean on the PR branch) — the measuring script:
sliding census of full-line `//` runs (>1 = violation) + the greps
above; also `git log --stat master..mac-ethernet-pr` must show NO
`support/mac/test/` anywhere.

## Behavior-neutrality gates (all must pass before done)

The restyle must not change behavior. The PR branch carries the same
fix set as `mac-ethernet` `b308dbf` (RX reload release, bounded drain +
per-apply publish, ISR ack clamp, TX ring-lap guard, status-gate park).
1. Unit tests 104/104: the test lives only on the dev branch now — run
   cross-branch: `git show mac-ethernet:support/mac/test/mac_sonic_test.cpp`
   into a scratch dir next to the PR branch's mac_sonic.cpp/.h; `g++ -O1
   -Wall`, run with `timeout 30` (an unkillable spin burned 8 CPU-hours
   once; always timeout).
2. ARM build: WSL, `PATH=/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin`,
   `make -j8` in /mnt/c/Temp/mistercore/Main_MiSTer → bin/MiSTer.
3. HW smoke on .94 (192.168.99.94, ssh -i ~/.ssh/mister_only): deploy
   the PR-branch binary (`killall MiSTer; scp; nohup /media/fat/MiSTer
   /media/fat/_Computer/MacLC_relcand.rbf &`), wait for the guest, run
   ONE 3 MB download AND ONE 3 MB PUT to completion (server file ≥
   3,145,856). All Fetch choreography, key codes, witnesses
   (`/tmp/mac_eth_stats`: `busy=` parks recover, `ab=0 ovs=0 laps=0`)
   and traps are in `docs/resume_eth_uploads_2026-08-27.md` + memory
   `eth-upload-wedge-rootcauses` (★ send `mouseBtn:left_up` TWICE — a
   lone release can drop; ★ Fetch launch: mouse-click the icon, never
   type-select 'f' into a still-drawing window — the Disk Copy trap).
   Restage `dd if=/dev/urandom of=/media/fat/testfile.bin bs=1M count=3`
   on the PEER box first. FTP root/1, Directory /media/fat.
4. After gates: push `mac-ethernet-pr` to origin (danifunker fork).
   Leave `mac-ethernet` and the boxes as-is. Tell the user the branch
   name and that opening the PR (target MiSTer-devel/Main_MiSTer
   master) is theirs to do.

## State snapshot (2026-08-27 08:45 EDT)

- Main fork: `mac-ethernet` @ b308dbf pushed; master 79aaf02; remote
  `upstream` fetched @ 0a8fb44.
- Core repo: `pds-enet-icache-fix` @ 93a90b7 pushed; release =
  MacLC_20260827.rbf (e4e22e7b, SEED 4, STA +0.151) + releases/MiSTer
  (508786f0) — this mission does not touch the core repo or the RBF.
- Boxes: both on e4e22e7b + Main 508786f0, guests at desktops, healthy;
  .94 restored to 24-bit baseline (32-bit spot check passed both ways);
  server test corpses cleaned, `testfile.bin` fixtures staged on both.
- Guest-side leftovers (cosmetic, ignore): dl*.bin files + a "tt"
  folder in the guests' Applications windows.
