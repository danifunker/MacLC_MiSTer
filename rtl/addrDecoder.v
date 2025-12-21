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
	input [1:0] machineType, // 0 = Plus, 1 = SE, 2 = LC
	input [23:0] address,
	input _cpuAS,
	input memoryOverlayOn,
	output reg selectRAM,
	output reg selectROM,
	output reg selectSCSI,
	output reg selectSCC,
	output reg selectIWM,
	output reg selectVIA,
	output reg selectPseudoVIA,
	output reg selectCLUT,
	output reg selectSEOverlay,
	output reg selectVRAM
);

	always @(*) begin
		selectRAM = 0;
		selectROM = 0;
		selectSCSI = 0;
		selectSCC = 0;
		selectIWM = 0;
		selectVIA = 0;
		selectPseudoVIA = 0;
		selectCLUT = 0;
		selectSEOverlay = 0;
		selectVRAM = 0;

		if (machineType == 2) begin // Mac LC
			casez (address[23:20])
				4'b00??: // 00 0000 - 3F FFFF (RAM)
					selectRAM = !_cpuAS;
				4'b010?: // 40 0000 - 5F FFFF (RAM mirror? No, LC RAM is up to 10MB)
					// V8 handles RAM mapping. For now, map lower range as RAM.
					selectRAM = !_cpuAS;
				4'b1010: // A0 0000 - AF FFFF (ROM)
					selectROM = !_cpuAS;
				4'b1111: begin // F0 0000 - FF FFFF
					// VRAM at F40000 (0x540000 in V8 space, mapped to F40000?)
					// V8 I/O at F00000+
					if (address[19:16] == 4'h4) begin // F4 0000
						selectVRAM = !_cpuAS;
					end else begin
						// Map I/O.
						// F04000: SCC
						// F06000: SCSI
						// F10000: SCSI
						// F12000: SCSI
						// F16000: SWIM (IWM)
						// F26000: VIA2 (Pseudo)

						// LC: F16000 IWM.
						if (address[23:12] == 12'hF16) selectIWM = !_cpuAS;
						// VIA1 at F00000.
						if (address[23:12] == 12'hF00) selectVIA = !_cpuAS; // VIA1
						// SCC at F04000.
						if (address[23:12] == 12'hF04) selectSCC = !_cpuAS;
						// SCSI at F10000.
						if (address[23:12] == 12'hF10) selectSCSI = !_cpuAS;
						// RAMDAC at F24000 (0x524000 relative).
						if (address[23:12] == 12'hF24) selectCLUT = !_cpuAS;
						// Pseudo-VIA at F26000 (0x526000 relative).
						if (address[23:12] == 12'hF26) selectPseudoVIA = !_cpuAS;
					end
				end
				default:
					;
			endcase
		end else begin
			casez (address[23:20])
				4'b00??: begin //00 0000 - 3F FFFF
					if (memoryOverlayOn == 0)
						selectRAM = !_cpuAS;
					else begin
						if (address[23:20] == 0) begin
							// Mac Plus: repeated images of overlay ROM only extend to $0F0000
							// Mac 512K: more repeated ROM images at $020000-$02FFFF
							// Mac SE:   overlay ROM at $00 0000 - $0F FFFF
							selectROM = !_cpuAS;
						end
					end
				end
				4'b0100: begin //40 0000 - 4F FFFF
					if(configROMSize[1] || address[17] == 1'b0)   // <- this detects SCSI (on Plus)!!!
						selectROM = !_cpuAS;
					selectSEOverlay = !_cpuAS;
				end
				4'b0101: begin //50 000 - 5F FFFF
					if (address[19]) // 58 000 - 5F FFFF
						selectSCSI = !_cpuAS;
					selectSEOverlay = !_cpuAS;
				end
				4'b0110:
					if (memoryOverlayOn)
						selectRAM = !_cpuAS;
				4'b10?1:
					selectSCC = !_cpuAS;
				4'b1100: // C0 000 - CF FFF
					if (!configROMSize[1])
						selectIWM = !_cpuAS;
				4'b1101:
					selectIWM = !_cpuAS;
				4'b1110:
					if (address[19]) // E8 000 - EF FFF
						selectVIA = !_cpuAS;
				default:
					; // select nothing
			endcase
		end
	end
endmodule
