module dataController_top(
	// clocks:
	input clk32,					// 32.5 MHz pixel clock
	input clk8_en_p,
	input clk8_en_n,
	input E_rising,
	input E_falling,

	// system control:
	input _systemReset,
	input pseudovia_irq,  // PseudoVIA interrupt (VBlank, slots)

	// 68000 CPU control:
	output _cpuReset,
	output [2:0] _cpuIPL,

	// 68000 CPU memory interface:
	input [15:0] cpuDataIn,
	input [3:0] cpuAddrRegHi, // A12-A9
	input [2:0] cpuAddrRegMid, // A6-A4
	input [1:0] cpuAddrRegLo, // A2-A1
	input _cpuUDS,
	input _cpuLDS,	
	input _cpuRW,
	output [15:0] cpuDataOut,
	
	// peripherals:
	input selectSCSI,
	input selectSCC,
	input selectIWM,
	input selectVIA,
	input selectSEOverlay,
	input _cpuVMA,
	
	
	input selectAriel,
	input [7:0] ariel_data_in,
	input selectPseudoVIA,
	input [7:0] pseudovia_data_in,

	// RAM/ROM:

	// RAM/ROM:
	input videoBusControl,	
	input cpuBusControl,	
	input [15:0] memoryDataIn,
	output [15:0] memoryDataOut,
	input memoryLatch,
	
	// keyboard:
	input [10:0] ps2_key,
	output capslock, 
	 
	// mouse:
	input [24:0] ps2_mouse,
	
	// serial:
	input serialIn, 
	output serialOut,	
	input serialCTS,
	output serialRTS,

	// RTC
	input [32:0] timestamp,

	// video:
	output pixelOut,	
	input _hblank,
	input _vblank,
	input loadPixels,
	output vid_alt,

	// audio
	output [10:0] audioOut,  // 8 bit audio + 3 bit volume
	output snd_alt,
	input loadSound,
	
	// misc
	output memoryOverlayOn,
	input [1:0] insertDisk,
	input [1:0] diskSides,
	output [1:0] diskEject,
	output [1:0] diskMotor,
	output [1:0] diskAct,

	output [21:0] dskReadAddrInt,
	input dskReadAckInt,
	output [21:0] dskReadAddrExt,
	input dskReadAckExt,

	// connections to io controller
	input   [SCSI_DEVS-1:0] img_mounted,
	input            [31:0] img_size,
	output           [31:0] io_lba[SCSI_DEVS],
	output  [SCSI_DEVS-1:0] io_rd,
	output  [SCSI_DEVS-1:0] io_wr,
	input   [SCSI_DEVS-1:0] io_ack,
	input             [7:0] sd_buff_addr,
	input            [15:0] sd_buff_dout,
	output           [15:0] sd_buff_din[SCSI_DEVS],
	input                   sd_buff_wr
);
	
	parameter SCSI_DEVS = 2;
	
	// add binary volume levels according to volume setting
	assign audioOut = 
		(snd_vol[0]?audio_x1:11'd0) +
		(snd_vol[1]?audio_x2:11'd0) +
		(snd_vol[2]?audio_x4:11'd0);

	// three binary volume levels *1, *2 and *4, sign expanded
	wire [10:0] audio_x1 = { {3{audio_latch[7]}}, audio_latch };
	wire [10:0] audio_x2 = { {2{audio_latch[7]}}, audio_latch, 1'b0 };
	wire [10:0] audio_x4 = {    audio_latch[7]  , audio_latch, 2'b00};
	
	reg loadSoundD;
	always @(posedge clk32)
		if (clk8_en_n) loadSoundD <= loadSound;

	// read audio data and convert to signed for further volume adjustment
	reg [7:0] audio_latch;
	always @(posedge clk32) begin
		if(clk8_en_p && loadSoundD) begin
			if(snd_ena) audio_latch <= 8'h7f;
 // when disabled, drive output high
			else  	 	audio_latch <= memoryDataIn[15:8] - 8'd128;
		end
	end
	
	// CPU reset generation
	// Mac LC boot sequence: Egret controls when 68000 comes out of reset via Port C bit 3
	// We also need a minimum reset time for the 68000 (100ms = 800,000 clocks of clk8)
	// The 68000 reset is released when:
	//   1. The minimum reset time has passed
	//   2. _systemReset is not asserted
	//   3. Egret has released reset_680x0 (Port C bit 3 = 1)

	reg [19:0] resetDelay; // 20 bits = 1 million
	wire minResetPassed = (resetDelay == 0);

	// Egret controls 68000 reset via Port C bit 3
`ifdef USE_EGRET_CPU
	wire egret_reset_680x0;  // 1 = hold 68000 in reset, 0 = release
`endif

	initial begin
		// force a reset when the FPGA configuration is completed
		resetDelay <= 20'hFFFFF;
	end

	always @(posedge clk32 or negedge _systemReset) begin
		if (_systemReset == 1'b0) begin
			resetDelay <= 20'hFFFFF;
		end
		else if (clk8_en_p && !minResetPassed) begin
			resetDelay <= resetDelay - 1'b1;
		end
	end

`ifdef USE_EGRET_CPU
	// With real Egret: 68000 reset is controlled by Egret (but respect minimum time)
	assign _cpuReset = (minResetPassed && !egret_reset_680x0) ? 1'b1 : 1'b0;
`else
	// Without Egret: just use the timer
	assign _cpuReset = minResetPassed ? 1'b1 : 1'b0;
`endif

	// Egret reset generation - Egret needs to start BEFORE the 68000
	// The real Egret starts very early and controls when the 68000 comes out of reset
	// Count up from boot, release Egret after 256 clk8 cycles regardless of _systemReset
	reg [9:0] egretBootCounter = 0;
	wire egretReset = (egretBootCounter < 10'd256);

	always @(posedge clk32) begin
		if (egretBootCounter < 10'd512) begin  // Stop counting once well past threshold
			if (clk8_en_p)
				egretBootCounter <= egretBootCounter + 1'b1;
		end
	end

`ifdef SIMULATION
	reg [31:0] dc_debug_count = 0;
	reg egretReset_prev = 1;
`ifdef USE_EGRET_CPU
	reg egret_reset_680x0_prev = 1;
	reg cpuReset_prev = 0;
`endif
	always @(posedge clk32) begin
		dc_debug_count <= dc_debug_count + 1;
		egretReset_prev <= egretReset;
		if (egretReset != egretReset_prev) begin
			$display("DC[%0d]: egretReset %s (egretBootCounter=%0d)",
			         dc_debug_count, egretReset ? "ASSERTED" : "RELEASED", egretBootCounter);
		end
`ifdef USE_EGRET_CPU
		egret_reset_680x0_prev <= egret_reset_680x0;
		cpuReset_prev <= _cpuReset;
		// Track when Egret releases/asserts 68000 reset
		if (egret_reset_680x0 != egret_reset_680x0_prev) begin
			$display("DC[%0d]: Egret %s 68000 reset (minResetPassed=%b, _cpuReset=%b)",
			         dc_debug_count,
			         egret_reset_680x0 ? "ASSERTS" : "RELEASES",
			         minResetPassed, _cpuReset);
		end
		// Track when 68000 actually comes out of reset
		if (_cpuReset != cpuReset_prev) begin
			$display("DC[%0d]: *** 68000 reset %s *** (egret_reset=%b, minResetPassed=%b)",
			         dc_debug_count,
			         _cpuReset ? "RELEASED" : "ASSERTED",
			         egret_reset_680x0, minResetPassed);
		end
`endif
	end
`endif
	
	// interconnects
	wire SEL;
	wire _viaIrq, _sccIrq, sccWReq;
	wire [15:0] viaDataOut;
	wire [15:0] iwmDataOut;
	wire [7:0] sccDataOut;
	wire [7:0] scsiDataOut;
	wire mouseX1, mouseX2, mouseY1, mouseY2, mouseButton;
	
	// Mac LC interrupt priorities (active low encoding: 111=none, 110=1, 101=2, 011=4, etc.)
	// Level 1: VIA1
	// Level 2: PseudoVIA (VBlank, slot interrupts)
	// Level 4: SCC
	assign _cpuIPL =
		!_sccIrq      ? 3'b011 :   // Level 4: SCC (highest priority)
		pseudovia_irq ? 3'b101 :   // Level 2: PseudoVIA
		!_viaIrq      ? 3'b110 :   // Level 1: VIA1
		3'b111;                     // No interrupt
		

	reg [15:0] cpu_data;
	always @(posedge clk32) if (cpuBusControl && memoryLatch) cpu_data <= memoryDataIn;

	// CPU-side data output mux
assign cpuDataOut = selectIWM ? iwmDataOut :
                    selectVIA ? viaDataOut :
                    selectSCC ? { sccDataOut, 8'hEF } :
                    selectSCSI ? { scsiDataOut, 8'hEF } :
                    selectAriel ? {ariel_data_in, ariel_data_in} :
                    selectPseudoVIA ? {pseudovia_data_in, pseudovia_data_in} :
                    (cpuBusControl && memoryLatch) ? memoryDataIn : cpu_data;
	
	// Memory-side
	assign memoryDataOut = cpuDataIn;

	// SCSI
	ncr5380 #(SCSI_DEVS) scsi(
		.clk(clk32),
		.reset(!_cpuReset),
		.bus_cs(selectSCSI),
		.bus_rs(cpuAddrRegMid),
		.ior(!_cpuUDS),
		.iow(!_cpuLDS),
		.dack(cpuAddrRegHi[0]),   // A9
		.wdata(cpuDataIn[15:8]),
		.rdata(scsiDataOut),

		// connections to io controller
		.img_mounted( img_mounted ),
		.img_size( img_size ),
		.io_lba ( io_lba ),
		.io_rd ( io_rd ),
		.io_wr ( io_wr ),
		.io_ack ( io_ack ),

		.sd_buff_addr(sd_buff_addr),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr)
	);

	// count vblanks, and set 1 second interrupt after 60 vblanks
	reg [5:0] vblankCount;
	reg _lastVblank;
	always @(posedge clk32) begin
		if (clk8_en_n) begin
			_lastVblank <= _vblank;
			if (_vblank == 1'b0 && _lastVblank == 1'b1) begin
				if (vblankCount != 59) begin
					vblankCount <= vblankCount + 1'b1;
				end
				else begin
					vblankCount <= 6'h0;
				end
			end
		end
	end
	wire onesec = vblankCount == 59;

	// Mac SE ROM overlay switch
	reg  SEOverlay;
	always @(posedge clk32) begin
		if (!_cpuReset)
			SEOverlay <= 1;
		else if (selectSEOverlay)
			SEOverlay <= 0;
	end

	// VIA
	wire [2:0] snd_vol;
	wire snd_ena;
	wire driveSel; // internal drive select, 0 - upper, 1 - lower

	wire [7:0] via_pa_i, via_pa_o, via_pa_oe;
	wire [7:0] via_pb_i, via_pb_o, via_pb_oe;
	wire viaIrq;

	assign _viaIrq = ~viaIrq;

	// Port A - Mac LC configuration
	// Mac LC V8 returns 0xD5 for Port A reads (machine identification)
	// This is a fixed value that tells the ROM this is a Mac LC
	// 0xD5 = 1101 0101
	//   Bit 7 = 1 (SCC wait/request - directly directly directly directly directly directly directly directly directly directly overridden by sccWReq for compatibility)
	//   Bits 6-0 = 1010101 (Mac LC identification pattern)
	assign via_pa_i = 8'hD5;
	// Sound volume still comes from PA[2:0] output latch
	assign snd_vol = ~via_pa_oe[2:0] | via_pa_o[2:0];
	assign snd_alt = 1'b0;  // LC doesn't use alternate sound buffer
	assign driveSel = ~via_pa_oe[4] | via_pa_o[4];  // Drive select from VIA PA4
	assign memoryOverlayOn = SEOverlay;  // LC uses hardware overlay control
	assign SEL = ~via_pa_oe[5] | via_pa_o[5];
	assign vid_alt = ~via_pa_oe[6] | via_pa_o[6];

	// Port B - Mac LC Egret/CUDA interface (V8 protocol)
	// From MAME v8.cpp and maclc.cpp:
	// - PB3: XCVR_SESSION/TREQ from Egret/CUDA (input to VIA - 0 means CUDA has data)
	// - PB4: VIA_FULL/BYTEACK to Egret/CUDA (output from VIA)
	// - PB5: SYS_SESSION/TIP to Egret/CUDA (output from VIA)
	// - PB0: +5V sense (always 1)
	// - PB1-2, PB6-7: tied high
	//
	// TREQ polarity: cuda_treq=1 means CUDA is asserting TREQ (pin LOW = has data)
	// So we invert cuda_treq when building the external value
	wire [7:0] via_pb_external = {2'b11, 2'b11, ~cuda_treq, 3'b111};
	// Combine VIA outputs with CUDA inputs
	// Standard MUX for most bits: VIA output when OE, external when input
	wire [7:0] pb_pin_level_mux = (via_pb_oe & via_pb_o) | (~via_pb_oe & via_pb_external);
	// TREQ (bit 3) is open-drain: CUDA can always pull it low
	// Only high if VIA is not pulling low AND CUDA is not pulling low
	wire pb3_via_pulling_low = via_pb_oe[3] & ~via_pb_o[3];
	wire pb3_cuda_pulling_low = cuda_treq;  // cuda_treq=1 means CUDA pulling TREQ low
	wire pb3_open_drain = ~(pb3_via_pulling_low | pb3_cuda_pulling_low);
	wire [7:0] pb_pin_level = {pb_pin_level_mux[7:4], pb3_open_drain, pb_pin_level_mux[2:0]};
	// CUDA can override specific bits via cuda_pb_oe
	assign via_pb_i = (pb_pin_level & ~cuda_pb_oe) | (cuda_pb_o & cuda_pb_oe);
	assign snd_ena = ~via_pb_oe[7] | via_pb_o[7];

	assign viaDataOut[7:0] = 8'hEF;

	// CUDA signals for Mac LC
	wire       cuda_cb1;
	wire       cuda_cb2;
	wire       cuda_cb2_oe;
	wire       cuda_treq;
	wire       cuda_byteack;
	wire       cuda_sr_irq;
	wire       via_sr_active;
	wire       via_sr_dir;
	wire       via_sr_ext_clk;
	wire [7:0] cuda_pb_o;
	wire [7:0] cuda_pb_oe;

	// VIA Shift Register read/write strobes for CUDA
	// These pulse when CPU accesses the VIA shift register (register 0xA)
	localparam VIA_SR_REG = 4'hA;
	reg via_sr_read, via_sr_write;
	reg via_access_prev;
	always @(posedge clk32) begin
		if (!_cpuReset) begin
			via_sr_read <= 1'b0;
			via_sr_write <= 1'b0;
			via_access_prev <= 1'b0;
		end else if (clk8_en_p) begin
			// Generate single-cycle pulses on VIA SR access
			via_sr_read <= 1'b0;
			via_sr_write <= 1'b0;

			if (selectVIA && !_cpuVMA && cpuAddrRegHi == VIA_SR_REG) begin
				if (!via_access_prev) begin
					if (_cpuRW) begin
						via_sr_read <= 1'b1;
`ifdef SIMULATION
						$display("VIA: SR READ - CPU reading shift register");
`endif
					end else begin
						via_sr_write <= 1'b1;
					end
				end
				via_access_prev <= 1'b1;
			end else begin
				via_access_prev <= 1'b0;
			end
		end
	end

	// CB1 from CUDA (CUDA always drives CB1 for shift register clocking)
	wire via_cb1_in = cuda_cb1;

	// Debug: track CB2 signal for VIA shift register
`ifdef SIMULATION
	reg cuda_cb1_prev;
	always @(posedge clk32) begin
		cuda_cb1_prev <= cuda_cb1;
		// Print when CB1 rises (when VIA will shift)
		if (cuda_cb1 && !cuda_cb1_prev) begin
			$display("DC: CB1 RISE - cuda_cb2_oe=%b, cuda_cb2=%b, final_cb2_i=%b",
			         cuda_cb2_oe, cuda_cb2, (cuda_cb2_oe ? cuda_cb2 : 1'b1));
		end
	end
`endif

	// Debug: Monitor Port B and CUDA signals
	/* verilator lint_off STMTDLY */
`ifdef SIMULATION
	reg [7:0] via_pb_oe_prev = 8'h00;
	reg cuda_treq_prev = 1'b0;
	reg [7:0] treq_log_counter = 8'd0;
	always @(posedge clk32) begin
		// Log cuda_treq periodically during startup
		if (treq_log_counter < 8'd50 && clk8_en_p) begin
			treq_log_counter <= treq_log_counter + 1'd1;
			$display("CUDA DEBUG: treq=%b, treq_prev=%b, pb3_open_drain=%b, via_pb_i=0x%02x",
				cuda_treq, cuda_treq_prev, pb3_open_drain, via_pb_i);
		end
		// Log when DDRB (via_pb_oe) changes
		if (via_pb_oe !== via_pb_oe_prev) begin
			$display("VIA: DDRB changed: 0x%02x -> 0x%02x (PB3=%b=%s, PB4=%b=%s, PB5=%b=%s)",
				via_pb_oe_prev, via_pb_oe,
				via_pb_oe[3], via_pb_oe[3] ? "OUT" : "IN",
				via_pb_oe[4], via_pb_oe[4] ? "OUT" : "IN",
				via_pb_oe[5], via_pb_oe[5] ? "OUT" : "IN");
			via_pb_oe_prev <= via_pb_oe;
		end
		// Log when CUDA TREQ changes
		if (cuda_treq !== cuda_treq_prev) begin
			$display("VIA: cuda_treq changed: %b -> %b, via_pb_external=0x%02x, via_pb_i=0x%02x",
				cuda_treq_prev, cuda_treq, via_pb_external, via_pb_i);
			cuda_treq_prev <= cuda_treq;
		end
		// PortB READ logging disabled - too verbose during polling
	end
`endif
	/* verilator lint_on STMTDLY */

	via6522 via(
		.clock      (clk32),
		.rising     (E_rising),
		.falling    (E_falling),
		.reset      (!_cpuReset),

		.addr       (cpuAddrRegHi),
		.wen        (selectVIA && !_cpuVMA && !_cpuRW),
		.ren        (selectVIA && !_cpuVMA &&  _cpuRW),
		.data_in    (cpuDataIn[15:8]),
		.data_out   (viaDataOut[15:8]),

		.phi2_ref   (),

		//-- pio --
		.port_a_o   (via_pa_o),
		.port_a_t   (via_pa_oe),
		.port_a_i   (via_pa_i),

		.port_b_o   (via_pb_o),
		.port_b_t   (via_pb_oe),
		.port_b_i   (via_pb_i),  // CUDA contribution already in via_pb_i

		//-- handshake pins
		.ca1_i      (_vblank),
		.ca2_i      (onesec),

		.cb1_i      (via_cb1_in),
		.cb2_i      (cuda_cb2_oe ? cuda_cb2 : cb2_i),
		.cb2_o      (cb2_o),
		.cb2_t      (cb2_t),

		.irq        (viaIrq),

		// Shift register status for CUDA
		.sr_out_active (via_sr_active),
		.sr_out_dir    (via_sr_dir),
		.sr_ext_clk    (via_sr_ext_clk)
	);

	// Egret/CUDA controller for Mac LC - handles PRAM, RTC, and ADB
	// Mac LC uses Egret (not CUDA) with V8 chip:
	// - PB3: TREQ from Egret (input to VIA)
	// - PB4: BYTEACK from VIA (output to Egret)
	// - PB5: TIP from VIA (output to Egret)
	//
	// Define USE_EGRET_CPU to use real 68HC05 CPU + Egret ROM (341s0850)
	// Otherwise uses state machine implementation (cuda_maclc.sv)

`ifdef USE_EGRET_CPU
	egret_wrapper egret_inst(
		.clk            (clk32),
		.clk8_en        (clk8_en_p),
		.reset          (egretReset),  // Egret uses shorter reset than 68000

		// RTC timestamp initialization
		.timestamp      (timestamp),

		// VIA Port B connections (Mac LC V8 protocol)
		.via_tip        (via_pb_o[5]),     // TIP from VIA (PB5 = SYS_SESSION)
		.via_byteack_in (via_sr_active),     // BYTEACK from VIA (PB4 = VIA_FULL)
		.cuda_treq      (cuda_treq),       // TREQ to VIA (PB3 = XCVR_SESSION)
		.cuda_byteack   (cuda_byteack),    // Not used in Egret

		// VIA Shift Register interface
		.cuda_cb1       (cuda_cb1),        // Shift clock
		.via_cb2_in     (cb2_o),           // Data from VIA
		.cuda_cb2       (cuda_cb2),        // Data to VIA
		.cuda_cb2_oe    (cuda_cb2_oe),     // CB2 output enable

		// VIA SR control signals
		.via_sr_read    (via_sr_read),
		.via_sr_write   (via_sr_write),
		.via_sr_ext_clk (via_sr_ext_clk),
		.via_sr_dir     (via_sr_dir),
		.cuda_sr_irq    (cuda_sr_irq),

		// Full Port B
		.cuda_portb     (cuda_pb_o),
		.cuda_portb_oe  (cuda_pb_oe),

		// ADB (not implemented yet)
		.adb_data_in    (1'b1),
		.adb_data_out   (),

		// System control - Egret controls 68000 reset via Port C bit 3
		.reset_680x0    (egret_reset_680x0),
		.nmi_680x0      ()
	);
`else
	cuda_maclc cuda(
		.clk            (clk32),
		.clk8_en        (clk8_en_p),
		.reset          (!_cpuReset),

		// RTC timestamp initialization
		.timestamp      (timestamp),

		// VIA Port B connections (Mac LC V8 protocol)
		.via_tip        (via_pb_o[5]),     // TIP from VIA (PB5 = SYS_SESSION)
		.via_byteack_in (via_pb_o[4]),     // BYTEACK from VIA (PB4 = VIA_FULL)
		.cuda_treq      (cuda_treq),       // TREQ to VIA (PB3 = XCVR_SESSION)
		.cuda_byteack   (cuda_byteack),    // Not used in V8 protocol

		// VIA Shift Register interface
		.cuda_cb1       (cuda_cb1),        // Shift clock
		.via_cb2_in     (cb2_o),           // Data from VIA
		.cuda_cb2       (cuda_cb2),        // Data to VIA
		.cuda_cb2_oe    (cuda_cb2_oe),     // CB2 output enable

		// VIA SR control signals
		.via_sr_read    (via_sr_read),
		.via_sr_write   (via_sr_write),
		.via_sr_ext_clk (via_sr_ext_clk),
		.via_sr_dir     (via_sr_dir),
		.cuda_sr_irq    (cuda_sr_irq),

		// Full Port B
		.cuda_portb     (cuda_pb_o),
		.cuda_portb_oe  (cuda_pb_oe),

		// ADB (simplified for now)
		.adb_data_in    (1'b1),
		.adb_data_out   (),

		// System control (not used yet)
		.reset_680x0    (),
		.nmi_680x0      ()
	);
`endif

	wire _ADBint;
	wire ADBST0 = ~via_pb_oe[4] | via_pb_o[4];
	wire ADBST1 = ~via_pb_oe[5] | via_pb_o[5];
	wire ADBListen;

	reg kbdclk;
	reg [7:0] kbdclk_count;  // ADB timing only needs 8 bits
	reg kbd_transmitting, kbd_wait_receiving, kbd_receiving;
	reg [2:0] kbd_bitcnt;

	wire cb2_i = kbddata_o;
	wire cb2_o, cb2_t;
	wire kbddat_i = ~cb2_t | cb2_o;
	reg kbddata_o;
	reg  [7:0] kbd_to_mac;
	reg kbd_data_valid;

	// ADB Keyboard transmitter-receiver
	always @(posedge clk32) begin
		if (clk8_en_p) begin
			if ((kbd_transmitting && !kbd_wait_receiving) || kbd_receiving) begin
				kbdclk_count <= kbdclk_count + 1'd1;
				if (kbdclk_count == 8'd80) begin  // ADB timing
					kbdclk <= ~kbdclk;
					kbdclk_count <= 0;
					if (kbdclk) begin
						// shift before the falling edge
						if (kbd_transmitting) kbd_out_data <= { kbd_out_data[6:0], kbddat_i };
						if (kbd_receiving) kbddata_o <= kbd_to_mac[7-kbd_bitcnt];
					end
				end
			end else begin
				kbdclk_count <= 0;
				kbdclk <= 1;
			end
		end
	end

	// ADB Keyboard control (Mac LC uses ADB exclusively)
	always @(posedge clk32) begin
		reg kbdclk_d;
		reg ADBListenD;
		if (!_cpuReset) begin
			kbd_bitcnt <= 0;
			kbd_transmitting <= 0;
			kbd_wait_receiving <= 0;
			kbd_data_valid <= 0;
			ADBListenD <= 0;
		end else if (clk8_en_p) begin
			// ADB data reception
			if (adb_dout_strobe) begin
				kbd_to_mac <= adb_dout;
				kbd_receiving <= 1;
			end

			kbd_out_strobe <= 0;
			adb_din_strobe <= 0;
			kbdclk_d <= kbdclk;

			// ADB transmission start
			if (!kbd_transmitting && !kbd_receiving) begin
				ADBListenD <= ADBListen;
				if (!ADBListenD && ADBListen) begin
					kbd_transmitting <= 1;
					kbd_bitcnt <= 0;
				end
			end

			// send/receive bits at rising edge of the keyboard clock
			if (~kbdclk_d & kbdclk) begin
				kbd_bitcnt <= kbd_bitcnt + 1'd1;

				if (kbd_bitcnt == 3'd7) begin
					if (kbd_transmitting) begin
						adb_din_strobe <= 1;
						adb_din <= kbd_out_data;
						kbd_transmitting <= 0;
					end
					if (kbd_receiving) begin
						kbd_receiving <= 0;
						kbd_data_valid <= 0;
					end
				end
			end
		end
	end

	// IWM
	iwm i(
		.clk(clk32),
		.cep(clk8_en_p),
		.cen(clk8_en_n),
		._reset(_cpuReset),
		.selectIWM(selectIWM),
		._cpuRW(_cpuRW),
		._cpuLDS(_cpuLDS),
		.dataIn(cpuDataIn),
		.cpuAddrRegHi(cpuAddrRegHi),
		.SEL(SEL),
		.driveSel(driveSel),
		.dataOut(iwmDataOut),
		.insertDisk(insertDisk),
		.diskSides(diskSides),
		.diskEject(diskEject),
		.diskMotor(diskMotor),
		.diskAct(diskAct),

		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt),
		.dskReadData(memoryDataIn[7:0])
	);

	// SCC
	scc s(
		.clk(clk32),
		.cep(clk8_en_p),
		.cen(clk8_en_n),
		.reset_hw(~_cpuReset),
		.cs(selectSCC && (_cpuLDS == 1'b0 || _cpuUDS == 1'b0)),
//		.cs(selectSCC && (_cpuLDS == 1'b0 || _cpuUDS == 1'b0) && cpuBusControl),
//		.we(!_cpuRW),
		.we(!_cpuLDS),
		.rs(cpuAddrRegLo), 
		.wdata(cpuDataIn[15:8]),
		.rdata(sccDataOut),
		._irq(_sccIrq),
		.dcd_a(mouseX1),
		.dcd_b(mouseY1),
		.wreq(sccWReq),
		.txd(serialOut),
		.rxd(serialIn),
		.cts(serialCTS),
		.rts(serialRTS)
		);
				
	// Video
	videoShifter vs(
		.clk32(clk32), 
		.memoryLatch(memoryLatch),
		.dataIn(memoryDataIn),
		.loadPixels(loadPixels), 
		.pixelOut(pixelOut));
	
	// Mouse
	ps2_mouse mouse(
		.clk(clk32),
		.ce(clk8_en_p),
		.reset(~_cpuReset),
		.ps2_mouse(ps2_mouse),
		.x1(mouseX1),
		.y1(mouseY1),
		.x2(mouseX2),
		.y2(mouseY2),
		.button(mouseButton));

	wire [7:0] kbd_in_data;
	wire kbd_in_strobe;
	reg  [7:0] kbd_out_data;
	reg  kbd_out_strobe;

	// Keyboard
	ps2_kbd kbd(
		.clk(clk32),
		.ce(clk8_en_p),
		.reset(~_cpuReset),
		.ps2_key(ps2_key),
		.data_out(kbd_out_data),              // data from mac
		.strobe_out(kbd_out_strobe),
		.data_in(kbd_in_data),         // data to mac
		.strobe_in(kbd_in_strobe),
		.capslock(capslock)
		);
		
	reg  [7:0] adb_din;
	reg        adb_din_strobe;
	wire [7:0] adb_dout;
	wire       adb_dout_strobe;

	adb adb(
		.clk(clk32),
		.clk_en(clk8_en_p),
		.reset(~_cpuReset),
		.st({ADBST1, ADBST0}),
		._int(_ADBint),
		.viaBusy(kbd_transmitting || kbd_receiving),
		.listen(ADBListen),
		.adb_din(adb_din),
		.adb_din_strobe(adb_din_strobe),
		.adb_dout(adb_dout),
		.adb_dout_strobe(adb_dout_strobe),

		.ps2_mouse(ps2_mouse),
		.ps2_key(ps2_key)
	);

endmodule