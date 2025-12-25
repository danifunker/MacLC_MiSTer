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
	// For initial CPU reset, RESET and HALT must be asserted for at least 100ms = 800,000 clocks of clk8
	reg [19:0] resetDelay; // 20 bits = 1 million
	wire isResetting = resetDelay != 0;

	initial begin
		// force a reset when the FPGA configuration is completed
		resetDelay <= 20'hFFFFF;
	end
	
	always @(posedge clk32 or negedge _systemReset) begin
		if (_systemReset == 1'b0) begin
			resetDelay <= 20'hFFFFF;
		end
		else if (clk8_en_p && isResetting) begin
			resetDelay <= resetDelay - 1'b1;
		end
	end
	assign _cpuReset = isResetting ? 1'b0 : 1'b1;
	
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

	// Port B - Mac LC CUDA interface
	// The VIA Port B is bidirectional. The "pin level" that the VIA reads is:
	// - For output pins (via_pb_oe=1): what the VIA is driving (via_pb_o)
	// - For input pins (via_pb_oe=0): external signals
	// External signals:
	// - Bit 7: vSync (tied high)
	// - Bit 6: overlay (tied high)
	// - Bit 5: TREQ from CUDA (active low)
	// - Bits 4-3: high (VIA outputs TIP/BYTEACK to CUDA)
	// - Bits 2-1: high (VIA outputs RTC CS/clock)
	// - Bit 0: RTC data (bidirectional, open-drain/wired-AND)
	wire [7:0] via_pb_external = {1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 2'b11, rtcdat_o};
	// Combine VIA outputs with external inputs based on direction
	// For most bits: output mode uses via_pb_o, input mode uses external
	// But bit 0 (RTC data) is OPEN-DRAIN: VIA can only pull low, RTC can also pull low
	// When VIA drives high (1), the RTC can still pull it low
	wire [7:0] pb_pin_level_normal = (via_pb_oe & via_pb_o) | (~via_pb_oe & via_pb_external);
	// RTC data (bit 0): wired-AND logic - both sides can pull low
	// If VIA drives 0, pin = 0. If VIA drives 1 (or is input), pin = rtcdat_o
	wire rtc_data_pin = (via_pb_oe[0] && !via_pb_o[0]) ? 1'b0 : rtcdat_o;
	wire [7:0] pb_pin_level = {pb_pin_level_normal[7:1], rtc_data_pin};
	// CUDA drives TREQ on bit 5 (overrides everything else for that bit)
	assign via_pb_i = (pb_pin_level & ~cuda_pb_oe) | (cuda_pb_o & cuda_pb_oe);
	assign snd_ena = ~via_pb_oe[7] | via_pb_o[7];

	assign viaDataOut[7:0] = 8'hEF;

	// CUDA signals for Mac LC
	wire       cuda_cb1;
	wire       cuda_cb1_oe;
	wire       cuda_cb2;
	wire       cuda_cb2_oe;
	wire       via_sr_active;
	wire       via_sr_dir;
	wire       via_sr_ext_clk;
	wire [7:0] cuda_pb_o;
	wire [7:0] cuda_pb_oe;

	// Combine CB1 from CUDA (when driving) or use internal clock
	wire via_cb1_in = cuda_cb1_oe ? cuda_cb1 : kbdclk;

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

	// CUDA stub for Mac LC ADB/power management
	cuda_stub cuda(
		.clk            (clk32),
		.clk8_en        (clk8_en_p),
		.reset          (!_cpuReset),

		.via_pb_i       (via_pb_o),        // Read VIA Port B outputs
		.cuda_pb_o      (cuda_pb_o),       // CUDA's Port B contributions
		.cuda_pb_oe     (cuda_pb_oe),

		.via_sr_active  (via_sr_active),
		.via_sr_out     (via_sr_dir),
		.cuda_sr_trigger(), // Not used yet - VIA handles its own interrupt

		.cuda_cb1       (cuda_cb1),
		.cuda_cb1_oe    (cuda_cb1_oe),
		.cuda_cb2       (cuda_cb2),
		.cuda_cb2_oe    (cuda_cb2_oe)
	);

	wire _rtccs   = ~via_pb_oe[2] | via_pb_o[2];
	wire rtcck    = ~via_pb_oe[1] | via_pb_o[1];
	wire rtcdat_i = ~via_pb_oe[0] | via_pb_o[0];
	wire rtcdat_o;

	rtc pram (
		.clk        (clk32),
		.reset      (!_cpuReset),
		.timestamp  (timestamp),
		._cs        (_rtccs),
		.ck         (rtcck),
		.dat_i      (rtcdat_i),
		.dat_o      (rtcdat_o)
	);

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