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
	input [1:0] configRAMSize,

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
	output selectASC,
	output selectVIA,
	output selectRAM,
	output selectROM,
	output selectSEOverlay,

	// LC Peripherals
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
	input  v8_hblank,
	input  v8_vblank,

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
	// Use V8's blanking signals for RAM control timing
	wire videoControlActive = !v8_hblank && !v8_vblank;

	assign _romOE = ~(cpuBusControl && selectROM && _cpuRW);
	
	wire extraRamRead = sndReadAck;
	assign _ramOE = ~((videoBusControl && videoControlActive) || (extraRamRead) ||
						(cpuBusControl && (selectRAM || selectVRAM) && _cpuRW));

	// RAM Write Enable: Active for RAM or VRAM writes
	assign _ramWE = ~(cpuBusControl && (selectRAM || selectVRAM) && !_cpuRW);
	
	always @(posedge clk) begin
		if (cpuBusControl && !_cpuRW)
			$display("AC: CPU WRITE attempt selectRAM=%b selectVRAM=%b addr=%h @%0t", selectRAM, selectVRAM, cpuAddr, $time);
		if (!_ramWE && cpuBusControl)
			$display("AC: RAM WRITE addr=%h ds=%b @%0t", memoryAddr, {_memoryUDS, _memoryLDS}, $time);
	end
	
	assign _memoryUDS = cpuBusControl ? _cpuUDS : 1'b0;
	assign _memoryLDS = cpuBusControl ? _cpuLDS : 1'b0;
	
	// VRAM is at CPU address $F40000-$FBFFFF (512KB)
	// Translate to internal SDRAM address $340000-$3BFFFF
	// CPU VRAM base $F40000 has bits [19:0] = $40000, so:
	// SDRAM addr = $340000 + (cpuAddr[19:0] - $40000) = $300000 + cpuAddr[19:0]
	wire vram_cpu_access = selectVRAM;
	wire [21:0] vram_translated = vram_cpu_access ? (22'h300000 + {2'b0, cpuAddr[19:0]}) : cpuAddr[21:0];
	wire [21:0] addrMux = sndReadAck ? audioAddr : 
	                      videoBusControl ? videoAddr : 
	                      vram_translated;
	wire [21:0] macAddr;
	assign macAddr[15:0] = addrMux[15:0];

	// Note: videoBusControl is NOT included here because Mac LC has dedicated VRAM
	// at a fixed address (0x340000) that shouldn't be masked by RAM size limits.
	// The original Mac Plus had shared video RAM, but Mac LC's V8 VRAM is separate.
	wire ram_access = (cpuBusControl && selectRAM) || sndReadAck;
	wire rom_access = (cpuBusControl && selectROM);

	// Mac LC ROM is 512KB (19 bits = $80000)
	// RAM size controlled by configRAMSize (up to 10MB)
	// ROM needs 19 address bits (0-18), so only force bits 19-21 to 0 for ROM
	assign macAddr[16] = addrMux[16];
	assign macAddr[17] = ram_access && configRAMSize == 2'b00 ? 1'b0 : addrMux[17];
	assign macAddr[18] = ram_access && configRAMSize == 2'b00 ? 1'b0 : addrMux[18];
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
		.selectSEOverlay(selectSEOverlay),
		.selectAriel(selectAriel),
		.selectPseudoVIA(selectPseudoVIA),
		.selectVRAM(selectVRAM)
	);

	always @(posedge clk) begin
		if (!_cpuAS && clk8_en_p)
			$display("AC: ADDR cpuAddr=%h packed=%h selROM=%b selRAM=%b selOvr=%b @%0t", 
				cpuAddr, {cpuAddr[23:1], 1'b0}, selectROM, selectRAM, selectSEOverlay, $time);
	end

	// Video timing for Mac LC uses V8 video controller
	// The videoTimer is kept for hsync/vsync/_hblank/_vblank generation
	// but video address comes from v8_video_addr input
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

	// Mac LC uses V8 video address directly
	assign videoAddr = v8_video_addr;

endmodule