/*
 * pds_enet.sv — Apple Ethernet LC Twisted Pair card (820-0532-B), LC PDS
 * pseudo-slot $E.
 *
 * v2 of the PDS Ethernet front-end (v1 was the Asante MacCON i LC; see
 * docs/pds_ethernet_scope.md for the full contract and the v1→v2 history).
 * The architecture is unchanged from v1: the FPGA side is a dumb front-end —
 * slot decode, register doorbell + read shadows, MAC PROM, and the declaration
 * ROM served from a DDR3 shared-memory window. The DP83934 SONIC-T model
 * (descriptor DMA, CAM, filters, TX/RX) and the bridge to a real network
 * interface run on the ARM inside the modified Main_MiSTer (support/mac),
 * which serves the same DDR3 window.
 *
 * Everything runs in clk_sys and the top drives DDRAM_CLK = clk_sys — no CDC.
 *
 * Guest-visible map (MAME enetlc.cpp `enetlctp` ground truth, 32-bit forms;
 * the Slot Manager and drivers access slot space in 32-bit mode):
 *   $FE00'0000-$FE00'01FF  SONIC registers: 64 x 16-bit, one per longword on
 *       the UPPER data lanes (word at longword+0; register index = A[7:2],
 *       no inversion; the $100-byte bank mirrors once in the $200 window).
 *       The +2 half of each longword is unmapped — served $FFFF, no stall.
 *   $FE04'0000-$FE04'01FF  MAC address PROM  (byte-read; mirrors every 8)
 *   $FE40'0000-$FE40'01FF  MAC address PROM  (alias — NetBSD reads it here)
 *       PROM bytes 0-5 = bit-swizzled MAC, 6 = $00, 7 = XOR checksum,
 *       complemented; cooked by Main into the MACPROM control word. Any
 *       word-wide read of the PROM window returns the magic $0028 (the
 *       driver's presence probe — MAME ground truth).
 *   $FEFF'8000-$FEFF'FFFF  declaration ROM, 32 KiB FLAT (341-0740 has
 *       byteLanes $0F — all four lanes; no lane expansion anywhere).
 *   IRQ: SONIC INT (level) -> pseudo-VIA slot-IFR reg $02 bit $20 (slot $E).
 *
 * The card has NO on-board RAM: the real SONIC bus-masters descriptors and
 * packets straight out of guest RAM. That path is the Phase-3 DMA-RPC engine
 * (ARM posts block read/write commands against guest SDRAM through the XFER
 * bounce window); this front-end deliberately knows nothing about it beyond
 * reserving the control words.
 *
 * DDR3 window v2 (ARM phys 0x1FF00000 — layout is THE contract, mirrored in
 * docs/pds_ethernet_scope.md and Main's support/mac/mac_eth.h):
 *   +0x00000  64K  XFER bounce buffer (guest-RAM DMA staging; Phase 3)
 *   +0x10000  64K  declROM window: window byte i = guest $FEFF'0000+i, so the
 *                  flat ROM occupies the top half (+0x8000..+0xFFFF)
 *   +0x20000       control block, 64-bit words:
 *       w0  +0x00 MAGIC    (ARM->FPGA) 64'h4D634C43_45544832 "McLCETH2"
 *       w1  +0x08 CMD_WPTR (FPGA->ARM) doorbell ring write index, monotonic
 *       w2..w17   SHADOWS  (ARM->FPGA) 64 regs x 16-bit: word n = regs
 *                 4n..4n+3, register 4n+k at bits [16k+15:16k]
 *       w18 +0x90 INT      (ARM->FPGA) bit0 = SONIC INT line state
 *       w19 +0x98 MACPROM  (ARM->FPGA) 8 cooked PROM bytes, byte k = PROM k
 *       w20 +0xA0 GEOMETRY (ARM only) layout version = 2
 *       w21 +0xA8 RPTR     (ARM->FPGA) daemon ring read index (backpressure)
 *       w22 +0xB0 DMA_CMD  (ARM->FPGA) Phase-3 guest-RAM DMA command
 *       w23 +0xB8 DMA_STAT (FPGA->ARM) Phase-3 DMA completion/seq echo
 *   +0x20800  2K   CMD ring, 256 x 64-bit, entry:
 *       bit0 = valid, [3:1] = tag, [9:4] = SONIC reg index, [31:16] = data,
 *       [39:32] = seq (reserved, 0)
 *       tags: 0 = REG_WR    1 = RESET (guest warm restart)
 *
 * Doorbell discipline (the A2065 lesson, kept from v1): register writes
 * stretch DTACK only until the ring entry + write pointer are IN DDR3 — never
 * until the ARM runs. Register and PROM reads are answered instantly from the
 * shadows/PROM word. Only declROM reads stretch for a DDR3 round trip. There
 * is no path that waits on host software at all in v2 (the SONIC has no CPU
 * data port), so a dead host can never wedge the guest.
 *
 * Presence: the card decodes only if MAGIC was valid at the moment the guest
 * came out of reset (and the OSD option is on). No service = pseudo-slot $E
 * stays exactly as today (open-bus $FFFF ack in the tops). The v2 MAGIC value
 * means a v1 daemon and a v2 FPGA (or vice versa) can never half-pair.
 */

module pds_enet (
	input             clk_sys,
	input             rst_core,      // hard reset (POR / core load), active high
	input             rst_guest,     // guest reset (RESET instruction etc.), active high
	input             ena_osd,       // OSD "Ethernet" option

	// CPU bus (clk_sys, TG68 16-bit bus conventions of the tops)
	input      [31:0] cpuAddr,
	input      [15:0] cpuDataIn,     // CPU write data (cpuDataOut of the tops)
	input             _cpuAS,
	input             _cpuUDS,
	input             _cpuLDS,
	input             _cpuRW,        // 1 = read

	output            card_sel,      // card claims this bus cycle (gate VPA/DTACK/din in top)
	output            card_ack,      // cycle may complete (data valid on reads)
	output     [15:0] card_dout,
	output            irq,           // active high -> pds_slot_irq

	// DDR3 / DDRAM port (clk_sys — top must drive DDRAM_CLK = clk_sys)
	output reg [28:0] mem_addr,
	output reg  [7:0] mem_burst,
	output reg        mem_rd,
	output reg        mem_we,
	output reg [63:0] mem_wdata,
	output reg  [7:0] mem_be,
	input      [63:0] mem_rdata,
	input             mem_rvalid,
	input             mem_busy
);

	// ── DDR3 window layout (64-bit word addresses) ──────────────────────────
	localparam [28:0] AV_BASE    = 29'h03FE0000;   // ARM 0x1FF00000
	localparam [14:0] AV_XFER    = 15'h0000;       // +0x00000, 8192 words (Phase 3)
	localparam [14:0] AV_ROM     = 15'h2000;       // +0x10000, 8192 words
	localparam [14:0] AV_MAGIC   = 15'h4000;       // control block
	localparam [14:0] AV_WPTR    = 15'h4001;
	localparam [14:0] AV_SHAD    = 15'h4002;       // 16 words (64 regs)
	localparam [14:0] AV_INT     = 15'h4012;
	localparam [14:0] AV_MACPROM = 15'h4013;
	localparam [14:0] AV_GEO     = 15'h4014;       // ARM-only, not polled
	localparam [14:0] AV_RPTR    = 15'h4015;
	localparam [14:0] AV_DMACMD  = 15'h4016;       // Phase 3
	localparam [14:0] AV_DMASTAT = 15'h4017;       // Phase 3
	localparam [14:0] AV_RING    = 15'h4100;       // 256 words

	localparam [63:0] MAGIC_V  = 64'h4D634C43_45544832;   // "McLCETH2"

	localparam [2:0] TAG_REG_WR = 3'd0;
	localparam [2:0] TAG_RESET  = 3'd1;

	// ── slot decode ─────────────────────────────────────────────────────────
	// 32-bit standard slot space $FExx'xxxx only (MAME's LC/LC II card map;
	// the Slot Manager scans in 32-bit mode — v1 sim proved it). Everything
	// unclaimed in $F1-$FE keeps the top's hardware-validated open-bus ack.
	// If the Phase-5 MAME driver trace shows 24-bit forms in use, add them.
	wire        form32 = (cpuAddr[31:24] == 8'hFE);
	wire [23:0] sub    = cpuAddr[23:0];

	wire sel_reg = form32 && (sub[23:9] == 15'h0000);   // $000000-$0001FF
	wire sel_mac = form32 && ((sub[23:9] == 15'h0200)   // $040000-$0401FF
	                       || (sub[23:9] == 15'h2000)); // $400000-$4001FF
	wire sel_rom = form32 && (sub[23:15] == 9'h1FF);    // $FF8000-$FFFFFF

	wire ds_any  = ~_cpuUDS | ~_cpuLDS;
	wire cyc     = !_cpuAS && ds_any;   // strobes valid: direction + data good

	assign card_sel = present && (sel_reg | sel_mac | sel_rom) && !_cpuAS;

	wire req = present && (sel_reg | sel_mac | sel_rom) && cyc;

	// Register-window access classification: the SONIC's 16 data lines sit on
	// the upper lanes of each longword, so the register is the word at
	// longword+0 (sub[1]==0). Reads there are shadow-served whatever the
	// strobes (a byte read just takes its half). Writes must be full words —
	// partial register writes don't exist on the real card; they (and the
	// dead +2 half) fall through to K_STUB: $FFFF on reads, ignored on
	// writes, never a stall, never a doorbell.
	wire word_acc = !_cpuUDS && !_cpuLDS;
	wire reg_rd   = sel_reg && (sub[1] == 1'b0) && _cpuRW;
	wire reg_wr   = sel_reg && (sub[1] == 1'b0) && !_cpuRW && word_acc;

	wire [5:0] reg_idx = sub[7:2];

	// ── shadows / PROM / INT / MAGIC (poll results) ─────────────────────────
	reg [63:0] shad [0:15];
	reg [63:0] macprom;
	reg        int_state;
	reg        magic_ok;

	// presence: latched while the guest is in reset, held stable across the
	// whole session so the Slot Manager never sees the card flicker.
	reg        present;

	wire [63:0] shad_word   = shad[reg_idx[5:2]];
	wire [15:0] sonic_rdata = shad_word[{reg_idx[1:0], 4'b0000} +: 16];

	// ── CPU-side request handshake (all clk_sys, no CDC) ────────────────────
	localparam H_IDLE = 2'd0, H_RUN = 2'd1, H_DONE = 2'd2;
	reg  [1:0] hstate;
	reg [15:0] dout_r;
	reg [23:0] req_sub;
	reg  [1:0] req_be;         // {UDS, LDS}
	reg [15:0] req_wdata;
	reg  [2:0] req_kind;
	localparam K_ROM = 3'd0, K_REGRD = 3'd1, K_REGWR = 3'd2, K_MACRD = 3'd3,
	           K_STUB = 3'd4;

	assign card_ack  = (hstate == H_DONE);
	assign card_dout = dout_r;

	// MAC PROM byte select: addresses are word-aligned on this bus (A0 lives
	// in the strobes), so the byte index is {A2,A1, odd} with odd = LDS-only.
	// Mirrors every 8 bytes through the whole $200 window (the LC III maps
	// are literally 8 bytes long — that is the real decode).
	wire [2:0] prom_idx  = {req_sub[2:1], req_be[1] ? 1'b0 : 1'b1};
	wire [7:0] prom_byte = macprom[{prom_idx, 3'b000} +: 8];

	// ── doorbell / mailbox FSM ──────────────────────────────────────────────
	localparam S_IDLE      = 4'd0;
	localparam S_CMD_W     = 4'd1;   // ring entry write in flight
	localparam S_WPTR_W    = 4'd2;   // wptr publish in flight
	localparam S_MEM_RD_W  = 4'd3;
	localparam S_MEM_RD_D  = 4'd4;
	localparam S_POLL_W    = 4'd5;
	localparam S_POLL_D    = 4'd6;
	localparam S_WPTR_INIT = 4'd7;

	reg  [3:0] state;
	// 32-bit monotonic doorbell count (ring index = wptr[7:0]); published in
	// full so the daemon can tell a ring wrap from an FPGA reset (the A2065
	// publishes its cmd_wr_idx the same way).
	reg [31:0] wptr;
	reg        wptr_published;
	reg [63:0] cmd_entry;      // pending ring entry (one deep)
	reg        cmd_queued;
	reg        cmd_for_cpu;    // the stalled CPU cycle completes on publish
	reg [15:0] poll_div;
	reg  [4:0] poll_step;      // walks MAGIC, SHAD0-15, INT, MACPROM, RPTR
	reg  [4:0] poll_step_q;
	reg        rst_guest_d;

	// ring backpressure: the daemon publishes its read index (AV_RPTR, polled
	// below); if a doorbell burst gets ~200 entries ahead the publish stalls —
	// bounded by cmd_wait_ctr (~2 ms) so a dead host can never hang the
	// guest, it just loses entries it wasn't reading anyway.
	reg [31:0] rptr_sh;
	reg [15:0] cmd_wait_ctr;
	wire       ring_full = (wptr - rptr_sh) >= 32'd200;

	// fast polling while the doorbell is backpressured (rptr_sh must refresh
	// to release it); Phase 3 adds the DMA-armed condition here.
	wire       poll_due  = (cmd_queued && ring_full) ? (poll_div[4:0] == 5'h1F)
	                     : magic_ok ? (poll_div[9:0] == 10'h3FF)
	                     : (poll_div == 16'hFFFF);

	wire [28:0] rom_word = AV_BASE + {14'b0, AV_ROM} + {16'b0, req_sub[15:3]};
	wire  [2:0] lane     = req_sub[2:0];   // byte lane of the D[15:8] byte

	integer i;
	always @(posedge clk_sys) begin
		if (rst_core) begin
			state       <= S_IDLE;
			hstate      <= H_IDLE;
			mem_rd      <= 0;
			mem_we      <= 0;
			mem_burst   <= 8'd1;
			mem_addr    <= 0;
			mem_wdata   <= 0;
			mem_be      <= 8'hFF;
			wptr        <= 0;
			wptr_published <= 0;
			cmd_queued  <= 0;
			cmd_for_cpu <= 0;
			poll_div    <= 0;
			poll_step   <= 0;
			poll_step_q <= 0;
			rst_guest_d <= 0;
			magic_ok    <= 0;
			int_state   <= 0;
			present     <= 0;
			macprom     <= 0;
			rptr_sh     <= 0;
			cmd_wait_ctr<= 0;
			dout_r      <= 16'hFFFF;
			req_sub     <= 0;
			req_be      <= 0;
			req_wdata   <= 0;
			req_kind    <= K_STUB;
			for (i = 0; i < 16; i = i + 1) shad[i] <= 64'h0;
		end else begin
			mem_rd <= 0;
			mem_we <= 0;
			poll_div <= poll_div + 1'b1;

			// presence can only change while the guest is held in reset; once
			// running it is frozen so the Slot Manager never sees the card
			// flicker. Sticky-rise on MAGIC within the reset window: rst_core
			// is hard-reset only, so a warm restart keeps the mailbox state
			// and just re-evaluates presence (and a host death mid-session
			// deliberately does NOT clear it — DDR3 keeps serving the ROM and
			// registers, writes still complete since they only wait on DDR3).
			rst_guest_d <= rst_guest;
			if (rst_guest) begin
				if (!ena_osd)      present <= 1'b0;
				else if (magic_ok) present <= 1'b1;
				// tell the host to reset its SONIC model (once per reset entry)
				if (!rst_guest_d && present && !cmd_queued && magic_ok) begin
					cmd_entry   <= {60'b0, TAG_RESET, 1'b1};
					cmd_queued  <= 1'b1;
					cmd_for_cpu <= 1'b0;
				end
			end

			// ── CPU handshake ────────────────────────────────────────────
			case (hstate)
			H_IDLE: if (req) begin
				req_sub   <= sub;
				req_be    <= {~_cpuUDS, ~_cpuLDS};
				req_wdata <= cpuDataIn;
				dout_r    <= 16'hFFFF;
				// classify
				if (reg_rd)                  req_kind <= K_REGRD;
				else if (reg_wr)             req_kind <= K_REGWR;
				else if (sel_mac && _cpuRW)  req_kind <= K_MACRD;
				else if (sel_rom && _cpuRW)  req_kind <= K_ROM;
				else                         req_kind <= K_STUB;
				hstate <= H_RUN;
			end
			H_RUN: begin
				case (req_kind)
				K_REGRD: begin
					dout_r <= sonic_rdata;
					hstate <= H_DONE;
				end
				K_REGWR: begin
					if (!cmd_queued) begin
						cmd_entry   <= {24'b0, 8'b0, req_wdata, 6'b0, reg_idx, TAG_REG_WR, 1'b1};
						cmd_queued  <= 1'b1;
						cmd_for_cpu <= 1'b1;   // H_DONE comes from the publish path
					end
				end
				K_MACRD: begin
					dout_r <= (req_be == 2'b11) ? 16'h0028 : {2{prom_byte}};
					hstate <= H_DONE;
				end
				K_STUB: begin
					dout_r <= 16'hFFFF;
					hstate <= H_DONE;
				end
				default: ;   // K_ROM completes via the mailbox FSM below
				endcase
			end
			H_DONE: begin
				if (_cpuAS || !ds_any) hstate <= H_IDLE;
			end
			default: hstate <= H_IDLE;
			endcase

			// ── mailbox FSM ──────────────────────────────────────────────
			if (cmd_queued && ring_full && state == S_IDLE) begin
				if (!(&cmd_wait_ctr)) cmd_wait_ctr <= cmd_wait_ctr + 1'b1;
			end else if (!cmd_queued)
				cmd_wait_ctr <= 0;

			case (state)
			S_IDLE: begin
				if (!wptr_published) begin
					mem_addr  <= AV_BASE + {14'b0, AV_WPTR};
					mem_wdata <= 64'd0;
					mem_be    <= 8'hFF;
					mem_we    <= 1;
					state     <= S_WPTR_INIT;
				end else if (cmd_queued && (!ring_full || (&cmd_wait_ctr))) begin
					mem_addr  <= AV_BASE + {14'b0, AV_RING} + {21'b0, wptr[7:0]};
					mem_wdata <= cmd_entry;
					mem_be    <= 8'hFF;
					mem_we    <= 1;
					state     <= S_CMD_W;
				end else if (hstate == H_RUN && req_kind == K_ROM) begin
					mem_addr <= rom_word;
					mem_rd   <= 1;
					state    <= S_MEM_RD_W;
				end else if (poll_due) begin
					poll_step_q <= poll_step;
					mem_addr <= AV_BASE + {14'b0,
					            (poll_step == 5'd0)  ? AV_MAGIC   :
					            (poll_step == 5'd17) ? AV_INT     :
					            (poll_step == 5'd18) ? AV_MACPROM :
					            (poll_step == 5'd19) ? AV_RPTR    :
					                                   AV_SHAD + {10'b0, poll_step - 5'd1}};
					mem_rd   <= 1;
					state    <= S_POLL_W;
				end
			end

			S_CMD_W: begin
				if (!mem_busy) begin
					mem_addr  <= AV_BASE + {14'b0, AV_WPTR};
					mem_wdata <= {32'b0, wptr + 32'd1};
					mem_be    <= 8'hFF;
					mem_we    <= 1;
					wptr      <= wptr + 32'd1;
					state     <= S_WPTR_W;
				end else mem_we <= 1;
			end

			S_WPTR_W: begin
				if (!mem_busy) begin
					cmd_queued <= 0;
					if (cmd_for_cpu) begin
						cmd_for_cpu <= 0;
						hstate      <= H_DONE;   // register write retires
					end
					state <= S_IDLE;
				end else mem_we <= 1;
			end

			S_WPTR_INIT: begin
				if (!mem_busy) begin
					wptr_published <= 1;
					state <= S_IDLE;
				end else mem_we <= 1;
			end

			S_MEM_RD_W: begin
				if (!mem_busy) state <= S_MEM_RD_D;
				else mem_rd <= 1;
			end

			S_MEM_RD_D: begin
				if (mem_rvalid) begin
					dout_r[15:8] <= mem_rdata[{lane,          3'b000} +: 8];
					dout_r[7:0]  <= mem_rdata[{lane + 3'd1,   3'b000} +: 8];
					hstate <= H_DONE;
					state  <= S_IDLE;
				end
			end

			S_POLL_W: begin
				if (!mem_busy) state <= S_POLL_D;
				else mem_rd <= 1;
			end

			S_POLL_D: begin
				if (mem_rvalid) begin
					case (poll_step_q)
					5'd0:  magic_ok  <= (mem_rdata == MAGIC_V);
					5'd17: int_state <= mem_rdata[0];
					5'd18: macprom   <= mem_rdata;
					5'd19: rptr_sh   <= mem_rdata[31:0];
					default: shad[poll_step_q[3:0] - 4'd1] <= mem_rdata;
					endcase
					// walk the full set only when the card is live; otherwise
					// just keep sampling MAGIC.
					if (magic_ok || poll_step_q != 5'd0)
						poll_step <= (poll_step_q == 5'd19) ? 5'd0 : poll_step_q + 5'd1;
					state <= S_IDLE;
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end

	assign irq = int_state && present;

endmodule
