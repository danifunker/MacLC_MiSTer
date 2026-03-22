module addrController_top(
	// clocks:
	input clk,
	output clk8,
	output clk8_en_p,
	output clk8_en_n,
	output clk16_en_p,
	output clk16_en_n,

	// system config:
	input [7:0] ram_config,  // V8 RAM config byte from pseudovia

	// 68000 CPU memory interface:
	input _cpuReset,
	input [23:0] cpuAddr,
	input _cpuUDS,
	input _cpuLDS,
	input _cpuRW,
	input _cpuAS,

	// RAM/ROM:
	output [22:0] memoryAddr,  // 23-bit SDRAM word address
	output _memoryUDS,
	output _memoryLDS,
	output _romOE,
	output _ramOE,
	output _ramWE,
	output videoBusControl,
	output dioBusControl,
	output cpuBusControl,
	output memoryLatch,

	// peripherals:
	output selectSCSI,
	output selectSCC,
	output selectIWM,
	output selectASC,
	output selectVIA,
	output selectRAM,
	output selectROM,

	// LC Peripherals
	output selectAriel,
	output selectPseudoVIA,
	output selectVRAM,
	output selectUnmapped,

	// video:
	output hsync,
	output vsync,
	output _hblank,
	output _vblank,
	output loadPixels,
	input  vid_alt,
	input  [21:0] v8_video_addr,
	input  v8_hblank,
	input  v8_vblank,

	input  snd_alt,
	output loadSound,

	// misc
	output memoryOverlayOn,

	// interface to read dsk image from ram
	input [21:0] dskReadAddrInt,
	output dskReadAckInt,
	input [21:0] dskReadAddrExt,
	output dskReadAckExt
);

	assign loadSound = sndReadAck;

	// ============================================================
	// Audio address generation (legacy Mac Plus style)
	// ============================================================
	localparam SIZE = 20'd135408;
	localparam STEP = 20'd5920;

	reg [22:0] audioAddr;
	reg [19:0] snd_div;

	reg sndReadAckD;
	always @(posedge clk)
		if (clk8_en_n) sndReadAckD <= sndReadAck;

	reg vblankD, vblankD2;
	always @(posedge clk) begin
		if(clk8_en_p && sndReadAckD) begin
			vblankD <= _vblank;
			vblankD2 <= vblankD;

			if(vblankD2 && !vblankD) begin
				// Sound buffer in motherboard RAM (SDRAM word $000000-$0FFFFF)
				audioAddr <= snd_alt ? 23'h07D080 : 23'h07FE80;
				snd_div <= 20'd0;
			end else begin
				if(snd_div >= SIZE-1) begin
					snd_div <= snd_div - SIZE + STEP;
					audioAddr <= audioAddr + 23'd1;
				end else
					snd_div <= snd_div + STEP;
			end
		end
	end

	// ============================================================
	// Bus cycle / clock generation
	// ============================================================
	assign dioBusControl = extraBusControl;

	reg [1:0] busCycle;
	reg [1:0] busPhase;
	reg [1:0] extra_slot_count;

	always @(posedge clk) begin
		busPhase <= busPhase + 1'd1;
		if (busPhase == 2'b11)
			busCycle <= busCycle + 2'd1;
	end
	assign memoryLatch = busPhase == 2'd3;
	assign clk8 = !busPhase[1];
	assign clk8_en_p = busPhase == 2'b11;
	assign clk8_en_n = busPhase == 2'b01;
	assign clk16_en_p = !busPhase[0];
	assign clk16_en_n = busPhase[0];

	reg extra_slot_advance;
	always @(posedge clk)
		if (clk8_en_n) extra_slot_advance <= (busCycle == 2'b11);

	always @(posedge clk) begin
		if(clk8_en_p && extra_slot_advance) begin
			extra_slot_count <= extra_slot_count + 2'd1;
		end
	end

	assign videoBusControl = (busCycle == 2'b00);
	assign cpuBusControl = (busCycle == 2'b01) || (busCycle == 2'b11);
	wire extraBusControl = (busCycle == 2'b10);

	// ============================================================
	// Memory control signals
	// ============================================================
	// Use V8's blanking signals for RAM control timing
	wire videoControlActive = !v8_hblank && !v8_vblank;

	assign _romOE = ~(cpuBusControl && selectROM && _cpuRW);

	wire extraRamRead = sndReadAck;
	assign _ramOE = ~((videoBusControl && videoControlActive) || (extraRamRead) ||
						(cpuBusControl && (selectRAM || selectVRAM) && _cpuRW));

	// RAM Write Enable: Active for RAM or VRAM writes
	assign _ramWE = ~(cpuBusControl && (selectRAM || selectVRAM) && !_cpuRW);

	assign _memoryUDS = cpuBusControl ? _cpuUDS : 1'b0;
	assign _memoryLDS = cpuBusControl ? _cpuLDS : 1'b0;

	// ============================================================
	// V8-style RAM address translation
	// All outputs are 23-bit SDRAM word addresses
	//
	// SDRAM Layout (word addresses):
	//   $000000-$0FFFFF  Motherboard RAM (2MB)
	//   $100000-$4FFFFF  SIMM RAM (up to 8MB)
	//   $500000-$53FFFF  ROM (512KB)
	//   $580000-$5BFFFF  VRAM (512KB)
	//   $600000-$6FFFFF  Floppy disk image 1 (2MB)
	//   $700000-$7FFFFF  Floppy disk image 2 (2MB)
	// ============================================================

	// Decode SIMM size from ram_config[7:6] (byte size)
	wire [22:0] simm_byte_size = (ram_config[7:6] == 2'b00) ? 23'h000000 :  // 0MB
	                              (ram_config[7:6] == 2'b01) ? 23'h200000 :  // 2MB
	                              (ram_config[7:6] == 2'b10) ? 23'h400000 :  // 4MB
	                                                           23'h800000;   // 8MB
	wire [21:0] simm_word_size = simm_byte_size[22:1];

	// CPU address classification for RAM
	wire motherboard_high = (cpuAddr[23:21] == 3'b100);  // $800000-$9FFFFF
	wire in_simm = (cpuAddr[22:0] < simm_byte_size);     // Below SIMM size

	// CPU byte addr -> word addr
	wire [21:0] cpu_word = cpuAddr[22:1];

	// Motherboard mirror offset: (cpu_word - simm_words) mod 2MB
	wire [21:0] mb_mirror_offset_raw = cpu_word - simm_word_size;
	wire [19:0] mb_mirror_offset = mb_mirror_offset_raw[19:0];  // Wrap to 2MB (1M words)

	// V8 RAM translation to SDRAM word address
	wire [22:0] ram_sdram_word =
		motherboard_high ? {3'b000, cpuAddr[20:1]} :                          // → Motherboard at SDRAM $000000
		in_simm          ? (23'h100000 + {1'b0, cpu_word}) :                  // → SIMM at SDRAM $100000+
		                   {3'b000, mb_mirror_offset};                        // → Motherboard mirror at SDRAM $000000+

	// ROM translation: SDRAM word $500000 + offset within 512KB
	wire [22:0] rom_sdram_word = {5'b01010, cpuAddr[18:1]};  // $500000 + offset

	// VRAM CPU access: CPU $F40000-$FBFFFF → SDRAM word $580000+
	// Offset from VRAM start = cpuAddr[19:0] - $40000
	wire [19:0] vram_cpu_offset = cpuAddr[19:0] - 20'h40000;
	wire [22:0] vram_sdram_word = 23'h580000 + {5'b0, vram_cpu_offset[18:1]};

	// Video fetch: v8_video_addr is byte offset from VRAM start → SDRAM word $580000+
	wire [22:0] vid_sdram_word = 23'h580000 + {2'b0, v8_video_addr[21:1]};

	// Floppy disk addresses: byte offset → SDRAM word
	wire [22:0] dsk_int_sdram_word = 23'h600000 + {2'b0, dskReadAddrInt[21:1]};
	wire [22:0] dsk_ext_sdram_word = 23'h700000 + {2'b0, dskReadAddrExt[21:1]};

	// CPU address mux (selects based on address decode)
	wire [22:0] cpu_sdram_word = selectVRAM ? vram_sdram_word :
	                              selectROM ? rom_sdram_word :
	                              selectRAM ? ram_sdram_word :
	                              23'h0;

	// Main address mux: priority among bus cycle types
	wire [22:0] addr_mux = sndReadAck      ? audioAddr :
	                        videoBusControl ? vid_sdram_word :
	                        cpu_sdram_word;

	// ============================================================
	// Extra bus slots (disk reads, sound)
	// ============================================================
	assign dskReadAckInt = (extraBusControl == 1'b1) && (extra_slot_count == 0);
	assign dskReadAckExt = (extraBusControl == 1'b1) && (extra_slot_count == 1);
	wire sndReadAck    = (extraBusControl == 1'b1) && (extra_slot_count == 2);

	// Final SDRAM word address output
	assign memoryAddr =
		dskReadAckInt ? dsk_int_sdram_word :
		dskReadAckExt ? dsk_ext_sdram_word :
		addr_mux;

	// ============================================================
	// Address decoder
	// ============================================================
	addrDecoder ad(
		.address({cpuAddr[23:1], 1'b0}),
		._cpuAS(_cpuAS),
		._cpuRW(_cpuRW),
		.memoryOverlayOn(memoryOverlayOn),
		.selectRAM(selectRAM),
		.selectROM(selectROM),
		.selectSCSI(selectSCSI),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectASC(selectASC),
		.selectVIA(selectVIA),
		.selectAriel(selectAriel),
		.selectPseudoVIA(selectPseudoVIA),
		.selectVRAM(selectVRAM),
		.selectUnmapped(selectUnmapped)
	);

	// ============================================================
	// ROM Overlay Register
	// ============================================================
	// At reset, ROM is overlaid at $000000 so the CPU reads the reset
	// vector from ROM.  The overlay is disabled when the CPU first
	// accesses the ROM area ($A0xxxx).
	//
	// The disable is deferred until _cpuAS goes high (bus cycle ends),
	// so the instruction/data read that triggered it completes with
	// overlay still active.  The next bus cycle sees overlay OFF.
	// ============================================================
	reg rom_overlay = 1;
	reg overlay_disable_pending = 0;

	assign memoryOverlayOn = rom_overlay;

	wire overlay_trigger = !_cpuAS && (cpuAddr[23:20] == 4'hA);

	always @(posedge clk) begin
		if (!_cpuReset) begin
			rom_overlay <= 1'b1;
			overlay_disable_pending <= 1'b0;
		end else begin
			if (overlay_trigger && rom_overlay)
				overlay_disable_pending <= 1'b1;

			if (overlay_disable_pending && _cpuAS) begin
				rom_overlay <= 1'b0;
				overlay_disable_pending <= 1'b0;
			end
		end
	end

	// ============================================================
	// Video timing (Mac Plus legacy - generates hsync/vsync/_hblank/_vblank)
	// ============================================================
	wire [21:0] plus_video_addr;  // Not used, but videoTimer generates timing signals

	videoTimer vt(
		.clk(clk),
		.clk_en(clk8_en_p),
		.busCycle(busCycle),
		.vid_alt(vid_alt),
		.videoAddr(plus_video_addr),
		.hsync(hsync),
		.vsync(vsync),
		._hblank(_hblank),
		._vblank(_vblank),
		.loadPixels(loadPixels));

endmodule
