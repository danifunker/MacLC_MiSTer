module addrController_top(
	// clocks:
	input clk,
	input clk_vid_lc, // New 25.175MHz clock
	output clk8,						// 8.125 MHz CPU clock
	output clk8_en_p,
	output clk8_en_n,
	output clk16_en_p,
	output clk16_en_n,

	// system config:
	input turbo,               // 0 = normal, 1 = faster
	input [1:0] configROMSize,  // 0 = 64K ROM, 1 = 128K ROM, 2 = 256K ROM
	input [1:0] configRAMSize,	// 0 = 128K, 1 = 512K, 2 = 1MB, 3 = 4MB RAM

	// 68000 CPU memory interface:
	input [23:0] cpuAddr,
	input _cpuUDS,
	input _cpuLDS,
	input _cpuRW,
	input _cpuAS,

	// RAM/ROM:
	output [21:0] memoryAddr,
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
	output selectVIA,
	output selectRAM,
	output selectROM,
	output selectSEOverlay,
	output selectVideoROM,
	output selectPseudoVIA,
	output selectCLUT,
	output selectVRAM,

	// video:
	output hsync,
	output vsync,
	output _hblank,
	output _vblank,
	output loadPixels,
	input  vid_alt,

	input  snd_alt,
	output loadSound,

	// misc
	input memoryOverlayOn,

	// interface to read dsk image from ram
	input [21:0] dskReadAddrInt,
	output dskReadAckInt,
	input [21:0] dskReadAddrExt,
	output dskReadAckExt
);

	// -------------- audio engine (may be moved into seperate module) ---------------
	assign loadSound = sndReadAck;

	localparam SIZE = 20'd135408;  // 168*806 clk8 events per frame
	localparam STEP = 20'd5920;    // one step every 16*370 clk8 events

	reg [21:0] audioAddr;
	reg [19:0] snd_div;

	reg sndReadAckD;
	always @(posedge clk)
		if (clk8_en_n) sndReadAckD <= sndReadAck;

	reg vblankD, vblankD2;
	always @(posedge clk) begin
		if(clk8_en_p && sndReadAckD) begin
			vblankD <= _vblank;
			vblankD2 <= vblankD;

			// falling adge of _vblank = begin of vblank phase
			if(vblankD2 && !vblankD) begin
				audioAddr <= snd_alt?22'h3FA100:22'h3FFD00;
				snd_div <= 20'd0;
			end else begin
				if(snd_div >= SIZE-1) begin
					snd_div <= snd_div - SIZE + STEP;
					audioAddr <= audioAddr + 22'd2;
				end else
					snd_div <= snd_div + STEP;
			end
		end
	end

	assign dioBusControl = extraBusControl;

	// interleaved RAM access for CPU and video
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

	// allocate memory slots in the extra cycle
	always @(posedge clk) begin
		if(clk8_en_p && extra_slot_advance) begin
			extra_slot_count <= extra_slot_count + 2'd1;
		end
	end

	// video controls memory bus during the first clock of the four-clock cycle
	assign videoBusControl = (busCycle == 2'b00);
	// cpu controls memory bus during the second and fourth clock of the four-clock cycle
	assign cpuBusControl = (busCycle == 2'b01) || (busCycle == 2'b11);
	// IWM/audio gets 3rd cycle
	wire extraBusControl = (busCycle == 2'b10);

	// interconnects
	wire [21:0] videoAddr;
	wire [21:0] videoAddrLegacy;
	wire [21:0] videoAddrLC;

	// Mac LC Detection
	// configROMSize: 0=64K, 1=128K, 2=256K.
	// In MacLC.sv, status_mod=1 maps to configROMSize=2 (2'b10).
	wire isLC = configROMSize[1];

	// RAM/ROM control signals
	wire videoControlActive = _hblank; // For Legacy. LC uses its own blanking/control logic inside videoTimerLC?

	assign _romOE = ~(cpuBusControl && (selectROM || selectVideoROM) && _cpuRW);

	wire extraRamRead = sndReadAck;

	// Legacy RAM OE logic
	// For LC, if videoBusControl is active, we read RAM.
	// videoControlActive (_hblank) is for legacy blanking.
	// We need to ensure we read RAM for LC video even if _hblank (legacy) logic says otherwise?
	// But `_hblank` comes from `videoTimer` output.
	// We muxed `_hblank` at the end.
	// So `videoControlActive` uses the active `_hblank`.

	assign _ramOE = ~((videoBusControl && videoControlActive) || (extraRamRead) ||
						(cpuBusControl && selectRAM && _cpuRW));
	assign _ramWE = ~(cpuBusControl && selectRAM && !_cpuRW);

	assign _memoryUDS = cpuBusControl ? _cpuUDS : 1'b0;
	assign _memoryLDS = cpuBusControl ? _cpuLDS : 1'b0;

	assign videoAddr = isLC ? videoAddrLC : videoAddrLegacy;

	wire [21:0] addrMux = sndReadAck ? audioAddr : videoBusControl ? videoAddr : cpuAddr[21:0];
	wire [21:0] macAddr;
	assign macAddr[15:0] = addrMux[15:0];

	// video and sound always addresses ram
	wire ram_access = (cpuBusControl && selectRAM) || videoBusControl || sndReadAck;
	wire rom_access = (cpuBusControl && selectROM);

	// simulate smaller RAM/ROM sizes
	assign macAddr[16] = rom_access && configROMSize == 2'b00 ? 1'b0 :     // force A16 to 0 for 64K ROM access
									addrMux[16];
	assign macAddr[17] = ram_access && configRAMSize == 2'b00 ? 1'b0 :   // force A17 to 0 for 128K RAM access
									rom_access && configROMSize == 2'b01 ? 1'b0 :  // force A17 to 0 for 128K ROM access
									rom_access && configROMSize == 2'b00 ? 1'b1 :  // force A17 to 1 for 64K ROM access (64K ROM image is at $20000)
									addrMux[17];
	assign macAddr[18] = ram_access && configRAMSize == 2'b00 ? 1'b0 :   // force A18 to 0 for 128K RAM access
	                     rom_access && configROMSize != 2'b11 ? 1'b0 : // force A18 to 0 for 64K/128K/256K ROM access
									addrMux[18];
	assign macAddr[19] = ram_access && configRAMSize[1] == 1'b0 ? 1'b0 : // force A19 to 0 for 128K or 512K RAM access
									rom_access ? 1'b0 : 								   // force A19 to 0 for ROM access
									addrMux[19];
	assign macAddr[20] = ram_access && configRAMSize != 2'b11 ? 1'b0 :   // force A20 to 0 for all but 4MB RAM access
									rom_access ? 1'b0 : 								   // force A20 to 0 for ROM access
									addrMux[20];
	assign macAddr[21] = ram_access && configRAMSize != 2'b11 ? 1'b0 :   // force A21 to 0 for all but 4MB RAM access
									rom_access ? 1'b0 : 								   // force A21 to 0 for ROM access
									addrMux[21];


	// floppy emulation gets extra slots 0 and 1
	assign dskReadAckInt = (extraBusControl == 1'b1) && (extra_slot_count == 0);
	assign dskReadAckExt = (extraBusControl == 1'b1) && (extra_slot_count == 1);
	// audio gets extra slot 2
	wire sndReadAck    = (extraBusControl == 1'b1) && (extra_slot_count == 2);

	assign memoryAddr =
		dskReadAckInt ? dskReadAddrInt + 22'h200000:   // first dsk image at 2MB (0x100000 words offset)
		dskReadAckExt ? dskReadAddrExt + 22'h300000:   // second dsk image at 3MB (0x180000 words offset)
		macAddr;

	// address decoding
	addrDecoder ad(
		.configROMSize(configROMSize),
		.address(cpuAddr),
		._cpuAS(_cpuAS),
		.memoryOverlayOn(memoryOverlayOn),
		.selectRAM(selectRAM),
		.selectROM(selectROM),
		.selectSCSI(selectSCSI),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectVIA(selectVIA),
		.selectSEOverlay(selectSEOverlay),
		.selectVideoROM(selectVideoROM),
		.selectPseudoVIA(selectPseudoVIA),
		.selectCLUT(selectCLUT),
		.selectVRAM(selectVRAM)
	);

	wire hsync_legacy, vsync_legacy, hblank_legacy, vblank_legacy, loadPixels_legacy;
	wire hsync_lc, vsync_lc, hblank_lc, vblank_lc, loadPixels_lc;

	// video
	videoTimer vt(
		.clk(clk),
		.clk_en(clk8_en_p),
		.busCycle(busCycle),
		.vid_alt(vid_alt),
		.videoAddr(videoAddrLegacy),
		.hsync(hsync_legacy),
		.vsync(vsync_legacy),
		._hblank(hblank_legacy),
		._vblank(vblank_legacy),
		.loadPixels(loadPixels_legacy));

	videoTimerLC vt_lc(
		.clk(clk_vid_lc),
		.clk_sys(clk),
		.busCycle(busCycle),
		.videoBusControl(videoBusControl),
		.videoAddr(videoAddrLC),
		.hsync(hsync_lc),
		.vsync(vsync_lc),
		._hblank(hblank_lc),
		._vblank(vblank_lc),
		.loadPixels(loadPixels_lc)
	);

	// Mux Video Signals
	assign hsync = isLC ? hsync_lc : hsync_legacy;
	assign vsync = isLC ? vsync_lc : vsync_legacy;
	assign _hblank = isLC ? hblank_lc : hblank_legacy;
	assign _vblank = isLC ? vblank_lc : vblank_legacy;
	assign loadPixels = isLC ? loadPixels_lc : loadPixels_legacy;

endmodule
