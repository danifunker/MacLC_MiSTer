/* 
	($000000 - $03FFFF) RAM  4MB, or Overlay ROM 4MB
	
	($400000 - $4FFFFF) ROM 1MB
		64K Mac 128K/512K ROM is $400000 - $40FFFF
		128K Mac 512Ke/Plus ROM is $400000 - $41FFFF
		If ROM is mirrored when A17 is 1, then SCSI is assumed to be unavailable
	
	($580000 - $580FFF) SCSI (Mac Plus only, not implemented here)
	
	($600000 - $7FFFFF) Overlay RAM 2MB
	
	($9FFFF8 - $BFFFFF) SCC
		The SCC is on the upper byte of the data bus, so you must use only even-addressed byte reads.
		When writing, you must use only odd-addressed byte writes (the MC68000 puts your data on both bytes of the bus, so it works correctly). 
		A byte read of an odd SCC read address tries to reset the entire SCC. 
		A word access to any SCC address will shift the phase of the computer's high-frequency timing by 128 ns.

		($9FFFF8) SCC read channel B control
		($9FFFFA) SCC read channel A control
		($9FFFFC) SCC read channel B data in/out
		($9FFFFE) SCC read channel A data in/out
		
		($BFFFF9) SCC write channel B control
		($BFFFFB) SCC write channel A control
		($BFFFFD) SCC write channel B data in/out
		($BFFFFF) SCC write channel A data in/out

	($DFE1FF - $DFFFFF) IWM
		The IWM is on the lower byte of the data bus, so use odd-addressed byte accesses only. 
		The 16 IWM registers are {8'hDF, 8'b111xxxx1, 8'hFF}:
			0	$0		ph0L		CA0 off (0)
			1	$200	ph0H		CA0 on (1)
			2	$400	ph1L		CA1 off (0)
			3	$600	ph1H		CA1 on (1)
			4	$800	h2L		CA2 off (0)
			5	$A00	ph2H		CA2 on (1)
			6	$C00	ph3L		LSTRB off (low)
			7	$E00	ph3H		LSTRB on (high)
			8	$1000	mtrOff	disk enable off
			9	$1200	mtrOn		disk enable on
			10	$1400	intDrive	select internal drive
			11	$1600	extDrive	select external drive
			12	$1800	q6L		Q6 off
			13	$1A00	q6H		Q6 on
			14	$1C00	q7L		Q7 off, read register
			15	$1E00	q7H		Q7 on, write register
		
	($EFE1FE - $EFFFFE) VIA 
		The VIA is on the upper byte of the data bus, so use even-addressed byte accesses only.
		The 16 VIA registers are {8'hEF, 8'b111xxxx1, 8'hFE}:
			0	$0		vBufB		register B
			1	$200	?????		not used?
			2	$400	vDirB		register B direction register
			3	$600	vDirA		register A direction register
			4	$800	vT1C		timer 1 counter (low-order byte)
			5	$A00	vT1CH		timer 1 counter (high-order byte)
			6	$C00	vT1L		timer 1 latch (low-order byte)
			7	$E00	vT1LH		timer 1 latch (high-order byte)
			8	$1000	vT2C		timer 2 counter (low-order byte)
			9	$1200	vT2CH		timer 2 counter (high-order byte)
			10	$1400	vSR		shift register (keyboard)
			11	$1600	vACR		auxiliary control register
			12	$1800	vPCR		peripheral control register
			13	$1A00	vIFR		interrupt flag register
			14	$1C00	vIER		interrupt enable register
			15	$1E00	vBufA		register A

	($F00000 - $F00005) memory phase read test

	($F80000 - $FFFFEF) space for test software
	
	($FFFFF0 - $FFFFFF) interrupt vectors
	
	Note: This can all be decoded using only the highest 4 address bits, if SCSI, phase read test, and test software are not used.
	7 other address bits are used by peripherals to determine which register to access:
		A12-A9 - IWM and VIA
		A2-A0 - SCC
	
*/

module addrDecoder(
	input [1:0] configROMSize,
	input [23:0] address,
	input _cpuAS,
	input memoryOverlayOn,
	input machineType, // 0 = Mac Plus, 1 = Mac LC
	
	output reg selectRAM,
	output reg selectROM,
	output reg selectSCSI,
	output reg selectSCC,
	output reg selectIWM,
	output reg selectVIA,
	output reg selectSEOverlay,
	
	// Mac LC Specific Selects
	output reg selectAriel,
	output reg selectPseudoVIA,
	output reg selectVRAM
);

	always @(*) begin
		// Defaults
		selectRAM = 0;
		selectROM = 0;
		selectSCSI = 0;
		selectSCC = 0;
		selectIWM = 0;
		selectVIA = 0;
		selectSEOverlay = 0;
		selectAriel = 0;
		selectPseudoVIA = 0;
		selectVRAM = 0;
		
		if (!_cpuAS) begin
			if (machineType == 0) begin
				// ==========================================================
				// Mac Plus Memory Map (Legacy)
				// ==========================================================
				casez (address[23:20])
					4'b00??: begin // 00 0000 - 3F FFFF (RAM / Overlay ROM)
						if (memoryOverlayOn == 0)
							selectRAM = 1;
						else begin
							if (address[23:20] == 0) begin
								// Mac Plus: repeated images of overlay ROM only extend to $0F0000
								selectROM = 1;
							end
						end
					end
					4'b0100: begin // 40 0000 - 4F FFFF (ROM)
						if(configROMSize[1] || address[17] == 1'b0)
							selectROM = 1;
						selectSEOverlay = 1;
					end
					4'b0101: begin // 50 0000 - 5F FFFF (SCSI @ 580000)
						if (address[19]) 
							selectSCSI = 1;
						selectSEOverlay = 1;
					end
					4'b0110: // 60 0000 - 6F FFFF (Overlay RAM)
						if (memoryOverlayOn)
							selectRAM = 1;
					4'b10?1: // 9? ?? ?? (SCC)
						selectSCC = 1;
					4'b1100: // C0 0000 (IWM)
						if (!configROMSize[1])
							selectIWM = 1;
					4'b1101: // D0 0000 (IWM)
						selectIWM = 1;
					4'b1110: // E0 0000 (VIA)
						if (address[19]) // E8 0000 - EF FFFF
							selectVIA = 1;
					default: ;
				endcase
			end else begin
				// ==========================================================
				// Mac LC (V8) Memory Map
				// ==========================================================
				
				// --- ROM (0xA00000 - 0xAFFFFF) ---
				if (address >= 24'hA00000 && address <= 24'hAFFFFF) begin
					selectROM = 1;
				end
				// --- Overlay ROM (0x000000) ---
				// Mirrors ROM to 0x0 at boot
				else if (memoryOverlayOn && address < 24'hA00000) begin
					selectROM = 1; 
				end
				// --- RAM (0x000000 - 0x9FFFFF) ---
				// Covers all lower memory except IO holes
				else if (address < 24'hA00000) begin
					// Check for V8 IO Holes
					if (address >= 24'h500000 && address <= 24'h5BFFFF) begin
						// 50 0000: VIA1
						if (address >= 24'h500000 && address <= 24'h501FFF) selectVIA = 1;
						// 51 4000: ASC (Audio) - usually handled by dataController, but map it?
						// 52 4000: Ariel (RAMDAC)
						else if (address >= 24'h524000 && address <= 24'h525FFF) selectAriel = 1;
						// 52 6000: PseudoVIA
						else if (address >= 24'h526000 && address <= 24'h527FFF) selectPseudoVIA = 1;
						// 54 0000: VRAM
						else if (address >= 24'h540000 && address <= 24'h5BFFFF) selectVRAM = 1;
					end else begin
						// Regular RAM
						selectRAM = 1;
					end
				end
				// --- Upper IO (0xF00000+) ---
				else if (address >= 24'hF00000) begin
					// F0 4000: SCC
					if (address >= 24'hF04000 && address <= 24'hF05FFF) selectSCC = 1;
					// F0 6000: SCSI DRQ
					else if (address >= 24'hF06000 && address <= 24'hF07FFF) selectSCSI = 1;
					// F1 0000: SCSI
					else if (address >= 24'hF10000 && address <= 24'hF11FFF) selectSCSI = 1;
					// F1 2000: SCSI DRQ
					else if (address >= 24'hF12000 && address <= 24'hF13FFF) selectSCSI = 1;
					// F1 6000: SWIM (IWM)
					else if (address >= 24'hF16000 && address <= 24'hF17FFF) selectIWM = 1;
				end
			end
		end
	end
endmodule
