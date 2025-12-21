module addrController_top(
	// clocks:
	input clk,
	output clk8,
	output clk8_en_p,
	output clk8_en_n,
	output clk16_en_p,
	output clk16_en_n,

	// system config:
	input turbo,
	input [1:0] configROMSize,
	input [1:0] configRAMSize,
	input machineType,

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
	
	// New LC Peripherals
	output selectAriel,
	output selectPseudoVIA,
	output selectVRAM,
	
	// video:
	output hsync,
	output vsync,
	output _hblank,
	output _vblank,
	output loadPixels,
	input  vid_alt,
	input  [21:0] v8_video_addr,
		
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

	assign loadSound = sndReadAck;

	localparam SIZE = 20'd135408;
	localparam STEP = 20'd5920;
	
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

	wire [21:0] videoAddr;
	wire videoControlActive = _hblank;

	assign _romOE = ~(cpuBusControl && selectROM && _cpuRW);
	
	wire extraRamRead = sndReadAck;
	assign _ramOE = ~((videoBusControl && videoControlActive) || (extraRamRead) ||
						(cpuBusControl && (selectRAM || selectVRAM) && _cpuRW));

	// RAM Write Enable: Active for RAM or VRAM writes
	assign _ramWE = ~(cpuBusControl && (selectRAM || selectVRAM) && !_cpuRW);
	
	assign _memoryUDS = cpuBusControl ? _cpuUDS : 1'b0;
	assign _memoryLDS = cpuBusControl ? _cpuLDS : 1'b0;
	
	wire vram_cpu_access = machineType && (cpuAddr[23:18] == 6'b010101);
	wire [21:0] vram_translated = vram_cpu_access ? (22'h340000 + cpuAddr[17:0]) : cpuAddr[21:0];
	wire [21:0] addrMux = sndReadAck ? audioAddr : 
	                      videoBusControl ? videoAddr : 
	                      vram_translated;
	wire [21:0] macAddr;
	assign macAddr[15:0] = addrMux[15:0];

	wire ram_access = (cpuBusControl && selectRAM) || videoBusControl || sndReadAck;
	wire rom_access = (cpuBusControl && selectROM);
	
	assign macAddr[16] = rom_access && configROMSize == 2'b00 ? 1'b0 : addrMux[16]; 
	assign macAddr[17] = ram_access && configRAMSize == 2'b00 ? 1'b0 :
	                     rom_access && configROMSize == 2'b01 ? 1'b0 :
	                     rom_access && configROMSize == 2'b00 ? 1'b1 : addrMux[17]; 
	assign macAddr[18] = ram_access && configRAMSize == 2'b00 ? 1'b0 :
	                     rom_access && configROMSize != 2'b11 ? 1'b0 : addrMux[18]; 
	assign macAddr[19] = ram_access && configRAMSize[1] == 1'b0 ? 1'b0 :
	                     rom_access ? 1'b0 : addrMux[19]; 
	assign macAddr[20] = ram_access && configRAMSize != 2'b11 ? 1'b0 :
	                     rom_access ? 1'b0 : addrMux[20]; 
	assign macAddr[21] = ram_access && configRAMSize != 2'b11 ? 1'b0 :
	                     rom_access ? 1'b0 : addrMux[21]; 
	
	assign dskReadAckInt = (extraBusControl == 1'b1) && (extra_slot_count == 0);
	assign dskReadAckExt = (extraBusControl == 1'b1) && (extra_slot_count == 1);
	wire sndReadAck    = (extraBusControl == 1'b1) && (extra_slot_count == 2);

	assign memoryAddr = 
		dskReadAckInt ? dskReadAddrInt + 22'h100000:
		dskReadAckExt ? dskReadAddrExt + 22'h200000:
		macAddr;

	addrDecoder ad(
		.configROMSize(configROMSize),
		.address(cpuAddr),
		._cpuAS(_cpuAS),
		.memoryOverlayOn(memoryOverlayOn),
		.machineType(machineType), // Added machineType
		.selectRAM(selectRAM),
		.selectROM(selectROM),
		.selectSCSI(selectSCSI),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectVIA(selectVIA),
		.selectSEOverlay(selectSEOverlay),
		// New Outputs
		.selectAriel(selectAriel),
		.selectPseudoVIA(selectPseudoVIA),
		.selectVRAM(selectVRAM)
	);

	wire [21:0] plus_video_addr;

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

	assign videoAddr = machineType ? v8_video_addr : plus_video_addr;
		
endmodule